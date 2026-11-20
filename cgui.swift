import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

let args = CommandLine.arguments
func err(_ s: String) -> Never { FileHandle.standardError.write((s+"\n").data(using:.utf8)!); exit(2) }
guard args.count >= 2 else { err("usage: cgui list|ax|front <name>|key <text>|keycode <n>|click <x> <y>|axdump <pid> [depth]") }
let cmd = args[1]

func listWindows() {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    if let arr = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] {
        for w in arr {
            let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
            let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0
            let num = w[kCGWindowNumber as String] as? Int ?? 0
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            let name = w[kCGWindowName as String] as? String ?? ""
            let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            print("win=\(num)\tpid=\(pid)\tlayer=\(layer)\towner=\(owner)\tname=\(name.isEmpty ? "-" : name)\tbounds=\(b["X"] ?? 0),\(b["Y"] ?? 0),\(b["Width"] ?? 0),\(b["Height"] ?? 0)")
        }
    }
}

func axDump(_ el: AXUIElement, _ depth: Int, _ maxDepth: Int, _ prefix: String) {
    if depth > maxDepth { return }
    func attr(_ k: String) -> String {
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, k as CFString, &v) == .success, let vv = v {
            if let s = vv as? String { return s }
            if let n = vv as? NSNumber { return "\(n)" }
            return "<\(type(of: vv))>"
        }
        return ""
    }
    let role = attr(kAXRoleAttribute); let sub = attr(kAXSubroleAttribute)
    let title = attr(kAXTitleAttribute); let desc = attr(kAXDescriptionAttribute)
    let value = attr(kAXValueAttribute); let ident = attr(kAXIdentifierAttribute)
    let pos = attr(kAXPositionAttribute); let size = attr(kAXSizeAttribute)
    print("\(prefix)role=\(role) sub=\(sub) title=\(title) desc=\(desc) value=\(value.prefix(120)) id=\(ident) pos=\(pos) size=\(size)")
    var kids: CFTypeRef?
    if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success, let arr = kids as? [AXUIElement] {
        for k in arr.prefix(40) { axDump(k, depth+1, maxDepth, prefix+"  ") }
    }
}

func axDumpPID(_ pid: pid_t, _ maxDepth: Int) {
    axDump(AXUIElementCreateApplication(pid), 0, maxDepth, "")
}

func frontApp(_ name: String) {
    let apps = NSWorkspace.shared.runningApplications
    if let a = apps.first(where: { ($0.localizedName ?? "") == name || ($0.bundleIdentifier ?? "") == name }) {
        print("activate \(a.localizedName ?? "?") pid=\(a.processIdentifier) ok=\(a.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]))")
    } else {
        print("not running: \(name)")
    }
}

func postText(_ text: String) {
    let src = CGEventSource(stateID: .hidSystemState)
    var chars = Array(text.utf16)
    if let d = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
        d.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
        d.post(tap: .cghidEventTap)
    }
    usleep(15000)
    if let u = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
        u.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
        u.post(tap: .cghidEventTap)
    }
    print("typed \(chars.count) utf16 units")
}

func postKeycode(_ code: CGKeyCode) {
    let src = CGEventSource(stateID: .hidSystemState)
    CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
    usleep(30000)
    CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
    print("keycode \(code)")
}

func clickAt(_ x: Double, _ y: Double) {
    let p = CGPoint(x: x, y: y)
    let src = CGEventSource(stateID: .hidSystemState)
    CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(120000)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(60000)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    print("clicked \(x),\(y) trusted=\(AXIsProcessTrusted())")
}

switch cmd {
case "list": listWindows()
case "ax": print("AXIsProcessTrusted=\(AXIsProcessTrusted())")
case "front": guard args.count > 2 else { err("front <name>") }; frontApp(args[2])
case "key": guard args.count > 2 else { err("key <text>") }; postText(args[2])
case "keycode": guard args.count > 2, let c = UInt16(args[2]) else { err("keycode <n>") }; postKeycode(CGKeyCode(c))
case "click": guard args.count > 3, let x = Double(args[2]), let y = Double(args[3]) else { err("click <x> <y>") }; clickAt(x, y)
case "axdump": guard args.count > 2, let pid = Int32(args[2]) else { err("axdump <pid> [depth]") }; axDumpPID(pid_t(pid), args.count > 3 ? (Int(args[3]) ?? 4) : 4)
default: err("unknown \(cmd)")
}
