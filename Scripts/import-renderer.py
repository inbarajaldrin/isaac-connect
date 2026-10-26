#!/usr/bin/env python3
"""Import the locked renderer and its notices from the official NVIDIA client."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_APP = Path("/Applications/Isaac Sim WebRTC Streaming Client.app")
NVIDIA_PACKAGE = "node_modules/@nvidia/omniverse-webrtc-streaming-library"


class AsarArchive:
    """Read packed files; never execute the client or extract archive paths."""

    def __init__(self, path):
        self.path = Path(path)
        self.size = self.path.stat().st_size
        with self.path.open("rb") as stream:
            prefix = stream.read(16)
            if len(prefix) != 16:
                raise ValueError("Truncated ASAR header")
            magic, header_size, _, json_size = struct.unpack("<4I", prefix)
            if magic != 4 or not 0 < json_size <= header_size <= 32 * 1024 * 1024:
                raise ValueError("Invalid ASAR header sizes")
            self.data_offset = 8 + header_size
            if self.data_offset > self.size or 16 + json_size > self.data_offset:
                raise ValueError("ASAR header exceeds archive bounds")
            data = stream.read(json_size)
            if len(data) != json_size:
                raise ValueError("Truncated ASAR metadata")
            self.header = json.loads(data)

    def entry(self, name):
        node = self.header
        for part in PurePosixPath(name).parts:
            if part in ("..", "/"):
                raise ValueError("Invalid archive path")
            node = node["files"][part]
        return node

    def read(self, name):
        node = self.entry(name)
        if node.get("unpacked") or "link" in node or "files" in node:
            raise ValueError(f"Expected a packed regular file: {name}")
        size, offset = int(node["size"]), int(node["offset"])
        start = self.data_offset + offset
        if offset < 0 or size < 0 or start + size > self.size:
            raise ValueError(f"ASAR file exceeds archive bounds: {name}")
        with self.path.open("rb") as stream:
            stream.seek(start)
            data = stream.read(size)
        if len(data) != size:
            raise ValueError(f"Truncated ASAR file: {name}")
        return data

    def names(self, node=None, prefix=""):
        node = self.header if node is None else node
        for name, entry in node.get("files", {}).items():
            path = prefix + name
            if "files" in entry:
                yield from self.names(entry, path + "/")
            else:
                yield path


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def validate_payload(payload, lock):
    for name, expected in lock["files"].items():
        data = payload[name]
        if len(data) != expected["size"] or sha256(data) != expected["sha256"]:
            raise ValueError(f"Renderer checksum mismatch: {name}; review before changing renderer.lock.json")


def verify_renderer(output, lock):
    validate_payload({name: (output / name).read_bytes() for name in lock["files"]}, lock)
    provenance = json.loads((output / "provenance.json").read_text())
    if provenance["source"] != lock["source"] or provenance["files"] != lock["files"]:
        raise ValueError("Renderer provenance does not match renderer.lock.json")
    if (set(lock["notices"]) != {"NVIDIA-NOTICE.txt", "THIRD-PARTY-NOTICES.txt"}
            or provenance["notices"] != lock["notices"]):
        raise ValueError("Renderer license notices are incomplete")
    for name, expected in lock["notices"].items():
        if sha256((output / name).read_bytes()) != expected:
            raise ValueError(f"Renderer notice checksum mismatch: {name}")


def import_renderer(app, output, lock):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    source = lock["source"]
    if (info.get("CFBundleIdentifier") != source["bundle_identifier"]
            or info.get("CFBundleShortVersionString") != source["version"]):
        raise ValueError(f"Expected official client {source['version']}; found {info.get('CFBundleShortVersionString')}")
    archive = AsarArchive(app / "Contents/Resources/app.asar")
    sdk = json.loads(archive.read(NVIDIA_PACKAGE + "/package.json"))
    if sdk["version"] != source["streaming_library_version"]:
        raise ValueError("NVIDIA streaming library version does not match the lock")
    payload = {name: archive.read("dist/renderer/" + name) for name in lock["files"]}
    validate_payload(payload, lock)  # Validate every renderer file before writing anything.

    nvidia = archive.read(NVIDIA_PACKAGE + "/LICENSE.txt")
    payload["NVIDIA-NOTICE.txt"] = (
        b"NVIDIA Isaac Sim WebRTC Streaming Client " + source["version"].encode()
        + b"\nNVIDIA streaming library " + sdk["version"].encode()
        + b"\n\n" + nvidia + b"\nApplicable client license:\n"
        + source["license_url"].encode() + b"\n\n"
        + b"This software contains source code provided by NVIDIA Corporation.\n"
        + b"The NVIDIA components are not licensed under the Isaac Connect MIT license.\n"
    )
    third_party = []
    for name in sorted(archive.names()):
        base = PurePosixPath(name).name.lower()
        if (name.startswith("node_modules/") and not name.startswith(NVIDIA_PACKAGE + "/")
                and (base.startswith("license") or base.startswith("copyrightnotice"))):
            third_party.append(b"\n===== " + name.encode() + b" =====\n" + archive.read(name))
    if not third_party:
        raise ValueError("Upstream third-party license notices are missing")
    payload["THIRD-PARTY-NOTICES.txt"] = b"Upstream package license notices\n" + b"\n".join(third_party)
    for name, expected in lock["notices"].items():
        if sha256(payload[name]) != expected:
            raise ValueError(f"Renderer notice checksum mismatch: {name}")
    provenance = {
        "source": source, "files": lock["files"],
        "notices": {name: sha256(payload[name]) for name in ("NVIDIA-NOTICE.txt", "THIRD-PARTY-NOTICES.txt")},
    }
    payload["provenance.json"] = (json.dumps(provenance, indent=2, sort_keys=True) + "\n").encode()
    for name, data in payload.items():
        relative = PurePosixPath(name)
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("Invalid renderer output path")
        path = output / name
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(path.name + ".import-tmp")
        temporary.write_bytes(data)
        temporary.replace(path)
    verify_renderer(output, lock)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=DEFAULT_APP)
    parser.add_argument("--output", type=Path, default=ROOT / "Sources/IsaacConnect/Renderer")
    parser.add_argument("--lock", type=Path, default=ROOT / "renderer.lock.json")
    parser.add_argument("--check", action="store_true", help="verify already imported files without reading a client app")
    args = parser.parse_args()
    try:
        lock = json.loads(args.lock.read_text())
        if args.check:
            verify_renderer(args.output, lock)
        else:
            import_renderer(args.app, args.output, lock)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Renderer import failed: {error}", file=sys.stderr)
        return 1
    print("Renderer files and license notices match the locked NVIDIA client.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
