# Renderer provenance

The renderer was traced to the installed official NVIDIA Isaac Sim WebRTC
Streaming Client app. Its bundle reports version **1.1.4**, build **1.1.4.238**,
and identifier `com.electron.isaacsim-webrtc-streaming-client`.

The three files under `dist/renderer/` in its `Contents/Resources/app.asar` match
the previously tested Isaac Connect renderer byte for byte. They are not built
from the nearby `web-viewer-sample` checkout, which has a different SDK version.
The installed client's SDK package reports version **5.12.0**.

`renderer.lock.json` is the source of truth for file sizes, checksums, and package
versions. `Scripts/import-renderer.py` reads the archive as a data container,
validates all three renderer files, and collects upstream notices. It neither
runs nor changes the official client. `--check` verifies the imported payload and
notices before the Isaac Connect app is built.

## Licensing boundary

The bundled SDK's `LICENSE.txt` contains a proprietary notice rather than an
open-source grant. The client license allows incorporation of binary software
subject to conditions, including additional application functionality, access
through the incorporating application, consistent distribution terms, and
preservation of notices. Its restrictions and component-specific terms also apply.

Isaac Connect adds saved workstations, multiple windows, reconnect handling, and
SSH launch/control. Those features describe the application; they are not a legal
determination that every distribution condition has been satisfied.

This source candidate excludes the proprietary renderer payload. Distribution of
a compiled app containing that payload still requires compliance with NVIDIA's
terms. A public-source review and a notarization result do not settle that question.

References checked on 2026-10-26:

- [Client license agreement](https://docs.isaacsim.omniverse.nvidia.com/latest/common/license-isaac-sim-webrtc-streaming-client.html)
- [Current Omniverse licensing guidance](https://docs.omniverse.nvidia.com/dev-guide/latest/common/NVIDIA_Omniverse_License_Agreement.html)

The general Omniverse page does not replace identifying the agreement applicable
to the exact client components being distributed.
