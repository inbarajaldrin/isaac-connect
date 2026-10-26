// RemoteLauncher — runs isaac-ctl verbs on a workstation over SSH.
//
// The cold-path control plane: it works precisely when nothing sim-side is
// listening (launch/stop/status of the Kit process itself). The hot path is the
// WebRTC stream + the in-process omni.kit.mcp bridge; readiness feedback is the
// viewer's own event-driven reconnect (it latches on the moment :49100 is live),
// so launch doesn't need to block until ready.
//
// Uses the user's own ssh (config, keys, agent) via /usr/bin/ssh. BatchMode=yes
// makes a missing key/known-host fail fast instead of hanging on a prompt a GUI
// app can never answer.

import Foundation

enum RemoteLauncher {

    struct Result {
        let ok: Bool
        let output: String
    }

    /// Run `isaac-ctl <verb>` on the workstation's ssh target. Completion on main.
    @MainActor
    static func run(verb: String, on w: Workstation, completion: @escaping @MainActor (Result) -> Void) {
        let target = w.ssh.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else {
            completion(Result(ok: false, output: "No SSH target set for \(w.name) — add user@host in Settings (⌘,)"))
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // Resolve isaac-ctl robustly: non-interactive ssh does NOT source the login
        // profile, so ~/.local/bin is usually absent from PATH — relying on a bare
        // `isaac-ctl` gives an intermittent "command not found" (it only works on
        // boxes where PATH happens to include it). So invoke the canonical install
        // path explicitly, fall back to PATH, and otherwise emit a CLEAR message
        // (not a raw shell error) so the user knows the box just needs setup.
        // $VARs expand on the REMOTE side. verb is app-controlled (launch/stop/status/
        // run <base64>), never free-form user text, so interpolation is safe.
        let remoteCmd = """
        b="$HOME/.local/bin/isaac-ctl"; \
        if [ -x "$b" ]; then "$b" \(verb); \
        elif command -v isaac-ctl >/dev/null 2>&1; then isaac-ctl \(verb); \
        else echo "isaac-ctl is not installed on this workstation — run the Isaac Sim setup (installs it to ~/.local/bin)" >&2; exit 127; fi
        """
        proc.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
            target,
            remoteCmd,
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        proc.terminationHandler = { p in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let ok = p.terminationStatus == 0
            let status = p.terminationStatus
            Task { @MainActor in
                completion(Result(ok: ok, output: out.isEmpty ? "(no output, exit \(status))" : out))
            }
        }

        do {
            try proc.run()
            NSLog("IsaacConnect: ssh \(target) isaac-ctl \(verb)")
            // Safety valve: never leave a wedged ssh hanging around. launch returns
            // ~2s after spawn; 30s covers a slow first connection comfortably.
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                if proc.isRunning { proc.terminate() }
            }
        } catch {
            completion(Result(ok: false, output: "ssh failed to start: \(error.localizedDescription)"))
        }
    }
}
