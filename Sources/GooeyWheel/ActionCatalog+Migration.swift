import Foundation

/// Actions that were merged into others or retired. A saved item that uses one is moved to
/// its replacement when the wheel loads.
enum ActionMigration {
    private struct Target {
        let id: String?
        var argument: String? = nil
        /// The old action's name, kept on an item whose action is gone so it still says what it was.
        var formerTitle: String? = nil
    }

    /// A folder in the home folder, written the way the folder field writes it.
    private static func folder(_ name: String) -> String {
        name.isEmpty ? "~" : "~/" + name
    }

    private static let map: [String: Target] = {
        var map: [String: Target] = [
            "media.stop": Target(id: "media.playPause"),
            "media.volumeUp": Target(id: "media.volume"),
            "media.volumeDown": Target(id: "media.volume"),
            "media.setVolume": Target(id: "media.volume"),
            "media.shuffle": Target(id: "media.controls"),
            "media.repeat": Target(id: "media.controls"),
            "media.repeatOne": Target(id: "media.controls"),
            "media.nowPlaying": Target(id: "media.controls"),
            "media.skipAhead": Target(id: nil, formerTitle: "Skip Ahead"),
            "media.skipBack": Target(id: nil, formerTitle: "Skip Back"),
            "media.captions": Target(id: nil, formerTitle: "Captions"),
            "media.pictureInPicture": Target(id: nil, formerTitle: "Picture in Picture"),
            "media.playbackSpeed": Target(id: nil, formerTitle: "Playback Speed"),
            "system.screenshotArea": Target(id: "system.screenshot", argument: "selection"),
            "system.screenshotWindow": Target(id: "system.screenshot", argument: "window"),
            "system.screenRecording": Target(id: "system.screenshot", argument: "toolbar"),
            "system.focus": Target(id: "system.doNotDisturb"),
            "system.brightnessUp": Target(id: "system.brightness"),
            "system.brightnessDown": Target(id: "system.brightness"),
            "system.backlightUp": Target(id: "system.keyboardBrightness"),
            "system.backlightDown": Target(id: "system.keyboardBrightness"),
            "edit.zoomIn": Target(id: "edit.zoom"),
            "edit.zoomOut": Target(id: "edit.zoom"),
            "edit.actualSize": Target(id: "edit.zoom"),
            "edit.close": Target(id: "edit.closeTab"),
            "navigation.pageUp": Target(id: nil, formerTitle: "Page Up"),
            "navigation.pageDown": Target(id: nil, formerTitle: "Page Down"),
            "navigation.scrollLeft": Target(id: nil, formerTitle: "Scroll Left"),
            "navigation.scrollRight": Target(id: nil, formerTitle: "Scroll Right"),
            "navigation.scrollUp": Target(id: nil, formerTitle: "Scroll Up"),
            "navigation.scrollDown": Target(id: nil, formerTitle: "Scroll Down"),
            "navigation.lineStart": Target(id: nil, formerTitle: "Line Start"),
            "navigation.lineEnd": Target(id: nil, formerTitle: "Line End"),
            "mouse.leftClick": Target(id: nil, formerTitle: "Left Click"),
            "mouse.rightClick": Target(id: nil, formerTitle: "Right Click"),
            "mouse.middleClick": Target(id: nil, formerTitle: "Middle Click"),
            "mouse.doubleClick": Target(id: nil, formerTitle: "Double Click"),
            "mouse.swapButtons": Target(id: nil, formerTitle: "Swap Buttons"),
            "mouse.backButton": Target(id: "navigation.back"),
            "mouse.forwardButton": Target(id: "navigation.forward"),
            "mouse.cycleDPI": Target(id: "mouse.pointerSpeed"),
            "apps.downloads": Target(id: "apps.openFolder", argument: folder("Downloads")),
            "apps.desktop": Target(id: "apps.openFolder", argument: folder("Desktop")),
            "apps.documents": Target(id: "apps.openFolder", argument: folder("Documents")),
            "apps.homeFolder": Target(id: "apps.openFolder", argument: folder("")),
            "apps.trash": Target(id: "apps.openFolder", argument: folder(".Trash")),
            "apps.applications": Target(id: "apps.openFolder", argument: "/Applications"),
            "automation.openURL": Target(id: "apps.openWebsite"),
            "device.easySwitch1": Target(id: "device.easySwitch"),
            "device.easySwitch2": Target(id: "device.easySwitch"),
            "device.easySwitch3": Target(id: "device.easySwitch"),
        ]
        let layouts = ["leftHalf", "rightHalf", "topHalf", "bottomHalf", "topLeft", "topRight", "bottomLeft", "bottomRight",
                       "leftThird", "rightThird", "maximize", "center", "restore"]
        for layout in layouts {
            map["desktop." + layout] = Target(id: "window.move", argument: layout)
        }
        return map
    }()

    /// Actions that kept their id but no longer take the argument they used to.
    private static let droppedArguments: Set<String> = ["system.appearance", "mouse.scrollDirection", "media.volume", "mouse.pointerSpeed"]

    /// The item with any retired action replaced. Folders are migrated item by item.
    static func migrate(_ item: WheelItem) -> WheelItem {
        var item = item
        if let children = item.children {
            item.children = children.map(migrate)
            return item
        }
        guard let id = item.actionID else { return item }
        if let target = map[id] {
            item.actionID = target.id
            item.argument = target.argument
            if target.id == nil, item.customTitle?.isEmpty ?? true { item.customTitle = target.formerTitle }
        } else if droppedArguments.contains(id) {
            item.argument = nil
        }
        return item
    }
}
