#!/usr/bin/env python3
"""Trusted image composition overlay; never accepts a guest/RPC filesystem path.

This only composes fixed reviewed bytes in an unmounted builder staging tree.
Repository recipes/dependency hooks belong in build microVMs. Signing/provenance
and complete input closure remain the release-ops pipeline's responsibility.
"""
import argparse
import os
from pathlib import Path
import shutil
import stat


def custody(path):
    """No symlinks or untrusted writable parents in the composition target."""
    if not path.is_absolute():
        raise ValueError("image_staging_custody_denied")
    for parent in reversed([path, *path.parents]):
        info = parent.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise ValueError("image_staging_custody_denied")


def directory(root, relative):
    path = root
    for component in relative.split("/"):
        path = path / component
        if not os.path.lexists(path):
            path.mkdir(mode=0o755)
        custody(path)
    return path


def apply(root, image_class):
    if os.geteuid() != 0 or image_class not in ("production", "test"):
        raise ValueError("image_class_invalid")
    custody(root)
    mock = root / "usr/lib/jeryu/mock"
    if image_class == "production" and os.path.lexists(mock):
        raise ValueError("production_mock_entrypoint_denied")
    # The fixed rootfs marker is immutable in the read-only admitted image.
    config = directory(root, "etc/jeryu") / "runtime-image-class"
    if os.path.lexists(config):
        raise ValueError("image_class_already_composed")
    descriptor = os.open(config, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o444)
    with os.fdopen(descriptor, "w") as output:
        output.write(image_class + "\n")
        output.flush()
        os.fsync(output.fileno())
    if image_class == "test":
        target = directory(root, "usr/lib/jeryu/mock") / "agent"
        if os.path.lexists(target):
            raise ValueError("mock_entrypoint_already_composed")
        source = Path(__file__).parent / "test/mock-agent"
        # Only this repository-owned fixed file is copied; it is not executed.
        with source.open("rb") as input_file:
            descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o555)
            with os.fdopen(descriptor, "wb") as output:
                shutil.copyfileobj(input_file, output)
                output.flush()
                os.fsync(output.fileno())
    print("runtime_class_composed=" + image_class)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image_class", choices=("production", "test"))
    parser.add_argument("staging_root", type=Path)
    arguments = parser.parse_args()
    try:
        apply(arguments.staging_root, arguments.image_class)
    except (ValueError, OSError):
        # Fixed diagnostics: no untrusted paths, source bytes or credentials.
        raise SystemExit("runtime_class_composition_failed")
