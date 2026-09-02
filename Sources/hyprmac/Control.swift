import AppKit
import HyprCore
import HyprKit

/// The `hyprctl` of hyprmac: a Unix socket that answers questions about the
/// desktop and carries out dispatchers.
///
/// One JSON object per line in, one out, and the connection closes — simple
/// enough for `nc -U` from a shell, which is what `scripts/wispctl` is. This is
/// the only door Wisper uses to see the screen or touch a window, so exactly one
/// process holds the Accessibility grant and there is one place to audit.
///
/// The socket lives in `$TMPDIR`, macOS's per-user equivalent of
/// `XDG_RUNTIME_DIR`: mode 0700, so only this user can reach it.
final class ControlSocket {
    static var path: String { NSTemporaryDirectory() + "hyprmac.sock" }

    private let handler: ([String: Any]) -> [String: Any]
    private var listener: Int32 = -1
    private let queue = DispatchQueue(label: "hyprmac.control")

    init(handler: @escaping ([String: Any]) -> [String: Any]) {
        self.handler = handler
    }

    func start() {
        let path = Self.path
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { log("control: socket() failed"); return }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            log("control: socket path too long: \(path)"); close(fd); return
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = UInt8(bitPattern: byte) }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            log("control: bind/listen failed on \(path): \(String(cString: strerror(errno)))")
            close(fd); return
        }
        listener = fd
        log("control: listening on \(path)")
        queue.async { [weak self] in self?.acceptLoop(fd) }
    }

    func stop() {
        guard listener >= 0 else { return }
        close(listener)
        listener = -1
        unlink(Self.path)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }   // listener closed
            serve(client)
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !data.contains(UInt8(ascii: "\n")) {
            let n = read(client, &chunk, chunk.count)
            guard n > 0 else { break }
            data.append(contentsOf: chunk[0..<n])
            if data.count > 1 << 20 { break }
        }
        let line = data.split(separator: UInt8(ascii: "\n"), maxSplits: 1).first.map { Data($0) } ?? data
        let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            ?? ["error": "expected one JSON object per line"]

        // Everything the handler touches is main-thread state.
        var response: [String: Any] = [:]
        DispatchQueue.main.sync { response = self.handler(request) }

        guard var out = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]) else { return }
        out.append(UInt8(ascii: "\n"))
        out.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = write(client, bytes.baseAddress! + offset, bytes.count - offset)
                guard n > 0 else { break }
                offset += n
            }
        }
    }
}
