# Third-party components

The MIT license in `LICENSE` covers original Isaac Connect code and artwork.
It does not relicense NVIDIA software or the dependencies in the imported renderer.

## NVIDIA renderer

The tested renderer is imported from **NVIDIA Isaac Sim WebRTC Streaming Client
1.1.4**. Its JavaScript includes **@nvidia/omniverse-webrtc-streaming-library
5.12.0**. The original HTML, JavaScript, and CSS are copied without modification;
`renderer.lock.json` records their SHA-256 hashes.

This software contains source code provided by NVIDIA Corporation.

NVIDIA retains ownership of its software. See the
[NVIDIA Isaac Sim WebRTC Streaming Client License Agreement](https://docs.isaacsim.omniverse.nvidia.com/latest/common/license-isaac-sim-webrtc-streaming-client.html).
That agreement describes conditional incorporation and redistribution; importing
the files or passing a checksum check does not grant a new license.

The public source candidate contains the integration code and checksums. The
renderer payload is a local build input. The built application includes its
original proprietary notice and the applicable license link at
`Contents/Resources/Renderer/NVIDIA-NOTICE.txt`.

## Renderer dependencies

The importer collects upstream package license files, including the notices for
React, React DOM, Bootstrap, React Bootstrap, and the streaming library's utility
dependencies. The complete collected notices ship at
`Contents/Resources/Renderer/THIRD-PARTY-NOTICES.txt`.

Upstream license notices for the bundled renderer and its dependencies are
included in `Contents/Resources/Renderer/`.

See [renderer provenance](docs/renderer-provenance.md) for the source package and
the scope of the packaging review.
