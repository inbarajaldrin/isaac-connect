# Renderer build input

This directory receives the tested NVIDIA WebRTC renderer during the build.
The proprietary payload is imported locally and is not part of the source release.

Run `python3 Scripts/import-renderer.py` with the official NVIDIA Isaac Sim WebRTC
Streaming Client 1.1.4 installed. Use `--app /path/to/client.app` for another location.
`renderer.lock.json` records the original files and their checksums.

The importer also collects upstream license notices into this directory. The app
bundle includes those notices with the renderer. See the root
`THIRD_PARTY_NOTICES.md` for licensing boundaries.
