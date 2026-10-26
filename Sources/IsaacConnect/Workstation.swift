// Workstation model + persistent store.
//
// A Workstation is one Isaac Sim WebRTC server you register in the app: a friendly
// name, the host (Tailscale IP / DNS) we open ws://<host>:<port> against, and the
// box's SSH user@host.
//
// Persisted as app-owned JSON at
//   ~/Library/Application Support/IsaacViewer/workstations.json
// First run starts empty — you add your workstation(s) in Settings.

import Foundation

/// A named custom launch command for a workstation — the "other launch scripts"
/// beyond the built-in Isaac Sim launch (e.g. an Isaac Lab training run). The
/// command runs verbatim on the box via `isaac-ctl run` (base64'd over SSH), so
/// it can be a full pipeline: `LIVESTREAM=2 <venv-python> <script> --kit_args …`.
struct LaunchProfile: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String            // menu label, e.g. "Cartpole training"
    var command: String         // full remote command line (box-local paths)
}

struct Workstation: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var host: String            // ws://<host>:<port> signaling/stream target
    var ssh: String = ""        // SSH user@host for the workstation
    var port: Int = 49100
    // Custom launch commands beyond the built-in Isaac Sim launch. Optional in the
    // JSON so older files (and the common no-custom-profiles case) decode cleanly.
    var launchProfiles: [LaunchProfile] = []

    /// Normalized host and port used to enforce one window per streaming endpoint,
    /// even when multiple workstation rows point at the same endpoint.
    var endpoint: String { "\(host.trimmingCharacters(in: .whitespaces).lowercased()):\(port)" }

    init(id: UUID = UUID(), name: String, host: String, ssh: String = "",
         port: Int = 49100, launchProfiles: [LaunchProfile] = []) {
        self.id = id; self.name = name; self.host = host
        self.ssh = ssh; self.port = port; self.launchProfiles = launchProfiles
    }

    // Custom decoder so files written before launchProfiles existed still load —
    // the synthesized decoder would throw keyNotFound (a default value doesn't
    // rescue a missing key), which would wrongly trip the corrupt-file backup.
    private enum CodingKeys: String, CodingKey { case id, name, host, ssh, port, launchProfiles }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        ssh = try c.decodeIfPresent(String.self, forKey: .ssh) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 49100
        launchProfiles = try c.decodeIfPresent([LaunchProfile].self, forKey: .launchProfiles) ?? []
    }
}

@MainActor
final class WorkstationStore {
    static let shared = WorkstationStore()

    private(set) var workstations: [Workstation] = []
    var onChange: (() -> Void)?

    // Keep the existing settings directory so renaming the app retains saved workstations.
    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IsaacViewer", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("workstations.json")
    }()

    private struct Persisted: Codable { var workstations: [Workstation] }

    init() { load() }

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // No saved file yet → start empty; the user registers their workstation(s)
            // in Settings (name / host / SSH).
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            workstations = try JSONDecoder().decode(Persisted.self, from: data).workstations
        } catch {
            // The file exists but is unreadable/corrupt. Preserve it (rather than let a
            // later save silently clobber it) and start empty so the app still launches.
            let backup = fileURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            NSLog("IsaacConnect: workstations.json unreadable (\(error)); moved to \(backup.lastPathComponent), starting empty")
        }
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try enc.encode(Persisted(workstations: workstations))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("IsaacConnect: failed to save workstations.json: \(error)")
        }
    }

    func workstation(id: UUID) -> Workstation? { workstations.first { $0.id == id } }
    func workstation(host: String) -> Workstation? { workstations.first { $0.host == host } }

    func add(_ w: Workstation) { workstations.append(w); save(); onChange?() }
    func remove(id: UUID) { workstations.removeAll { $0.id == id }; save(); onChange?() }
    func update(_ w: Workstation) {
        guard let i = workstations.firstIndex(where: { $0.id == w.id }) else { return }
        workstations[i] = w; save(); onChange?()
    }

}
