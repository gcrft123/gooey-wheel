import AppKit
import Carbon.HIToolbox

// SkyLight's symbolic hot key calls are private. The App Store edition posts the default key combinations instead.
#if !APPSTORE

/// The system's own keyboard shortcuts, such as Mission Control or Move Left a Space, as the
/// window server holds them for this login session. Shortcuts are numbered; System Settings
/// lists their names in KeyboardSettings.appex's DefaultShortcutsTable.xml.
///
/// `press` sends the user's shortcut when one is set. When it is turned off or has no key,
/// the shortcut is lent a combination nobody types for long enough to send it, then given
/// back. Lending changes only the window server's table, never the saved preferences, and a
/// loan cut short by a crash is given back at the next launch.
enum SymbolicHotKey {
    static let screenshotScreen = 28
    static let screenshotSelection = 30
    static let screenshotSelectionToClipboard = 31
    static let spotlight = 64
    static let spaceLeft = 79
    static let spaceRight = 81
    static let notificationCenter = 163
    static let doNotDisturb = 175
    static let stageManager = 222

    /// A shortcut's key as the window server stores it: the character it types (0xFFFF for
    /// keys that type none), the virtual key code (0xFFFF when no key is set) and CGEventFlags
    /// bits for the modifiers.
    struct Value: Equatable, Codable {
        var character: UInt16
        var key: UInt16
        var modifiers: UInt32
        var enabled: Bool

        var hasKey: Bool { key != 0xFFFF }

        var combo: KeyCombo {
            let mask: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]
            return KeyCombo(Int(key), CGEventFlags(rawValue: UInt64(modifiers)).intersection(mask))
        }
    }

    // MARK: The window server's table

    private typealias GetValue = @convention(c) (Int32, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt32>) -> Int32
    private typealias IsEnabled = @convention(c) (Int32) -> Bool
    private typealias SetValue = @convention(c) (Int32, UInt16, UInt16, UInt32) -> Int32
    private typealias SetEnabled = @convention(c) (Int32, Bool) -> Int32

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let getValue = skyLight.flatMap { dlsym($0, "SLSGetSymbolicHotKeyValue") }.map { unsafeBitCast($0, to: GetValue.self) }
    private static let isEnabled = skyLight.flatMap { dlsym($0, "SLSIsSymbolicHotKeyEnabled") }.map { unsafeBitCast($0, to: IsEnabled.self) }
    private static let setValue = skyLight.flatMap { dlsym($0, "SLSSetSymbolicHotKeyValue") }.map { unsafeBitCast($0, to: SetValue.self) }
    private static let setEnabled = skyLight.flatMap { dlsym($0, "SLSSetSymbolicHotKeyEnabled") }.map { unsafeBitCast($0, to: SetEnabled.self) }

    /// Whether this macOS has the calls the table is read and changed with.
    static var isSupported: Bool {
        getValue != nil && isEnabled != nil && setValue != nil && setEnabled != nil
    }

    static func value(_ id: Int) -> Value? {
        guard let getValue, let isEnabled else { return nil }
        var character: UInt16 = 0
        var key: UInt16 = 0
        var modifiers: UInt32 = 0
        guard getValue(Int32(id), &character, &key, &modifiers) == 0 else { return nil }
        return Value(character: character, key: key, modifiers: modifiers, enabled: isEnabled(Int32(id)))
    }

    @discardableResult
    static func write(_ id: Int, _ value: Value) -> Bool {
        guard let setValue, let setEnabled else { return false }
        let set = setValue(Int32(id), value.character, value.key, value.modifiers)
        let enable = setEnabled(Int32(id), value.enabled)
        return set == 0 && enable == 0
    }

    /// The combination that sends a shortcut as the user set it, or nil when it is off or has
    /// no key.
    static func userCombo(_ id: Int) -> KeyCombo? {
        guard let value = value(id), value.enabled, value.hasKey else { return nil }
        return value.combo
    }

    // MARK: Pressing

    /// How long a lent combination stays in the table after it is sent. The window server
    /// matches shortcuts as it takes each key-down from its queue, a few milliseconds after
    /// it is posted; the rest is room for a busy system. Once matched, the press reaches the
    /// shortcut's owner whatever the table says.
    static let loanDuration: TimeInterval = 0.5

    /// Sends a system shortcut. `send` posts the combination; checks pass one that records it.
    static func press(_ id: Int, send: (KeyCombo) throws -> Void = { try KeySender.post($0) }) throws {
        if let combo = userCombo(id) {
            try send(combo)
            return
        }
        try send(try lend(id))
    }

    /// Binds a shortcut that is off or has no key to an unused combination until shortly
    /// after the caller has sent it, and returns the combination.
    static func lend(_ id: Int) throws -> KeyCombo {
        restoreInterrupted()
        guard isSupported, let original = value(id) else {
            throw ActionError.unavailable("system shortcut \(id)")
        }
        if let loan = loans[id] {
            // Still lent from a moment ago. Its original is already saved.
            loan.giveBack.cancel()
            scheduleReturn(id, loan.lent)
            return loan.lent.combo
        }
        guard let lent = unusedValue() else { throw ActionError.failed("No free key combination to send system shortcut \(id)") }
        var saved = savedLoans
        saved[String(id)] = SavedLoan(original: original, lent: lent)
        savedLoans = saved
        guard write(id, lent), value(id) == lent else {
            write(id, original)
            savedLoans.removeValue(forKey: String(id))
            throw ActionError.failed("Couldn't set system shortcut \(id)")
        }
        watchForQuit()
        scheduleReturn(id, lent)
        return lent.combo
    }

    /// Gives back every shortcut that is lent right now.
    static func returnAll() {
        for (id, loan) in loans {
            loan.giveBack.cancel()
            giveBack(id)
        }
    }

    /// Gives back shortcuts a previous run lent and didn't return, such as after a crash.
    /// One the user has changed since, or that a new login has reset, is left alone.
    static func restoreInterrupted() {
        for (key, saved) in savedLoans {
            guard let id = Int(key), loans[id] == nil else { continue }
            if settle(id, saved) { savedLoans.removeValue(forKey: key) }
        }
    }

    // MARK: Loans

    private struct Loan {
        let lent: Value
        let giveBack: DispatchWorkItem
    }

    struct SavedLoan: Codable {
        let original: Value
        let lent: Value
    }

    private static var loans: [Int: Loan] = [:]

    private static func scheduleReturn(_ id: Int, _ lent: Value) {
        let work = DispatchWorkItem { giveBack(id) }
        loans[id] = Loan(lent: lent, giveBack: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + loanDuration, execute: work)
    }

    private static func giveBack(_ id: Int) {
        loans.removeValue(forKey: id)
        guard let saved = savedLoans[String(id)] else { return }
        if settle(id, saved) { savedLoans.removeValue(forKey: String(id)) }
    }

    /// Puts a lent shortcut back. True once nothing is left to do: it was put back, or it no
    /// longer holds the lent combination. A record that couldn't be settled is kept, to try
    /// again at the next launch.
    private static func settle(_ id: Int, _ saved: SavedLoan) -> Bool {
        guard let current = value(id) else { return false }
        guard current == saved.lent else { return true }
        return write(id, saved.original)
    }

    private static let defaultsKey = "LentSymbolicHotKeys"

    /// Loans not yet given back, kept in the app's defaults before the table changes so a
    /// crash can't strand one.
    static var savedLoans: [String: SavedLoan] {
        get {
            guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [:] }
            return (try? JSONDecoder().decode([String: SavedLoan].self, from: data)) ?? [:]
        }
        set {
            if newValue.isEmpty {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            } else if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: defaultsKey)
            }
        }
    }

    /// Whether any shortcut is recorded as lent. For checks.
    static var hasSavedLoans: Bool { !savedLoans.isEmpty }

    private static var watchingForQuit = false

    private static func watchForQuit() {
        guard !watchingForQuit else { return }
        watchingForQuit = true
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            returnAll()
        }
    }

    /// ⌃⌥⇧⌘ with a function key from F13 up, which keyboards rarely have and nobody binds,
    /// skipping any combination a system shortcut or another loan already uses.
    private static func unusedValue() -> Value? {
        let modifiers = CGEventFlags([.maskControl, .maskAlternate, .maskShift, .maskCommand, .maskSecondaryFn]).rawValue
        let keys = [kVK_F19, kVK_F18, kVK_F17, kVK_F16, kVK_F20, kVK_F15, kVK_F14, kVK_F13]
        var taken = Set(loans.values.map(\.lent.key))
        for id in 0..<300 {
            if let value = value(id), value.enabled, UInt64(value.modifiers) == modifiers { taken.insert(value.key) }
        }
        guard let key = keys.first(where: { !taken.contains(UInt16($0)) }) else { return nil }
        return Value(character: 0xFFFF, key: UInt16(key), modifiers: UInt32(modifiers), enabled: true)
    }
}
#endif
