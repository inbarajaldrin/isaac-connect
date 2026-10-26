# Architecture and debugging

[Back to README](../README.md)

## How it works

- **Embedded loopback HTTP server** (`LocalServer.swift`, POSIX sockets, 127.0.0.1,
  ephemeral port) serves the bundled NVIDIA renderer from `Resources/Renderer/`.
  The renderer loads its JS via `<script type="module">`, which needs a real
  (non-null) origin — `file://` silently fails, `http://127.0.0.1` works.
- **WKWebView** fills each window. `mediaTypesRequiringUserActionForPlayback = []`
  plus a document-start script that mutes the `<video>` then `.play()`s it (muted
  autoplay is the only gesture-free form WebKit allows).
- **ATS** in Info.plist (`NSAllowsArbitraryLoads` + `…InWebContent` +
  `NSAllowsLocalNetworking`) permits the insecure `ws://<host>:49100` signaling.
- **Auto-connect**: after the renderer loads, the connect form is driven (with
  retry) to the window's workstation host; signaling/media go to `ws://<host>:49100`.
- **Auto-reconnect watchdog**: a document-start hook posts WebSocket /
  RTCPeerConnection health to native; a 1s watchdog recovers (reload + re-drive
  connect, exponential backoff) on signaling close while streaming, PC
  failed/disconnected/closed, or a `<video>` stall.
- **Event-based idle (Linux→Mac status link)**: a dropped stream doesn't say *why*
  (sim finished vs. restarting), so after a couple of failed reloads the viewer
  asks the box `isaac-ctl status` over SSH. **running** (sim up, even mid-boot) →
  keep re-acquiring; **stopped/unreachable** → stop blindly redrawing, title shows
  `· not running`, and a slow status heartbeat auto-reconnects the instant the sim
  is relaunched (from the menu *or* directly on Linux). Without an SSH target it
  falls back to a bounded retry then parks until you reconnect.
- **Clean disconnect**: on switch / window-close / quit, all peer connections +
  sockets are closed (`pc.close()` + `ws.close(1000)`) with a flush delay before
  teardown, so the server emits `NVST_CCE_DISCONNECTED` and frees the slot.
- **Launch/Stop**: `RemoteLauncher.swift` shells `/usr/bin/ssh` (BatchMode, your
  keys/config) to run `isaac-ctl <verb>` on the box — the cold-path control plane
  that works precisely when nothing sim-side is listening. Launch returns at spawn;
  readiness feedback IS the auto-reconnect latching on.
## Notes

- The app allows **one window per streaming endpoint (host and port)**. Isaac
  Connect and the official client cannot use the same single-session stream at
  the same time.
- Debug env hooks, off by default: `ISAAC_VERIFY=<path>` (poll `<video>` state to a
  file), `ISAAC_SIM_DROP=1` (SIGUSR1 nulls the video source to test recovery),
  `ISAAC_ACQUIRE_TIMEOUT=<s>` (override the no-video reload timeout).
- `.build/` and the assembled `*.app` are regenerable and not committed.
## Layout

```
Package.swift                       # SPM executable; .copy(Renderer)
entitlements.plist                  # network.client/server (receive-only)
AppIcon.icns                        # app icon (original artwork)
LICENSE                             # MIT
Scripts/
  build.sh                          # build + bundle + sign -> "Isaac Connect.app"
  release.sh                        # Developer-ID sign + notarize + staple + gh release
.github/workflows/ci.yml            # build-only CI (no signing/secrets)
linux/
  isaac-ctl                         # launch|stop|status|restart on the workstation
                                    # (webrtc flags, ETLI block, deadlock fix;
                                    #  ~/.config/isaac-ctl.conf holds machine truth)
Sources/IsaacConnect/
  main.swift                        # entry point (NSApplication bootstrap)
  AppDelegate.swift                 # lifecycle, window set, menu bar
  ViewerController.swift            # per-window stream: connect/watchdog/clipboard
  ViewerWindow.swift                # one window + its controller (multi-window)
  RemoteLauncher.swift              # ssh → isaac-ctl verbs on a box (launch/run/stop)
  Workstation.swift                 # workstation + launch-profile model + JSON store
  SettingsWindowController.swift    # editor: workstations + per-box launch profiles
  LocalServer.swift                 # loopback static file server
  Renderer/                         # bundled NVIDIA renderer (small files only)
    index.html
    assets/renderer-*.js, renderer-*.css
```
