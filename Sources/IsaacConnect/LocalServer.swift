// Minimal loopback HTTP/1.0 static file server.
//
// Why this exists: the bundled Isaac renderer loads its JS via
// <script type="module">, which requires a CORS-eligible (non-null) origin.
// A file:// origin is null and WebKit silently refuses to run the module, so
// the React app never mounts. Serving the same files over http://127.0.0.1
// gives a real origin and the renderer mounts normally.
//
// It binds to 127.0.0.1 on an ephemeral port, serves only the files under the
// given root, one request per connection (Connection: close). Sufficient for
// the renderer's three GETs (index.html, the JS bundle, the CSS).

import Foundation

final class LocalServer: @unchecked Sendable {
    private let root: URL
    private(set) var port: UInt16 = 0
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "isaacviewer.localserver", attributes: .concurrent)

    init(root: URL) {
        self.root = root
    }

    /// Bind + start accepting. Returns the chosen port, or nil on failure.
    @discardableResult
    func start() -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                                   // ephemeral port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")      // loopback only

        let bindOK = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard bindOK else { close(fd); return nil }
        guard listen(fd, 16) == 0 else { close(fd); return nil }

        // Read back the assigned port.
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let gotPort = withUnsafeMutablePointer(to: &bound) { ptr -> Bool in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &len) == 0
            }
        }
        guard gotPort else { close(fd); return nil }
        self.port = UInt16(bigEndian: bound.sin_port)
        self.listenFD = fd

        queue.async { [weak self] in self?.acceptLoop() }
        return self.port
    }

    func stop() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
    }

    private func acceptLoop() {
        while listenFD >= 0 {
            let client = accept(listenFD, nil, nil)
            if client < 0 { break }
            queue.async { [weak self] in self?.handle(client) }
        }
    }

    private func handle(_ client: Int32) {
        defer { close(client) }

        // Read the request line (enough for "GET /path HTTP/1.x").
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(client, &buf, buf.count)
        guard n > 0 else { return }
        guard let req = String(bytes: buf[0..<n], encoding: .utf8) else { return }
        let firstLine = req.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            send(client, status: "400 Bad Request", contentType: "text/plain", body: Data("bad request".utf8))
            return
        }

        var path = String(parts[1])
        if let q = path.firstIndex(of: "?") { path = String(path[path.startIndex..<q]) }
        if path == "/" { path = "/index.html" }
        // Strip leading slash; reject path traversal.
        let rel = String(path.drop(while: { $0 == "/" }))
        if rel.contains("..") {
            send(client, status: "403 Forbidden", contentType: "text/plain", body: Data("forbidden".utf8))
            return
        }

        let fileURL = root.appendingPathComponent(rel)
        guard let data = try? Data(contentsOf: fileURL) else {
            send(client, status: "404 Not Found", contentType: "text/plain", body: Data("not found".utf8))
            return
        }
        send(client, status: "200 OK", contentType: Self.contentType(for: rel), body: data)
    }

    private func send(_ client: Int32, status: String, contentType: String, body: Data) {
        var header = "HTTP/1.0 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "\r\n"
        var out = Data(header.utf8)
        out.append(body)
        out.withUnsafeBytes { raw in
            var off = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while off < out.count {
                let w = write(client, base + off, out.count - off)
                if w <= 0 { break }
                off += w
            }
        }
    }

    private static func contentType(for path: String) -> String {
        if path.hasSuffix(".html") { return "text/html; charset=utf-8" }
        if path.hasSuffix(".js")   { return "text/javascript; charset=utf-8" }
        if path.hasSuffix(".css")  { return "text/css; charset=utf-8" }
        if path.hasSuffix(".json") { return "application/json" }
        if path.hasSuffix(".png")  { return "image/png" }
        if path.hasSuffix(".svg")  { return "image/svg+xml" }
        return "application/octet-stream"
    }
}
