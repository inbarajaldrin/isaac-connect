# Installation and setup

[Back to README](../README.md)

## Setup

### macOS (the viewer)

#### Download and install

Download the Apple silicon ZIP from [Releases](https://github.com/inbarajaldrin/isaac-connect/releases/latest),
unzip it, and drag **Isaac Connect.app** into **Applications**. Open the app and
add your workstation in **Settings** (`⌘,`). The download requires macOS 14 or
later and includes the renderer; Xcode, Swift, and Python are not required.

#### Build from source

For a source build, install the official **NVIDIA Isaac Sim WebRTC Streaming
Client 1.1.4** from NVIDIA. The build imports its tested renderer locally and
collects the upstream license notices. The proprietary renderer payload is not
included in this source repository; its versions and checksums are pinned in
`renderer.lock.json`.

```sh
git clone https://github.com/inbarajaldrin/isaac-connect.git
cd isaac-connect
./Scripts/build.sh                       # swift build -c release + assemble + sign
cp -R "Isaac Connect.app" /Applications/
open "/Applications/Isaac Connect.app"    # first run: opens Settings to register a workstation
```

Requires macOS 14+, Swift 6 command-line tools, and Python 3. The
build signs with whatever codesigning identity is in your keychain (Developer ID
preferred, Apple Development fallback). Re-running is idempotent — it rebuilds and
replaces the bundle.

For an official client installed elsewhere, set
`NVIDIA_CLIENT_APP="/path/to/Isaac Sim WebRTC Streaming Client.app"` when building.
Renderer upgrades require an updated lock and a compatibility review. See
[renderer provenance](../docs/renderer-provenance.md) and
[third-party notices](../THIRD_PARTY_NOTICES.md).

On first launch, register each workstation in **Settings** (name / host / SSH
`user@host`); the app connects to your first saved box. `ISAAC_IP=<host> open
"Isaac Connect.app"` targets a specific host on launch.

**Verify:** `codesign -dv "/Applications/Isaac Connect.app" && pgrep -x IsaacConnect`
— both succeed after `open` (signed bundle, process running).

### Linux workstation (`isaac-ctl`)

On each box (requires an [Isaac Sim pip install](https://docs.isaacsim.omniverse.nvidia.com/latest/installation/install_python.html)
providing an `isaacsim` CLI in a venv):

```sh
mkdir -p ~/.local/bin ~/.config
curl -fsSL https://raw.githubusercontent.com/inbarajaldrin/isaac-connect/main/linux/isaac-ctl \
  -o ~/.local/bin/isaac-ctl && chmod +x ~/.local/bin/isaac-ctl
```

Set `ISAACSIM_BIN` in `~/.config/isaac-ctl.conf` to the selected installation's
actual executable, preserving other settings already in that file:

```sh
ISAACSIM_BIN="/absolute/path/to/your/venv/bin/isaacsim"
```

For the tested **Isaac Sim 6.1** runtime, also add its application-streaming
settings to that config file. Use the workstation address entered in the Mac app:

```sh
ISAACSIM_STREAM_IP="your-workstation-ip"
ISAACSIM_EXTRA_ARGS="${ISAACSIM_EXTRA_ARGS:+$ISAACSIM_EXTRA_ARGS }--enable omni.kit.livestream.app"
ISAACSIM_EXTRA_ARGS+=" --/exts/omni.kit.livestream.app/primaryStream/publicIp=$ISAACSIM_STREAM_IP"
ISAACSIM_EXTRA_ARGS+=" --/exts/omni.kit.livestream.app/primaryStream/signalPort=${ISAACSIM_STREAM_PORT:-49100}"
ISAACSIM_EXTRA_ARGS+=" --/exts/omni.kit.livestream.app/primaryStream/streamPort=47998"
ISAACSIM_EXTRA_ARGS+=" --/exts/omni.kit.livestream.app/primaryStream/enableEventTracing=false"
```

These settings follow the installed 6.1 streaming extension and
[NVIDIA's streaming documentation](https://docs.isaacsim.omniverse.nvidia.com/6.1.0/installation/manual_livestream_clients.html).
The Mac app needs key-based SSH (`ssh user@host true` must succeed without a
prompt). The launcher is a shell script; it needs Bash and Linux `setsid`.

**Verify:** `~/.local/bin/isaac-ctl launch --wait && ~/.local/bin/isaac-ctl status`
— prints `ready` then `running pid=… stream=<ip>:49100`, and the Mac viewer
connects to that ip. (`isaac-ctl stop` to tear down.)
