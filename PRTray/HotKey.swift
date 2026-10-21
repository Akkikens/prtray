import AppKit
import Carbon.HIToolbox

/// Global ⌥⌘G that opens the menu-bar tray by clicking the status item.
enum HotKey {
    private static var ref: EventHotKeyRef?

    static func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.openTray() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x50525452), id: 1)  // 'PRTR'
        RegisterEventHotKey(UInt32(kVK_ANSI_G), UInt32(optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &ref)
    }

    static func openTray() {
        for w in NSApp.windows where String(describing: type(of: w)).contains("StatusBar") {
            if let b = findButton(in: w.contentView) { b.performClick(nil); return }
        }
    }

    private static func findButton(in v: NSView?) -> NSButton? {
        guard let v else { return nil }
        if let b = v as? NSButton { return b }
        for s in v.subviews { if let b = findButton(in: s) { return b } }
        return nil
    }
}
