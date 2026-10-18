import AppKit

/// Local control channel: a Unix domain socket in the data folder, readable only
/// by the current user. One JSON line in, one JSON line out:
///   → {"command": "start", "args": {"task": "Thesis"}}
///   ← {"ok": true, "result": {...}}  or  {"ok": false, "error": "..."}
/// The running app owns all data; the CLI and MCP server only talk through here,
/// so there is never a second process writing the library.
enum ControlSocket {
    static var defaultPath: String { Store.defaultDirectory.appendingPathComponent("control.sock").path }

    // MARK: Server

    @MainActor
    final class Server {
        private let path: String
        private let handler: @MainActor (String, [String: Any]) throws -> Any
        private var listenFD: Int32 = -1
        private var source: DispatchSourceRead?

        init(path: String = ControlSocket.defaultPath, handler: @escaping @MainActor (String, [String: Any]) throws -> Any) {
            self.path = path
            self.handler = handler
        }

        func start() throws {
            unlink(path)
            listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
            guard listenFD >= 0 else { throw CommandError("socket() failed: \(errno)") }
            var addr = try ControlSocket.address(path)
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0 else { close(listenFD); throw CommandError("bind() failed: \(errno)") }
            chmod(path, 0o600)
            guard listen(listenFD, 16) == 0 else { close(listenFD); throw CommandError("listen() failed: \(errno)") }
            let fd = listenFD
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
            source.setEventHandler { [weak self] in
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                self?.serve(client)
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            self.source = source
        }

        func stop() {
            source?.cancel()
            source = nil
            unlink(path)
        }

        nonisolated private func serve(_ fd: Int32) {
            ControlSocket.setTimeout(fd, seconds: 5)
            guard let line = ControlSocket.readLine(fd),
                  let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let command = request["command"] as? String else {
                ControlSocket.writeLine(fd, ["ok": false, "error": "Malformed request."])
                close(fd)
                return
            }
            let args = request["args"] as? [String: Any] ?? [:]
            DispatchQueue.main.async {
                let response: [String: Any]
                do {
                    let result = try MainActor.assumeIsolated { try self.handler(command, args) }
                    response = ["ok": true, "result": result]
                } catch {
                    response = ["ok": false, "error": error.localizedDescription]
                }
                DispatchQueue.global().async {
                    ControlSocket.writeLine(fd, response)
                    close(fd)
                }
            }
        }
    }

    // MARK: Client

    /// Sends one command. If the app is not running and `launch` is set, starts it
    /// in the background and waits for the socket.
    static func send(_ command: String, _ args: [String: Any] = [:], path: String = defaultPath,
                     launch: Bool = true) throws -> Any {
        var fd = connect(path)
        if fd < 0, launch {
            launchApp()
            for _ in 0..<50 where fd < 0 {
                usleep(200_000)
                fd = connect(path)
            }
        }
        guard fd >= 0 else { throw CommandError("Plumb is not running and could not be started.") }
        defer { close(fd) }
        setTimeout(fd, seconds: 10)
        writeLine(fd, ["command": command, "args": args])
        guard let line = readLine(fd), let response = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw CommandError("No response from Plumb.")
        }
        if response["ok"] as? Bool == true { return response["result"] ?? NSNull() }
        throw CommandError(response["error"] as? String ?? "Unknown error.")
    }

    private static func launchApp() {
        // The CLI and MCP server run from inside Plumb.app; open that bundle.
        let bundle = Bundle.main.bundleURL
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = bundle.pathExtension == "app" ? ["-g", bundle.path] : ["-g", "-b", Bundle.main.bundleIdentifier ?? "dev.plumb.timer"]
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: POSIX helpers

    private static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < capacity else { throw CommandError("Socket path too long: \(path)") }
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strncpy($0, path, capacity - 1) }
        }
        return addr
    }

    private static func connect(_ path: String) -> Int32 {
        guard var addr = try? address(path) else { return -1 }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result != 0 { close(fd); return -1 }
        return fd
    }

    fileprivate static func setTimeout(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    fileprivate static func readLine(_ fd: Int32, limit: Int = 4 << 20) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < limit {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
            if let nl = data.firstIndex(of: 0x0A) { return data[..<nl] }
        }
        return data.isEmpty ? nil : data
    }

    fileprivate static func writeLine(_ fd: Int32, _ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }
}
