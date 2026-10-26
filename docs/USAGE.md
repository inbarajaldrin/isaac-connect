# Using Isaac Connect

[Back to README](../README.md)

## Features

- **Workstation switching** — pick a box from the **Workstation** menu; the view
  switches in place (clean-disconnect old → connect new).
- **Multi-window** — **Window ▸ New Window for ▸ &lt;box&gt;** opens an independent
  window per workstation, so you can watch two boxes at once. A streaming endpoint
  (host and port) already open in a window is grayed out.
- **Settings editor** — name your workstations and set host/IP + SSH (`⌘,`),
  persisted to `~/Library/Application Support/IsaacViewer/workstations.json`
  (the existing directory is retained across the rename to Isaac Connect).
- **Clean reconnect** — auto-recovers on signaling close / PC failure / video stall,
  and disconnects gracefully on quit so the server frees its single-session slot.
- **Launch/Stop from the Mac** — **Workstation ▸ Launch / Stop** runs `isaac-ctl`
  on the box over SSH (using the workstation's `user@host`); the viewer's
  reconnect loop then latches onto the stream the moment it's live. The built-in
  **Launch** is the Isaac Sim webrtc launch.
- **Custom launch profiles** — give a workstation extra named launch commands in
  **Settings ▸ Launch profiles** (e.g. an Isaac Lab training run). They appear
  under **Workstation ▸ Launch ▸ &lt;name&gt;** and run verbatim on the box via
  `isaac-ctl run` (base64'd over SSH, so any quoting survives); `Stop` and the
  same auto-latch reconnect apply uniformly.
- **Isaac Lab too** — Lab standalone scripts run with `LIVESTREAM=2` stream the
  identical webrtc protocol on the same `:49100` signaling port, so a Lab box is
  just another workstation entry to *view*; to *launch* one, add a custom profile
  with the Lab command (see below).
- **Clipboard forwarding** — text copied inside the remote Isaac UI (prim paths,
  console logs) lands on the Mac pasteboard.
