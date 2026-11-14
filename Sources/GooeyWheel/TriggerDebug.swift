import AppKit

/// A diagnostic for the thumb button, off by default. Turn it on with
/// `defaults write dev.gooey.wheel TriggerDebug -bool YES` and relaunch.
///
/// It logs every stage of a press, from the mouse's messages on both channels to the wheel's
/// state, along with clicks, app switches, sleep, and main-thread stalls, to
/// `~/Library/Logs/Gooey Wheel/trigger.log`.
enum TriggerDebug {
    static let enabled = UserDefaults.standard.bool(forKey: "TriggerDebug")

    /// The wheel's state, added to each event.
    static var wheelState: () -> String = { "" }

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        LogFile.shared.write(message())
    }

    /// Logs an event along with the wheel's state.
    static func event(_ message: String) {
        guard enabled else { return }
        LogFile.shared.write("\(message) \(wheelState())")
    }

    private static var started = false
    private static var monitors: [Any] = []

    static func start() {
        guard enabled, !started else { return }
        started = true
        log("launch, pid \(ProcessInfo.processInfo.processIdentifier)")
        watchMainThread()

        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { logClick($0, inApp: false) }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { logClick($0, inApp: true); return $0 }) {
            monitors.append(local)
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            log("frontmost app: \(app?.localizedName ?? "?")")
        }
        for (name, label) in [(NSWorkspace.willSleepNotification, "sleep"), (NSWorkspace.didWakeNotification, "wake"),
                              (NSWorkspace.screensDidSleepNotification, "screens sleep"), (NSWorkspace.screensDidWakeNotification, "screens wake")] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in log(label) }
        }
    }

    private static func logClick(_ event: NSEvent, inApp: Bool) {
        let name: String
        switch event.type {
        case .leftMouseDown: name = "left down"
        case .leftMouseUp: name = "left up"
        case .rightMouseDown: name = "right down"
        case .rightMouseUp: name = "right up"
        case .otherMouseDown: name = "button \(event.buttonNumber) down"
        default: name = "button \(event.buttonNumber) up"
        }
        let p = NSEvent.mouseLocation
        log("mouse \(name) at \(Int(p.x)),\(Int(p.y))\(inApp ? " (in app)" : "")")
    }

    /// Logs any stretch longer than 100 ms in which the main thread doesn't answer.
    private static func watchMainThread() {
        let thread = Thread {
            while true {
                let sent = Date()
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                if answered.wait(timeout: .now() + 0.1) == .timedOut {
                    answered.wait()
                    log(String(format: "STALL main thread blocked %.0f ms", Date().timeIntervalSince(sent) * 1000))
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

}

private final class LogFile {
    static let shared = LogFile()
    private let handle: FileHandle?
    private let lock = NSLock()
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Gooey Wheel")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("trigger.log")
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: file)
        _ = try? handle?.seekToEnd()
    }

    func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        handle?.write(Data("\(formatter.string(from: Date())) \(line)\n".utf8))
    }
}
