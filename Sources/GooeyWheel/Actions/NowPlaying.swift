import AppKit

/// What is playing, kept up to date in the background so the wheel can read it at once.
///
/// Since macOS 15.4 MediaRemote, which knows what is playing, only answers processes signed
/// by Apple. A helper library (the NowPlayingHelper target) is loaded into /usr/bin/perl, one
/// such process, and reports each change as a line of JSON. The approach is that of
/// ungive/mediaremote-adapter (BSD-3-Clause).
///
/// The helper runs for as long as the app does. Between changes it waits in its run loop and
/// uses no CPU; starting it when the wheel opens instead would leave the first hover with
/// nothing to show for the 100 ms or so it takes to answer. It quits when its standard input
/// closes, which happens when the app quits or crashes. When perl or the library is missing,
/// or MediaRemote doesn't answer, `state` stays nil and the media keys still work.
final class NowPlaying {
    static let shared = NowPlaying()

    struct State: Equatable, Decodable {
        var playing: Bool
        var title: String?
        var artist: String?
        var album: String?
        /// The bundle identifier of the app playing.
        var app: String?

        /// "Title — Artist", or as much of it as is known.
        var track: String? {
            let parts = [title, artist].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " — ")
        }
    }

    /// MediaRemote's numbers for the commands sent here.
    enum Command: Int {
        case togglePlayPause = 2
        case next = 4
        case previous = 5
    }

    /// What the helper last reported, or nil when it hasn't, or can't run on this Mac.
    private(set) var state: State?
    private var process: Process?
    private var input: FileHandle?
    private var output = Data()
    /// Launches in a row that ended without reporting anything.
    private var failures = 0
    private var stopping = false

    private static let perl = URL(fileURLWithPath: "/usr/bin/perl")
    private static let loader = """
        use DynaLoader;
        my $library = DynaLoader::dl_load_file($ARGV[0], 0) or exit 3;
        my $run = DynaLoader::dl_find_symbol($library, "gooey_now_playing_run") or exit 3;
        DynaLoader::dl_install_xsub("main::run", $run);
        main::run();
        """

    /// The helper library: in the app's Frameworks folder, or next to the executable in a
    /// `swift build` folder.
    static var libraryURL: URL? {
        let name = "libGooeyNowPlaying.dylib"
        guard let folder = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() else { return nil }
        return [folder.deletingLastPathComponent().appendingPathComponent("Frameworks/\(name)"), folder.appendingPathComponent(name)]
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stop()
            self?.process?.terminate()
        }
    }

    var isRunning: Bool { process?.isRunning == true }

    /// Starts the helper unless it is running or has failed to start three times in a row.
    func start() {
        guard process == nil, failures < 3, let library = Self.libraryURL,
              FileManager.default.isExecutableFile(atPath: Self.perl.path) else { return }
        // A write to a helper that has just quit fails instead of ending the app.
        signal(SIGPIPE, SIG_IGN)
        stopping = false
        let process = Process()
        process.executableURL = Self.perl
        process.arguments = ["-e", Self.loader, library.path]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { self?.received(data) }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.ended() }
        }
        do {
            try process.run()
        } catch {
            failures = 3
            return
        }
        self.process = process
        self.input = input.fileHandleForWriting
    }

    /// Ends the helper by closing its standard input, as quitting the app does.
    func stop() {
        stopping = true
        try? input?.close()
        input = nil
    }

    /// Sends a command to the app playing. Returns false when the helper isn't running.
    @discardableResult
    func send(_ command: Command) -> Bool {
        guard isRunning, let input else { return false }
        do {
            try input.write(contentsOf: Data("\(command.rawValue)\n".utf8))
            return true
        } catch {
            return false
        }
    }

    private func received(_ data: Data) {
        output.append(data)
        while let newline = output.firstIndex(of: UInt8(ascii: "\n")) {
            let line = output[output.startIndex..<newline]
            output.removeSubrange(output.startIndex...newline)
            guard let state = try? JSONDecoder().decode(State.self, from: line) else { continue }
            failures = 0
            update(state)
        }
    }

    private func ended() {
        process = nil
        input = nil
        output.removeAll()
        update(nil)
        if stopping { return }
        failures += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.start() }
    }

    private func update(_ state: State?) {
        guard state != self.state else { return }
        self.state = state
        NotificationCenter.default.post(name: ActionBehaviors.stateDidChange, object: nil)
    }
}
