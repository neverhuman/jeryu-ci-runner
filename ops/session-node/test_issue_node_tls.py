"""Tests for issue-node-tls.py.

Run from the repository root: python3 -m unittest discover -s ops/session-node

Every key is a throwaway the tool generates inside a temporary directory that
is removed when its test ends. openssl(1) is the independent verifier.
"""
import contextlib
import hashlib
import importlib.util
import io
import ipaddress
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.x509.oid import ExtendedKeyUsageOID

TOOL = Path(__file__).resolve().with_name("issue-node-tls.py")


def load_tool():
    # The tool's file name is not a module name, so load it by path; only the
    # placement helper is driven directly, everything else through the CLI.
    spec = importlib.util.spec_from_file_location("issue_node_tls", TOOL)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def certificate(path):
    return x509.load_pem_x509_certificate(Path(path).read_bytes())


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def mode(path):
    return stat.S_IMODE(os.lstat(path).st_mode)


def pins(output):
    return dict(line.split("=", 1) for line in output.splitlines() if "=" in line)


class IssueNodeTlsTest(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="issue-node-tls-test-")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)

    def run_tool(self, *arguments, expect=0, umask=None):
        previous = None if umask is None else os.umask(umask)
        try:
            result = subprocess.run(
                [sys.executable, str(TOOL), *map(str, arguments)],
                cwd=self.root,
                capture_output=True,
                text=True,
                check=False,
                # Bounded: a run that blocks (on a FIFO, say) fails, not hangs.
                timeout=60,
            )
        finally:
            if previous is not None:
                os.umask(previous)
        output = result.stdout + result.stderr
        # No run may print a private key: neither its PEM label nor a line of
        # any key file that exists now.
        self.assertNotIn("PRIVATE KEY", output)
        for key in self.root.rglob("*.key"):
            # Only regular files: reading a FIFO a test planted would block.
            if not key.is_file():
                continue
            for line in key.read_text().splitlines():
                if not line.startswith("-----"):
                    self.assertNotIn(line, output)
        self.assertEqual(result.returncode, expect, output)
        return result

    def issue_ca(self, directory="ca", name="acme session node CA", days=30):
        self.run_tool("ca", "--dir", directory, "--name", name, "--days", days)
        return self.root / directory

    def issue_leaf(self, role, directory=None, ca="ca", days=7, reuse=False, expect=0):
        directory = directory or role
        arguments = [f"{role}-leaf", "--dir", directory, "--ca-dir", ca, "--days", days]
        if role == "client":
            arguments += ["--name", "acme control plane"]
        if reuse:
            arguments.append("--reuse-key")
        return self.run_tool(*arguments, expect=expect)

    def openssl_verify(self, ca, leaf, *options):
        result = subprocess.run(
            ["openssl", "verify", "-x509_strict", *options, "-CAfile", str(ca), str(leaf)],
            capture_output=True,
            text=True,
            check=False,
        )
        return result.returncode

    def openssl_pins(self, leaf):
        der = subprocess.run(
            ["openssl", "x509", "-in", str(leaf), "-outform", "DER"],
            capture_output=True,
            check=True,
        ).stdout
        public = subprocess.run(
            ["openssl", "x509", "-in", str(leaf), "-pubkey", "-noout"],
            capture_output=True,
            check=True,
        ).stdout
        spki = subprocess.run(
            ["openssl", "pkey", "-pubin", "-outform", "DER"],
            input=public,
            capture_output=True,
            check=True,
        ).stdout
        return hashlib.sha256(der).hexdigest(), hashlib.sha256(spki).hexdigest()

    def test_chain_verifies_and_pins_match_an_independent_computation(self):
        ca = self.issue_ca()
        node = pins(self.issue_leaf("node").stdout)
        client = pins(self.issue_leaf("client").stdout)
        authority = certificate(ca / "ca.pem")
        for leaf in ("node/node.pem", "client/client.pem"):
            certificate(self.root / leaf).verify_directly_issued_by(authority)
        node_pem, client_pem = self.root / "node/node.pem", self.root / "client/client.pem"
        self.assertEqual(
            self.openssl_verify(ca / "ca.pem", node_pem, "-purpose", "sslserver",
                                "-verify_ip", "127.0.0.1"),
            0,
        )
        self.assertEqual(
            self.openssl_verify(ca / "ca.pem", client_pem, "-purpose", "sslclient"), 0
        )
        for issued, path in ((node, node_pem), (client, client_pem)):
            self.assertEqual(
                (issued["leaf_sha256"], issued["key_sha256"]), self.openssl_pins(path)
            )
            listed = pins(self.run_tool("pins", "--cert", path).stdout)
            self.assertEqual(listed, issued)
        # The verifiers can refuse: a CA with the same name but another key
        # issued this leaf, so only its signature tells them apart.
        self.issue_ca("other", name="acme session node CA")
        self.issue_leaf("node", directory="stranger", ca="other")
        stranger = self.root / "stranger/node.pem"
        self.assertNotEqual(
            self.openssl_verify(ca / "ca.pem", stranger, "-purpose", "sslserver"), 0
        )
        with self.assertRaises(InvalidSignature):
            certificate(stranger).verify_directly_issued_by(authority)

    def test_leaves_carry_exactly_the_stated_san_and_extended_key_usage(self):
        ca = self.issue_ca()
        self.issue_leaf("node")
        self.issue_leaf("client")
        node = certificate(self.root / "node/node.pem")
        client = certificate(self.root / "client/client.pem")
        authority = certificate(ca / "ca.pem")
        san = node.extensions.get_extension_for_class(x509.SubjectAlternativeName)
        self.assertEqual(list(san.value), [x509.IPAddress(ipaddress.ip_address("127.0.0.1"))])
        with self.assertRaises(x509.ExtensionNotFound):
            client.extensions.get_extension_for_class(x509.SubjectAlternativeName)
        for leaf, usage in ((node, ExtendedKeyUsageOID.SERVER_AUTH),
                            (client, ExtendedKeyUsageOID.CLIENT_AUTH)):
            extended = leaf.extensions.get_extension_for_class(x509.ExtendedKeyUsage)
            self.assertEqual(list(extended.value), [usage])
            basic = leaf.extensions.get_extension_for_class(x509.BasicConstraints)
            self.assertTrue(basic.critical)
            self.assertFalse(basic.value.ca)
            uses = leaf.extensions.get_extension_for_class(x509.KeyUsage).value
            self.assertTrue(uses.digital_signature)
            self.assertFalse(uses.key_cert_sign)
        basic = authority.extensions.get_extension_for_class(x509.BasicConstraints)
        self.assertTrue(basic.critical and basic.value.ca)
        self.assertEqual(basic.value.path_length, 0)
        self.assertTrue(authority.extensions.get_extension_for_class(x509.KeyUsage).value.key_cert_sign)
        # Each leaf is refused for any other name or purpose.
        node_pem, client_pem = self.root / "node/node.pem", self.root / "client/client.pem"
        for leaf, options in (
            (node_pem, ("-purpose", "sslserver", "-verify_ip", "127.0.0.2")),
            (node_pem, ("-purpose", "sslclient")),
            (client_pem, ("-purpose", "sslserver")),
        ):
            self.assertNotEqual(self.openssl_verify(ca / "ca.pem", leaf, *options), 0)

    def test_reuse_key_keeps_the_key_pin_and_changes_the_leaf_pin(self):
        self.issue_ca()
        for role in ("node", "client"):
            with self.subTest(role=role):
                key = self.root / role / f"{role}.key"
                first = pins(self.issue_leaf(role).stdout)
                key_before = digest(key)
                second = pins(self.issue_leaf(role, days=8, reuse=True).stdout)
                self.assertEqual(first["key_sha256"], second["key_sha256"])
                self.assertNotEqual(first["leaf_sha256"], second["leaf_sha256"])
                self.assertEqual(digest(key), key_before)
                renewed = self.root / role / f"{role}.pem"
                self.assertEqual(
                    (second["leaf_sha256"], second["key_sha256"]), self.openssl_pins(renewed)
                )
                self.assertEqual(sorted(os.listdir(self.root / role)), [f"{role}.key", f"{role}.pem"])

    def test_existing_files_are_never_overwritten(self):
        ca = self.issue_ca()
        before = {name: digest(ca / name) for name in ("ca.key", "ca.pem")}
        refused = self.run_tool("ca", "--dir", "ca", "--name", "again", "--days", 1, expect=1)
        self.assertIn("refusing to overwrite", refused.stderr)
        self.assertEqual({name: digest(ca / name) for name in before}, before)
        # A lone leaf without its key is refused before any new key is written.
        node = self.root / "node"
        node.mkdir(mode=0o700)
        (node / "node.pem").write_bytes(b"an earlier leaf\n")
        refused = self.issue_leaf("node", expect=1)
        self.assertIn("refusing to overwrite", refused.stderr)
        self.assertEqual(os.listdir(node), ["node.pem"])
        self.assertEqual((node / "node.pem").read_bytes(), b"an earlier leaf\n")
        # A second leaf without --reuse-key is refused and the first one stays.
        self.issue_leaf("client")
        client = self.root / "client"
        before = {name: digest(client / name) for name in ("client.key", "client.pem")}
        self.issue_leaf("client", expect=1)
        self.assertEqual({name: digest(client / name) for name in before}, before)
        self.assertEqual(sorted(os.listdir(client)), ["client.key", "client.pem"])

    def test_placement_never_replaces_an_existing_name(self):
        tool = load_tool()
        directory = self.root / "place"
        directory.mkdir(mode=0o700)
        (directory / "taken").write_bytes(b"kept")
        os.symlink("missing", directory / "dangling")
        fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
        try:
            for name in ("taken", "dangling"):
                with contextlib.redirect_stderr(io.StringIO()) as stderr:
                    with self.assertRaises(SystemExit):
                        tool.write_file(fd, str(directory), name, b"new", 0o644)
                self.assertIn("refusing to overwrite", stderr.getvalue())
            tool.write_file(fd, str(directory), "fresh", b"new", 0o644)
        finally:
            os.close(fd)
        self.assertEqual((directory / "taken").read_bytes(), b"kept")
        self.assertTrue((directory / "dangling").is_symlink())
        self.assertFalse((directory / "missing").exists())
        self.assertEqual((directory / "fresh").read_bytes(), b"new")
        self.assertEqual(sorted(os.listdir(directory)), ["dangling", "fresh", "taken"])

    def test_symlinked_directories_are_refused(self):
        self.issue_ca()
        (self.root / "real").mkdir(mode=0o700)
        os.symlink("real", self.root / "link")
        os.symlink("ca", self.root / "ca-link")
        os.symlink("nowhere", self.root / "dangling")
        for arguments in (
            ("ca", "--dir", "link", "--name", "x", "--days", 1),
            ("node-leaf", "--dir", "link", "--ca-dir", "ca", "--days", 1),
            ("client-leaf", "--dir", "dangling", "--ca-dir", "ca", "--name", "x", "--days", 1),
            ("node-leaf", "--dir", "node", "--ca-dir", "ca-link", "--days", 1),
        ):
            refused = self.run_tool(*arguments, expect=1)
            self.assertIn("refusing a symlinked directory", refused.stderr)
        self.assertEqual(os.listdir(self.root / "real"), [])
        self.assertFalse((self.root / "nowhere").exists())
        self.assertFalse((self.root / "node").exists())

    def test_modes_are_exact_whatever_the_umask(self):
        for umask in (0o000, 0o077):
            with self.subTest(umask=f"{umask:03o}"):
                base = self.root / f"umask-{umask:03o}"
                base.mkdir()
                self.run_tool("ca", "--dir", base / "ca", "--name", "x", "--days", 30, umask=umask)
                for role in ("node", "client"):
                    arguments = [f"{role}-leaf", "--dir", base / role, "--ca-dir", base / "ca",
                                 "--days", 7]
                    if role == "client":
                        arguments += ["--name", "x"]
                    self.run_tool(*arguments, umask=umask)
                    self.run_tool(*arguments, "--reuse-key", umask=umask)
                for name in ("ca", "node", "client"):
                    self.assertEqual(mode(base / name), 0o700, name)
                    self.assertEqual(mode(base / name / f"{name}.key"), 0o600, name)
                    self.assertEqual(mode(base / name / f"{name}.pem"), 0o644, name)

    def test_ca_custody_and_lifetime_are_checked(self):
        ca = self.issue_ca(days=10)
        refused = self.issue_leaf("node", days=11, expect=1)
        self.assertIn("would outlive its CA", refused.stderr)
        self.assertFalse((self.root / "node/node.key").exists())
        os.chmod(ca / "ca.key", 0o640)
        refused = self.issue_leaf("node", expect=1)
        self.assertIn("lets group or others in", refused.stderr)
        os.chmod(ca / "ca.key", 0o600)
        other = self.issue_ca("other")
        original = (ca / "ca.key").read_bytes()
        (ca / "ca.key").write_bytes((other / "ca.key").read_bytes())
        refused = self.issue_leaf("node", expect=1)
        self.assertIn("ca.key does not belong to ca.pem", refused.stderr)
        (ca / "ca.key").write_bytes(original)
        # A FIFO in place of the key or the certificate is refused at once,
        # never waited on for a writer.
        for name in ("ca.key", "ca.pem"):
            kept = (ca / name).read_bytes()
            (ca / name).unlink()
            os.mkfifo(ca / name, 0o600)
            refused = self.issue_leaf("node", expect=1)
            self.assertIn("not a regular file", refused.stderr)
            (ca / name).unlink()
            (ca / name).write_bytes(kept)
            os.chmod(ca / name, 0o600 if name == "ca.key" else 0o644)
        # With its own key back, the same CA issues: the refusals were custody.
        self.issue_leaf("node")

    def test_help_names_every_subcommand(self):
        listed = self.run_tool("--help").stdout
        for command in ("ca", "node-leaf", "client-leaf", "pins"):
            self.assertIn(command, listed)
            self.assertIn("usage:", self.run_tool(command, "--help").stdout)
        self.assertIn("--reuse-key", self.run_tool("node-leaf", "--help").stdout)


if __name__ == "__main__":
    unittest.main()
