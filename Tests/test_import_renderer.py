import importlib.util
import json
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "Scripts/import-renderer.py"
spec = importlib.util.spec_from_file_location("import_renderer", MODULE_PATH)
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)


def make_archive(path, files):
    tree, chunks, offset = {"files": {}}, [], 0
    for name, data in files.items():
        node = tree
        parts = name.split("/")
        for part in parts[:-1]:
            node = node["files"].setdefault(part, {"files": {}})
        node["files"][parts[-1]] = {"size": len(data), "offset": str(offset)}
        chunks.append(data)
        offset += len(data)
    metadata = json.dumps(tree).encode()
    header_size = (8 + len(metadata) + 3) // 4 * 4
    prefix = struct.pack("<4I", 4, header_size, header_size - 4, len(metadata))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(prefix + metadata + b"\0" * (header_size - 8 - len(metadata)) + b"".join(chunks))


class RendererImportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.app = self.root / "Client.app"
        self.output = self.root / "Renderer"
        self.archive = self.app / "Contents/Resources/app.asar"
        self.source = {
            "product": "Fixture client", "version": "1.1.4",
            "bundle_identifier": "example.client", "streaming_library_version": "5.12.0",
            "license_url": "https://example.test/license",
        }
        self.assets = {"index.html": b"<div>fixture</div>", "assets/fixture.js": b"fixture();"}
        self.lock = {"source": self.source, "files": {
            name: {"size": len(data), "sha256": renderer.sha256(data)} for name, data in self.assets.items()
        }}
        self.files = {"dist/renderer/" + name: data for name, data in self.assets.items()}
        self.files.update({
            renderer.NVIDIA_PACKAGE + "/package.json": b'{"version":"5.12.0"}',
            renderer.NVIDIA_PACKAGE + "/LICENSE.txt": b"Fixture proprietary notice",
            "node_modules/example/LICENSE": b"Fixture dependency license",
        })
        expected_nvidia = (
            b"NVIDIA Isaac Sim WebRTC Streaming Client 1.1.4\nNVIDIA streaming library 5.12.0\n\n"
            b"Fixture proprietary notice\nApplicable client license:\nhttps://example.test/license\n\n"
            b"This software contains source code provided by NVIDIA Corporation.\n"
            b"The NVIDIA components are not licensed under the Isaac Connect MIT license.\n"
        )
        expected_dependencies = (
            b"Upstream package license notices\n\n===== node_modules/example/LICENSE =====\n"
            b"Fixture dependency license"
        )
        self.lock["notices"] = {
            "NVIDIA-NOTICE.txt": renderer.sha256(expected_nvidia),
            "THIRD-PARTY-NOTICES.txt": renderer.sha256(expected_dependencies),
        }
        (self.app / "Contents").mkdir(parents=True)
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "example.client", "CFBundleShortVersionString": "1.1.4",
        }))
        make_archive(self.archive, self.files)

    def tearDown(self):
        self.temp.cleanup()

    def test_import_preserves_bytes_and_collects_licenses(self):
        self.output.mkdir()
        (self.output / "README.md").write_text("Keep this integration document")
        renderer.import_renderer(self.app, self.output, self.lock)
        for name, data in self.assets.items():
            self.assertEqual((self.output / name).read_bytes(), data)
        self.assertIn("Fixture proprietary notice", (self.output / "NVIDIA-NOTICE.txt").read_text())
        self.assertIn("Fixture dependency license", (self.output / "THIRD-PARTY-NOTICES.txt").read_text())
        self.assertEqual((self.output / "README.md").read_text(), "Keep this integration document")
        renderer.verify_renderer(self.output, self.lock)

    def test_checksum_failure_preserves_existing_output(self):
        self.output.mkdir()
        (self.output / "index.html").write_bytes(b"existing renderer")
        self.files["dist/renderer/assets/fixture.js"] = b"changed upstream"
        make_archive(self.archive, self.files)
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            renderer.import_renderer(self.app, self.output, self.lock)
        self.assertEqual((self.output / "index.html").read_bytes(), b"existing renderer")
        self.assertFalse((self.output / "provenance.json").exists())

    def test_changed_notice_is_detected(self):
        renderer.import_renderer(self.app, self.output, self.lock)
        (self.output / "NVIDIA-NOTICE.txt").write_text("altered")
        with self.assertRaisesRegex(ValueError, "notice checksum mismatch"):
            renderer.verify_renderer(self.output, self.lock)

    def test_wrong_client_version_does_not_write_output(self):
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "example.client", "CFBundleShortVersionString": "2.0.0",
        }))
        with self.assertRaisesRegex(ValueError, "Expected official client"):
            renderer.import_renderer(self.app, self.output, self.lock)
        self.assertFalse(self.output.exists())

    def test_upstream_notice_change_does_not_write_output(self):
        self.files["node_modules/example/LICENSE"] = b"different dependency license"
        make_archive(self.archive, self.files)
        with self.assertRaisesRegex(ValueError, "notice checksum mismatch"):
            renderer.import_renderer(self.app, self.output, self.lock)
        self.assertFalse(self.output.exists())

    def test_archive_truncation_is_rejected(self):
        self.archive.write_bytes(self.archive.read_bytes()[:-1])
        archive = renderer.AsarArchive(self.archive)
        with self.assertRaisesRegex(ValueError, "archive bounds"):
            archive.read("node_modules/example/LICENSE")


if __name__ == "__main__":
    unittest.main()
