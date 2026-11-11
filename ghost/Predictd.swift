// Client for predictd, the model host: newline-delimited JSON over its unix socket. Generic, not tied to any policy.
import Foundation

let SOCK = "/tmp/predictd-\(getuid()).sock"
let PREDICTD_LOG = "/tmp/predictd-\(getuid()).log"

/// This binary (symlinks resolved), and the directory holding the engine next to it: ghostd, predictd, predictd.json, VERSION,
/// ghost/, bench/ (the repo, or the app's Resources/engine).
let EXECUTABLE: String = {
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
    var size = UInt32(buf.count)
    _ = _NSGetExecutablePath(&buf, &size)
    return URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath().path
}()
let ROOT = (EXECUTABLE as NSString).deletingLastPathComponent

struct PredictdError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

private let idLock = NSLock()
private var nextID = 0
private func newID() -> String {
    idLock.lock(); defer { idLock.unlock() }
    nextID += 1
    return "r\(nextID)"
}

/// One connection to the daemon; `call` sends a request and waits for the answer with the same id.
final class Link {
    private let fd: Int32
    private var buf = Data()

    init(_ path: String = SOCK) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PredictdError("socket failed") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); throw PredictdError("socket path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { p in
            p.copyBytes(from: bytes)
            p[bytes.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { close(fd); throw PredictdError("cannot connect to \(path)") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close(fd) }

    @discardableResult
    func send(_ req: [String: Any]) throws -> String {
        var r = req
        let id = (r["id"] as? String) ?? newID()
        r["id"] = id
        var data = jsonData(r)
        data.append(0x0A)
        try data.withUnsafeBytes { p in
            var off = 0
            while off < p.count {
                let n = write(fd, p.baseAddress! + off, p.count - off)
                if n <= 0 { throw PredictdError("predictd closed the connection") }
                off += n
            }
        }
        return id
    }

    /// Send and wait for the answer (other messages on this connection are dropped).
    func call(_ req: [String: Any], timeout: Double = 30) throws -> [String: Any] {
        let id = try send(req)
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            while let nl = buf.firstIndex(of: 0x0A) {
                let line = buf[buf.startIndex..<nl]
                buf = Data(buf[buf.index(after: nl)...])
                if let m = jsonObject(Data(line)) as? [String: Any], m["id"] as? String == id { return m }
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let left = max(0, Int32(end.timeIntervalSinceNow * 1000))
            if poll(&pfd, 1, min(left, 50)) > 0 {
                var chunk = [UInt8](repeating: 0, count: 1 << 16)
                let n = read(fd, &chunk, chunk.count)
                if n == 0 { throw PredictdError("predictd closed the connection") }
                if n > 0 { buf.append(contentsOf: chunk[0..<n]) }
            }
        }
        throw PredictdError("no answer from predictd to \(req["op"] ?? "?")")
    }
}

/// Connect to the daemon on `path`, starting it first if nobody answers there. `noUser`: the shipped predictd.json only
/// (benchmarks).
func startPredictd(_ path: String = SOCK, noUser: Bool = false, wait: Double = 40) throws -> Link {
    if let l = try? Link(path) { return l }
    let binary = ROOT + "/predictd"
    guard FileManager.default.isExecutableFile(atPath: binary) else { throw PredictdError("\(binary) not found: run build.sh first") }
    try spawnDetached(binary, ["--socket", path] + (noUser ? ["--user-config", ""] : []), log: PREDICTD_LOG)
    let end = Date().addingTimeInterval(wait)
    while Date() < end {
        Thread.sleep(forTimeInterval: 0.1)
        if let l = try? Link(path) { return l }
    }
    throw PredictdError("predictd did not come up, see \(PREDICTD_LOG)")
}

/// Start a program in its own session (it outlives us and ignores our terminal's Ctrl-C), output appended to `log`.
func spawnDetached(_ path: String, _ args: [String], log: String) throws {
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    var fa: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fa)
    defer { posix_spawn_file_actions_destroy(&fa) }
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&fa, 1, log, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    posix_spawn_file_actions_adddup2(&fa, 1, 2)
    let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, path, &fa, &attr, argv, environ)
    guard rc == 0 else { throw PredictdError("cannot start \(path): \(String(cString: strerror(rc)))") }
    DispatchQueue.global().async { var st: Int32 = 0; waitpid(pid, &st, 0) }   // reap it when it exits
}
