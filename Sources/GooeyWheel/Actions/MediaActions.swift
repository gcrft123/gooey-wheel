import AppKit

/// Media actions: the play, next and previous keys, and what is playing.
enum MediaActions {
    /// Presses a media key, which macOS hands to the app playing. Without the Accessibility
    /// permission the key can't be posted, and the now-playing helper sends the same command
    /// to that app instead. Otherwise the key goes first: it reaches apps that take media keys
    /// without telling MediaRemote what they play.
    private static func press(_ key: KeySender.SpecialKey, _ command: NowPlaying.Command) throws {
        if !KeySender.isTrusted, NowPlaying.shared.send(command) { return }
        try KeySender.post(key)
    }

    private static var playing: Bool? { NowPlaying.shared.state?.playing }
    private static var track: String? { NowPlaying.shared.state?.track }

    static let behaviors: [String: ActionBehavior] = {
        // From the first time the wheel looks up an action, so what is playing is known by
        // the time an item is hovered.
        NowPlaying.shared.start()

        var playPause = ActionBehavior(run: { _ in try press(.play, .togglePlayPause) })
        playPause.liveSymbol = { _ in playing.map { $0 ? "pause.fill" : "play.fill" } }
        playPause.liveDetail = { _ in track }

        var controls = ActionBehavior()
        controls.choices = { _ in
            let playPause: (title: String, symbol: String)
            switch playing {
            case true?: playPause = ("Pause", "pause.fill")
            case false?: playPause = ("Play", "play.fill")
            case nil: playPause = ("Play/Pause", "playpause.fill")
            }
            // Each stays open, for pressing Next a few times in a row.
            return [
                LiveChoice(id: "previous", title: "Previous", symbol: "backward.fill", keepsOpen: true),
                LiveChoice(id: "playPause", title: playPause.title, symbol: playPause.symbol, keepsOpen: true),
                LiveChoice(id: "next", title: "Next", symbol: "forward.fill", keepsOpen: true),
            ]
        }
        controls.choose = { choice, _ in
            switch choice.id {
            case "previous": try press(.previous, .previous)
            case "next": try press(.next, .next)
            default: try press(.play, .togglePlayPause)
            }
        }
        controls.liveDetail = { _ in track }

        return [
            "media.playPause": playPause,
            "media.next": ActionBehavior(run: { _ in try press(.next, .next) }),
            "media.previous": ActionBehavior(run: { _ in try press(.previous, .previous) }),
            "media.controls": controls,
        ]
    }()

    // MARK: Checks

    static var tests: [SelfTest.Case] {
        [
            SelfTest.Case("media.keysArePosted") { ctx in
                // Recorded, not posted: a real press would pause or skip what the user hears.
                // Without Accessibility the actions would send real commands through the helper.
                guard KeySender.isTrusted else { try ctx.skip("Accessibility isn't granted") }
                let tap = EventRecorder()
                defer { tap.stop() }
                let expected: [(String, KeySender.SpecialKey)] = [("media.playPause", .play), ("media.next", .next), ("media.previous", .previous)]
                for (id, key) in expected {
                    tap.events.removeAll()
                    try ActionBehaviors.behavior(for: id)?.run?(.current)
                    try ctx.expect(keys(tap.events) == [key.rawValue, key.rawValue], "\(id) posted \(keys(tap.events))")
                }
                let controls = ActionBehaviors.behavior(for: "media.controls")
                for (choice, key) in zip(controls?.choices?(.current) ?? [], [KeySender.SpecialKey.previous, .play, .next]) {
                    tap.events.removeAll()
                    try controls?.choose?(choice, .current)
                    try ctx.expect(keys(tap.events) == [key.rawValue, key.rawValue], "\(choice.id) posted \(keys(tap.events))")
                }
            },
            SelfTest.Case("media.controlsChoices") { ctx in
                let choices = ActionBehaviors.behavior(for: "media.controls")?.choices?(.current) ?? []
                try ctx.expect(choices.map(\.id) == ["previous", "playPause", "next"], "choices \(choices.map(\.id))")
                try ctx.expect(choices.allSatisfy(\.keepsOpen), "every choice keeps the picker open")
                let missing = choices.map(\.symbol).filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
                try ctx.expect(missing.isEmpty, "missing symbols \(missing)")
            },
            SelfTest.Case("media.nowPlayingReads") { ctx in
                guard let library = NowPlaying.libraryURL else { try ctx.skip("the helper library isn't built next to the app") }
                ctx.note(library.lastPathComponent)
                let nowPlaying = NowPlaying.shared
                nowPlaying.start()
                try ctx.expect(ctx.wait(upTo: 3, until: { nowPlaying.state != nil }), "no report from the helper in 3 s")
                guard let state = nowPlaying.state else { return }
                ctx.note(state.track.map { "\(state.playing ? "playing" : "paused") \($0) in \(state.app ?? "?")" } ?? "nothing playing")
                let playPause = ActionBehaviors.behavior(for: "media.playPause")
                try ctx.expect(playPause?.liveSymbol?(.current) == (state.playing ? "pause.fill" : "play.fill"), "play/pause symbol")
                try ctx.expect(playPause?.liveDetail?(.current) == state.track, "play/pause detail")
                let controls = ActionBehaviors.behavior(for: "media.controls")
                try ctx.expect(controls?.liveDetail?(.current) == state.track, "controls detail")
                let symbol = controls?.choices?(.current).first { $0.id == "playPause" }?.symbol
                try ctx.expect(symbol == (state.playing ? "pause.fill" : "play.fill"), "controls play/pause symbol \(symbol ?? "nil")")
            },
            SelfTest.Case("media.nowPlayingHelperQuitsWithTheApp") { ctx in
                let nowPlaying = NowPlaying.shared
                nowPlaying.start()
                guard nowPlaying.isRunning else { try ctx.skip("the helper isn't running") }
                // Closing its input is what the app quitting or crashing does.
                nowPlaying.stop()
                try ctx.expect(ctx.wait(upTo: 2, until: { !nowPlaying.isRunning && nowPlaying.state == nil }), "still running after its input closed")
                nowPlaying.start()
                try ctx.expect(ctx.wait(upTo: 3, until: { nowPlaying.state != nil }), "no report after starting again")
            },
        ]
    }

    /// The media key numbers in recorded events.
    private static func keys(_ events: [CGEvent]) -> [Int] {
        events.compactMap { NSEvent(cgEvent: $0) }.filter { $0.type == .systemDefined && $0.subtype.rawValue == 8 }.map { $0.data1 >> 16 }
    }
}
