import AppKit

// Spawns programs, which only actions the App Store edition leaves out do.
#if !APPSTORE

/// A program run to completion in the background, with what it printed. It runs in a process
/// group of its own, so a time limit stops whatever it started as well, not only the program.
struct ChildProcess {
    var executable: String
    var arguments: [String] = []
    /// The working directory. Nil keeps this process's.
    var directory: String? = nil
    /// The whole environment. Nil passes on this process's.
    var environment: [String: String]? = nil
    /// How long it may run before it is stopped, in seconds.
    var timeout: TimeInterval = 300

    struct Result {
        /// The exit status, or 128 plus the signal that ended it.
        var status: Int32
        var output: String
        var errorOutput: String
        var timedOut: Bool

        var succeeded: Bool { status == 0 && !timedOut }

        /// The last lines of what it printed to standard error, for a log line.
        func errorTail(lines: Int = 5) -> String {
            let text = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
        }
    }

    /// Output past this many bytes per stream keeps only its end.
    private static let outputLimit = 256 * 1024
    /// How long a stopped program has after SIGTERM before it gets SIGKILL.
    private static let killGrace: TimeInterval = 3
    /// How long to keep reading after the program exits, for anything it left running that
    /// still holds its output open.
    private static let drainGrace: TimeInterval = 1

    /// Runs it and waits for it to finish. Blocks, so call it off the main thread.
    func run() throws -> Result {
        let out = try Self.makePipe()
        let err = try Self.makePipe()
        var spawned = false
        defer {
            if !spawned { [out[0], out[1], err[0], err[1]].forEach { close($0) } }
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, out[1], 1)
        posix_spawn_file_actions_adddup2(&actions, err[1], 2)
        if let directory { posix_spawn_file_actions_addchdir_np(&actions, directory) }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A new process group, no other open files, and default signal handling.
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attributes, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let envp = (environment ?? ProcessInfo.processInfo.environment).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envp.forEach { free($0) } }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard status == 0 else {
            throw ActionError.failed("Couldn't run \(executable): \(String(cString: strerror(status)))")
        }
        spawned = true
        // Our copies of the write ends, so the readers see the end of the output.
        close(out[1])
        close(err[1])
        let stdout = Reader(out[0], limit: Self.outputLimit)
        let stderr = Reader(err[0], limit: Self.outputLimit)

        let exited = DispatchSemaphore(value: 0)
        var waitStatus: Int32 = 0
        DispatchQueue.global(qos: .utility).async {
            while waitpid(pid, &waitStatus, 0) == -1, errno == EINTR {}
            exited.signal()
        }
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            killpg(pid, SIGTERM)
            if exited.wait(timeout: .now() + Self.killGrace) == .timedOut {
                killpg(pid, SIGKILL)
                exited.wait()
            }
        }

        let code: Int32 = waitStatus & 0x7F == 0 ? (waitStatus >> 8) & 0xFF : 128 + (waitStatus & 0x7F)
        return Result(
            status: code,
            output: String(decoding: stdout.finish(within: Self.drainGrace), as: UTF8.self),
            errorOutput: String(decoding: stderr.finish(within: Self.drainGrace), as: UTF8.self),
            timedOut: timedOut
        )
    }

    /// Runs it on a background queue and calls `completion` there when it has finished.
    func start(_ completion: @escaping (Swift.Result<Result, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            completion(Swift.Result { try run() })
        }
    }

    private static func makePipe() throws -> [Int32] {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw ActionError.failed("Couldn't make a pipe: \(String(cString: strerror(errno)))") }
        return fds
    }

    /// Collects what arrives on a file descriptor until it ends, keeping at most `limit` bytes.
    private final class Reader {
        private let source: DispatchSourceRead
        private let done = DispatchSemaphore(value: 0)
        private var data = Data()

        init(_ fd: Int32, limit: Int) {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "GooeyWheel.ChildProcess.Reader"))
            source.setEventHandler { [unowned self] in
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    data.append(contentsOf: buffer[0..<count])
                    if data.count > limit { data.removeFirst(data.count - limit) }
                } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                    source.cancel()
                }
            }
            source.setCancelHandler { [unowned self] in
                close(fd)
                done.signal()
            }
            source.resume()
        }

        /// What was read, once the output ends or `seconds` have passed, whichever is first.
        func finish(within seconds: TimeInterval) -> Data {
            if done.wait(timeout: .now() + seconds) == .timedOut {
                source.cancel()
                done.wait()
            }
            return data
        }
    }
}
#endif
