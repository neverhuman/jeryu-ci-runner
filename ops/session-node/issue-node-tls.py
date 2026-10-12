#!/usr/bin/env python3
"""Issue the TLS material of a production JeRyu session node (Ed25519).

  ca           a new CA: ca.key (0600) and ca.pem (0644)
  node-leaf    the node's server leaf: node.key and node.pem, SAN IP 127.0.0.1
               only, extended key usage serverAuth
  client-leaf  the control plane's client leaf: client.key and client.pem,
               extended key usage clientAuth, no SAN
  pins         a leaf's DER SHA-256 and its key's SubjectPublicKeyInfo DER
               SHA-256: the two pin forms the control plane takes

Run it on the CA host, never on the node: the CA key must not reach a node.
Every file is written to a temporary name opened with O_EXCL, fsynced, and
then linked into place; link(2) refuses an existing name where rename(2) would
replace it, so nothing is overwritten. The one replacement is --reuse-key,
which keeps a leaf's key and renames the renewed certificate over the old one.
No private key is ever printed.
"""
import argparse
import datetime
import hashlib
import ipaddress
import os
import secrets
import stat
import sys

from cryptography import x509
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ed25519
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

# The control plane dials only https://127.0.0.1:<port>, so that is the one name.
NODE_ADDRESS = ipaddress.IPv4Address("127.0.0.1")
NODE_COMMON_NAME = "JeRyu session node"
MAX_DAYS = 3650
MAX_FILE_BYTES = 64 * 1024
# A peer whose clock runs slightly behind still accepts a fresh certificate.
CLOCK_SKEW = datetime.timedelta(minutes=5)


def fail(message):
    print(f"issue-node-tls: {message}", file=sys.stderr)
    raise SystemExit(1)


def not_after(certificate):
    # not_valid_after_utc is cryptography >= 42; older releases return naive UTC.
    value = getattr(certificate, "not_valid_after_utc", None)
    if value is None:
        value = certificate.not_valid_after.replace(tzinfo=datetime.timezone.utc)
    return value


def not_before(certificate):
    value = getattr(certificate, "not_valid_before_utc", None)
    if value is None:
        value = certificate.not_valid_before.replace(tzinfo=datetime.timezone.utc)
    return value


def open_directory(path, create):
    """Open a real directory without following a symlink, creating it 0700.

    Every later file operation is relative to this descriptor, so swapping the
    path for a symlink after the check cannot redirect a write.
    """
    created = False
    if create:
        try:
            os.mkdir(path, 0o700)
            created = True
        except FileExistsError:
            pass
        except OSError as error:
            fail(f"{path}: cannot create the directory: {error.strerror}")
    try:
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError as error:
        if os.path.islink(path):
            fail(f"{path}: refusing a symlinked directory")
        fail(f"{path}: not a usable directory: {error.strerror}")
    if created:
        os.fchmod(fd, 0o700)
    if os.fstat(fd).st_mode & 0o022:
        os.close(fd)
        fail(f"{path}: writable by group or others; another user could swap its files")
    return fd


def present(dir_fd, names):
    """The names that exist, a dangling symlink included."""
    found = []
    for name in names:
        try:
            os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
            found.append(name)
        except FileNotFoundError:
            pass
    return found


def write_file(dir_fd, directory, name, data, mode, replace=False):
    temporary = f".{name}.{secrets.token_hex(8)}.tmp"
    fd = os.open(
        temporary,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
        0o600,
        dir_fd=dir_fd,
    )
    try:
        try:
            # The exact mode, whatever the umask; set before any byte is written.
            os.fchmod(fd, mode)
            view = memoryview(data)
            while view:
                view = view[os.write(fd, view):]
            os.fsync(fd)
        finally:
            os.close(fd)
        if replace:
            os.rename(temporary, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
        else:
            os.link(temporary, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd, follow_symlinks=False)
    except FileExistsError:
        fail(f"refusing to overwrite {os.path.join(directory, name)}")
    finally:
        try:
            os.unlink(temporary, dir_fd=dir_fd)
        except FileNotFoundError:
            pass
    os.fsync(dir_fd)


def read_bounded(fd, label):
    data = os.read(fd, MAX_FILE_BYTES + 1)
    if len(data) > MAX_FILE_BYTES:
        fail(f"{label}: larger than {MAX_FILE_BYTES} bytes")
    return data


def read_private_key(dir_fd, directory, name):
    label = os.path.join(directory, name)
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=dir_fd)
    except OSError as error:
        fail(f"{label}: cannot open the key without following a link: {error.strerror}")
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            fail(f"{label}: not a regular file")
        if info.st_uid != os.geteuid():
            fail(f"{label}: owned by uid {info.st_uid}, not by you")
        if info.st_mode & 0o077:
            fail(f"{label}: mode {stat.S_IMODE(info.st_mode):04o} lets group or others in; use 0600")
        if info.st_nlink != 1:
            fail(f"{label}: has {info.st_nlink} links; a key has exactly one")
        data = read_bounded(fd, label)
    finally:
        os.close(fd)
    try:
        key = serialization.load_pem_private_key(data, password=None)
    except (TypeError, ValueError):
        key = None
    if not isinstance(key, ed25519.Ed25519PrivateKey):
        fail(f"{label}: not an unencrypted Ed25519 private key in PEM")
    return key


def read_certificate(path, label, dir_fd=None):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC, dir_fd=dir_fd)
    except OSError as error:
        fail(f"{label}: cannot open: {error.strerror}")
    try:
        data = read_bounded(fd, label)
    finally:
        os.close(fd)
    try:
        return x509.load_pem_x509_certificate(data)
    except ValueError:
        fail(f"{label}: not a PEM certificate")


def public_bytes(key):
    return key.public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)


def load_ca(ca_directory, now):
    dir_fd = open_directory(ca_directory, create=False)
    try:
        key = read_private_key(dir_fd, ca_directory, "ca.key")
        certificate = read_certificate("ca.pem", os.path.join(ca_directory, "ca.pem"), dir_fd)
    finally:
        os.close(dir_fd)
    try:
        constraints = certificate.extensions.get_extension_for_class(x509.BasicConstraints).value
    except x509.ExtensionNotFound:
        constraints = None
    if constraints is None or not constraints.ca:
        fail(f"{ca_directory}/ca.pem: not a CA certificate")
    if public_bytes(certificate.public_key()) != public_bytes(key.public_key()):
        fail(f"{ca_directory}: ca.key does not belong to ca.pem")
    if not (not_before(certificate) <= now < not_after(certificate)):
        fail(f"{ca_directory}/ca.pem: not valid now (valid until {stamp(not_after(certificate))})")
    return key, certificate


def key_usage(digital_signature=False, key_cert_sign=False):
    return x509.KeyUsage(
        digital_signature=digital_signature,
        content_commitment=False,
        key_encipherment=False,
        data_encipherment=False,
        key_agreement=False,
        key_cert_sign=key_cert_sign,
        crl_sign=key_cert_sign,
        encipher_only=False,
        decipher_only=False,
    )


def build_ca(key, name, days, now):
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, name)])
    return (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(subject)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - CLOCK_SKEW)
        .not_valid_after(now + datetime.timedelta(days=days))
        # Leaves only: the CA can never sign a further CA.
        .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
        .add_extension(key_usage(key_cert_sign=True), critical=True)
        .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False)
        .sign(key, None)
    )


def build_leaf(ca_key, ca_certificate, public_key, common_name, usage, node, days, now):
    expires = now + datetime.timedelta(days=days)
    if expires > not_after(ca_certificate):
        fail(f"the leaf would outlive its CA, which expires {stamp(not_after(ca_certificate))}")
    builder = (
        x509.CertificateBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, common_name)]))
        .issuer_name(ca_certificate.subject)
        .public_key(public_key)
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - CLOCK_SKEW)
        .not_valid_after(expires)
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .add_extension(key_usage(digital_signature=True), critical=True)
        .add_extension(x509.ExtendedKeyUsage([usage]), critical=False)
        .add_extension(x509.SubjectKeyIdentifier.from_public_key(public_key), critical=False)
        .add_extension(
            x509.AuthorityKeyIdentifier.from_issuer_public_key(ca_certificate.public_key()),
            critical=False,
        )
    )
    if node:
        builder = builder.add_extension(
            x509.SubjectAlternativeName([x509.IPAddress(NODE_ADDRESS)]), critical=False
        )
    return builder.sign(ca_key, None)


def private_pem(key):
    return key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )


def certificate_pem(certificate):
    return certificate.public_bytes(serialization.Encoding.PEM)


def stamp(moment):
    return moment.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def print_pins(certificate):
    der = certificate.public_bytes(serialization.Encoding.DER)
    spki = certificate.public_key().public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
    )
    print(f"leaf_sha256={hashlib.sha256(der).hexdigest()}")
    print(f"key_sha256={hashlib.sha256(spki).hexdigest()}")
    print(f"not_after={stamp(not_after(certificate))}")


def command_ca(arguments):
    now = datetime.datetime.now(datetime.timezone.utc)
    dir_fd = open_directory(arguments.dir, create=True)
    try:
        taken = present(dir_fd, ["ca.key", "ca.pem"])
        if taken:
            fail(f"refusing to overwrite {', '.join(os.path.join(arguments.dir, n) for n in taken)}")
        key = ed25519.Ed25519PrivateKey.generate()
        certificate = build_ca(key, arguments.name, arguments.days, now)
        write_file(dir_fd, arguments.dir, "ca.key", private_pem(key), 0o600)
        write_file(dir_fd, arguments.dir, "ca.pem", certificate_pem(certificate), 0o644)
    finally:
        os.close(dir_fd)
    print(f"wrote {os.path.join(arguments.dir, 'ca.key')}")
    print(f"wrote {os.path.join(arguments.dir, 'ca.pem')}")
    print(f"not_after={stamp(not_after(certificate))}")


def command_leaf(arguments, role):
    now = datetime.datetime.now(datetime.timezone.utc)
    key_name, certificate_name = f"{role}.key", f"{role}.pem"
    ca_key, ca_certificate = load_ca(arguments.ca_dir, now)
    dir_fd = open_directory(arguments.dir, create=not arguments.reuse_key)
    try:
        if arguments.reuse_key:
            key = read_private_key(dir_fd, arguments.dir, key_name)
        else:
            # Checked before anything is written, so a refusal leaves no new key behind.
            taken = present(dir_fd, [key_name, certificate_name])
            if taken:
                listed = ", ".join(os.path.join(arguments.dir, n) for n in taken)
                fail(f"refusing to overwrite {listed}; --reuse-key renews the leaf with its key")
            key = ed25519.Ed25519PrivateKey.generate()
        if role == "node":
            common_name, usage = NODE_COMMON_NAME, ExtendedKeyUsageOID.SERVER_AUTH
        else:
            common_name, usage = arguments.name, ExtendedKeyUsageOID.CLIENT_AUTH
        certificate = build_leaf(
            ca_key, ca_certificate, key.public_key(), common_name, usage, role == "node",
            arguments.days, now,
        )
        replaced = bool(present(dir_fd, [certificate_name]))
        if not arguments.reuse_key:
            write_file(dir_fd, arguments.dir, key_name, private_pem(key), 0o600)
        write_file(
            dir_fd, arguments.dir, certificate_name, certificate_pem(certificate), 0o644,
            replace=arguments.reuse_key,
        )
    finally:
        os.close(dir_fd)
    print(f"{'kept' if arguments.reuse_key else 'wrote'} {os.path.join(arguments.dir, key_name)}")
    print(f"{'replaced' if replaced else 'wrote'} {os.path.join(arguments.dir, certificate_name)}")
    print_pins(certificate)


def command_pins(arguments):
    print_pins(read_certificate(arguments.cert, arguments.cert))


def days(text):
    try:
        value = int(text, 10)
    except ValueError:
        value = 0
    if not 1 <= value <= MAX_DAYS:
        raise argparse.ArgumentTypeError(f"days must be a whole number from 1 to {MAX_DAYS}")
    return value


def common_name(text):
    if not 1 <= len(text) <= 64 or not all(" " <= c <= "~" for c in text):
        raise argparse.ArgumentTypeError("name must be 1 to 64 printable ASCII characters")
    return text


def parser():
    top = argparse.ArgumentParser(
        prog="issue-node-tls.py",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Each subcommand has --help. Files are owned by whoever runs this; "
            "install them on each host with the owners and modes its config needs."
        ),
    )
    commands = top.add_subparsers(dest="command", required=True, metavar="COMMAND")
    ca = commands.add_parser("ca", help="create a CA (ca.key 0600, ca.pem 0644)")
    ca.add_argument("--dir", required=True, help="directory for ca.key and ca.pem; created 0700")
    ca.add_argument("--name", required=True, type=common_name, help="the CA's common name")
    ca.add_argument("--days", required=True, type=days, help="validity in days")
    for role, summary in (
        ("node", "issue the node's server leaf (SAN IP 127.0.0.1, serverAuth)"),
        ("client", "issue the control plane's client leaf (clientAuth)"),
    ):
        leaf = commands.add_parser(f"{role}-leaf", help=summary)
        leaf.add_argument(
            "--dir", required=True, help=f"directory for {role}.key and {role}.pem; created 0700"
        )
        leaf.add_argument("--ca-dir", required=True, help="directory holding ca.key and ca.pem")
        if role == "client":
            leaf.add_argument("--name", required=True, type=common_name, help="the leaf's common name")
        leaf.add_argument("--days", required=True, type=days, help="validity in days")
        leaf.add_argument(
            "--reuse-key",
            action="store_true",
            help=f"keep {role}.key and replace only {role}.pem, so a key pin keeps matching",
        )
    pins = commands.add_parser("pins", help="print a certificate's leaf and key pins")
    pins.add_argument("--cert", required=True, help="PEM certificate")
    return top


def main():
    arguments = parser().parse_args()
    try:
        if arguments.command == "ca":
            command_ca(arguments)
        elif arguments.command == "pins":
            command_pins(arguments)
        else:
            command_leaf(arguments, {"node-leaf": "node", "client-leaf": "client"}[arguments.command])
    except OSError as error:
        fail(f"{error.filename or 'I/O'}: {error.strerror}")


if __name__ == "__main__":
    main()
