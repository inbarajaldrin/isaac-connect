# Linux launcher configuration

[Back to README](../README.md)

## Linux side (`linux/isaac-ctl`)

One script per workstation, installed to `~/.local/bin/isaac-ctl`, machine config
in `~/.config/isaac-ctl.conf`:

| Key | Meaning |
|-----|---------|
| `ISAACSIM_BIN` | the install's `isaacsim` entry point — **source of truth**, written by setup. Without it, resolution falls back to `PATH` (symlinks resolved; shell-wrapper launchers refused) then NVIDIA's doc-example venv names — best-effort only, since install variants differ (pip-Lab `env_isaaclab`/py3.11, pip-standalone `env_isaacsim`/py3.12, binary installs with no venv at all) |
| `ISAACSIM_STREAM_IP` / `ISAACSIM_STREAM_PORT` | override the advertised endpoint (default: tailscale IP, 49100) |
| `ISAACSIM_KIT_MCP_EXT_FOLDER` | override ONLY for boxes that never ran [omni-kit-mcp](https://github.com/inbarajaldrin)'s `install.py` — installed boxes autoload the MCP bridge with zero flags |
| `ISAACSIM_EXTRA_ARGS` | appended verbatim (project extensions, …) |

`launch` starts Isaac Sim headless with WebRTC streaming and returns immediately
(`--wait` blocks until the stream port listens); `status` prints
`running pid=… stream=ip:port` (exit 0) or `stopped` (exit 1); `stop` is
TERM-then-KILL with an exact pidfile (never `pgrep -f`). `--app isaaclab` is
reserved for a Lab launch profile (viewing Lab already works — see Features).

`status`/`launch` are **port-aware**: a sim started *outside* isaac-ctl (by hand
on the box) is still reported `running` (so the viewer connects instead of
parking idle), and `launch` refuses rather than starting a second sim that would
fight for the port. **isaac-ctl must be installed on each box you launch/stop from**
(the viewer invokes `~/.local/bin/isaac-ctl` over SSH); a box without it viewer-side
gives a clear "not installed — run setup" message, not a cryptic shell error.

**ROS 2 bridge** is a persistent *setup* step, not a launch flag: enable
`isaacsim.ros2.bridge` (its **versioned** extension id) in the Kit app's
`user.config.json`. Because Kit config can persist extensions but **not** process
env (ld.so consumes it pre-exec), `isaac-ctl` applies the two crash guards the
bridge needs — static-TLS surplus bump + venv-nvjitlink `LD_PRELOAD` (fatal
`_dl_allocate_tls_init` / `__nvJitLinkCreate_12_8` otherwise) — at every
**full-app** launch. The guards are **per-profile, launcher-scoped** — never put
them in blanket env files like a venv's `activate`: the static-TLS tunable is
*not* universally benign (it breaks the PhysX GPU dispatcher's thread creation in
Isaac Lab standalone runs — the tunable steals the surplus from new threads'
stacks), so the future `isaaclab` profile omits it while the full-app profile
keeps it.
