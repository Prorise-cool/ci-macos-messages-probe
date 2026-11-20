import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

let args = CommandLine.arguments
func out(_ s: String) { print(s) }
func err(_ s: String) -> Never { FileHandle.standardError.write((s+"\n").data(using:.utf8)!); exit(2) }
guard args.count >= 2 else { err("usage: cgui list|ax|front <name>|key <text>|keycode <n>|click <x> <y>|axdump <pid> [depth]|axwinls <pid>|axfind <pid> <needle>|axset <pid> <needle> <text>|axpress <pid> <needle>|axfocus <pid> <needle>|axfindin <pid> <winsubrole> <needle>|axpressin <pid> <winsubrole> <needle>|axfillin <pid> <winsubrole> <text>") }
let cmd = args[1]

// ---------------------------------------------------------------- AX helpers
func attr(_ el: AXUIElement, _ k: String) -> CFTypeRef? {
    var v: CFTypeRef?
    if AXUIElementCopyAttributeValue(el, k as CFString, &v) == .success { return v }
    return nil
}
func sattr(_ el: AXUIElement, _ k: String) -> String {
    guard let v = attr(el, k) else { return "" }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return "\(n)" }
    return "<\(type(of: v))>"
}
func axPoint(_ el: AXUIElement) -> CGPoint? {
    guard let v = attr(el, kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero
    if AXValueGetValue(v as! AXValue, AXValueType.cgPoint, &p) { return p }
    return nil
}
func axSize(_ el: AXUIElement) -> CGSize? {
    guard let v = attr(el, kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var s = CGSize.zero
    if AXValueGetValue(v as! AXValue, AXValueType.cgSize, &s) { return s }
    return nil
}
func axPosStr(_ el: AXUIElement) -> String {
    if let p = axPoint(el), let s = axSize(el) {
        return "pos=\(Int(p.x)),\(Int(p.y)) size=\(Int(s.width))x\(Int(s.height)) center=\(Int(p.x + s.width/2)),\(Int(p.y + s.height/2))"
    }
    if let p = axPoint(el) { return "pos=\(Int(p.x)),\(Int(p.y)) size=?" }
    return "pos=? size=?"
}
func axEnabled(_ el: AXUIElement) -> String {
    guard let v = attr(el, kAXEnabledAttribute) as? NSNumber else { return "" }
    return "enabled=\(v.boolValue)"
}
func axActions(_ el: AXUIElement) -> String {
    var names: CFArray?
    if AXUIElementCopyActionNames(el, &names) == .success, let a = names as? [String] { return "actions=[\(a.joined(separator: ","))]" }
    return ""
}
func line(_ el: AXUIElement, _ depth: Int) -> String {
    let pad = String(repeating: "  ", count: depth)
    let val = sattr(el, kAXValueAttribute)
    return "\(pad)role=\(sattr(el, kAXRoleAttribute)) sub=\(sattr(el, kAXSubroleAttribute)) title=[\(sattr(el, kAXTitleAttribute))] desc=[\(sattr(el, kAXDescriptionAttribute))] value=[\(val.prefix(80))] id=[\(sattr(el, kAXIdentifierAttribute))] \(axPosStr(el)) \(axEnabled(el)) \(axActions(el))"
}
func kids(_ el: AXUIElement) -> [AXUIElement] {
    (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}
func walk(_ el: AXUIElement, _ depth: Int, _ maxDepth: Int, _ visit: (AXUIElement, Int) -> Void) {
    if depth > maxDepth { return }
    visit(el, depth)
    for k in kids(el).prefix(80) { walk(k, depth + 1, maxDepth, visit) }
}
func appEl(_ pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }

func haystack(_ el: AXUIElement) -> String {
    return (sattr(el, kAXTitleAttribute) + "|" + sattr(el, kAXDescriptionAttribute) + "|" + sattr(el, kAXIdentifierAttribute) + "|" + sattr(el, kAXValueAttribute) + "|" + sattr(el, kAXRoleAttribute) + "|" + sattr(el, kAXSubroleAttribute)).lowercased()
}
func findMatches(_ pid: pid_t, _ needle: String, _ maxDepth: Int = 14) -> [(AXUIElement, Int)] {
    let n = needle.lowercased()
    var res: [(AXUIElement, Int)] = []
    walk(appEl(pid), 0, maxDepth) { el, d in
        if haystack(el).contains(n) { res.append((el, d)) }
    }
    return res
}
func findIn(_ root: AXUIElement, _ needle: String, _ maxDepth: Int = 18) -> [(AXUIElement, Int)] {
    let n = needle.lowercased()
    var res: [(AXUIElement, Int)] = []
    walk(root, 0, maxDepth) { el, d in
        if haystack(el).contains(n) { res.append((el, d)) }
    }
    return res
}
func appWindows(_ pid: pid_t) -> [AXUIElement] {
    let app = appEl(pid)
    var wins: [AXUIElement] = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    if wins.isEmpty { wins = kids(app).filter { sattr($0, kAXRoleAttribute) == "AXWindow" } }
    return wins
}
func firstWindowBySubrole(_ pid: pid_t, _ subrole: String) -> AXUIElement? {
    for w in appWindows(pid) where sattr(w, kAXSubroleAttribute) == subrole { return w }
    return nil
}

// ---------------------------------------------------------------- window list
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
            out("win=\(num)\tpid=\(pid)\tlayer=\(layer)\towner=\(owner)\tname=\(name.isEmpty ? "-" : name)\tbounds=\(b["X"] ?? 0),\(b["Y"] ?? 0),\(b["Width"] ?? 0),\(b["Height"] ?? 0)")
        }
    }
}

func frontApp(_ name: String) {
    let apps = NSWorkspace.shared.runningApplications
    if let a = apps.first(where: { ($0.localizedName ?? "") == name || ($0.bundleIdentifier ?? "") == name }) {
        out("activate \(a.localizedName ?? "?") pid=\(a.processIdentifier) ok=\(a.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]))")
    } else { out("not running: \(name)") }
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
    out("typed \(chars.count) utf16 units")
}

func postKeycode(_ code: CGKeyCode) {
    let src = CGEventSource(stateID: .hidSystemState)
    CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
    usleep(30000)
    CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
    out("keycode \(code)")
}

func postKeycodeMod(_ code: CGKeyCode, _ flags: CGEventFlags) {
    let src = CGEventSource(stateID: .hidSystemState)
    if let d = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true) {
        d.flags = flags
        d.post(tap: .cghidEventTap)
    }
    usleep(30000)
    if let u = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) {
        u.flags = flags
        u.post(tap: .cghidEventTap)
    }
    out("keycode \(code) flags=\(flags.rawValue)")
}

func clickAt(_ x: Double, _ y: Double) {
    let p = CGPoint(x: x, y: y)
    let src = CGEventSource(stateID: .hidSystemState)
    CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(120000)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(60000)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    out("clicked \(x),\(y) trusted=\(AXIsProcessTrusted())")
}

func setValue(_ el: AXUIElement, _ s: String) -> AXError {
    _ = AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    usleep(80000)
    return AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, s as CFString)
}

func pressFirst(_ ms: [(AXUIElement, Int)]) -> Int {
    var pressed = 0
    for (el, d) in ms {
        if axActions(el).contains("AXPress") {
            let r = AXUIElementPerformAction(el, kAXPressAction as CFString)
            out("press depth=\(d) role=\(sattr(el, kAXRoleAttribute)) sub=\(sattr(el, kAXSubroleAttribute)) title=[\(sattr(el, kAXTitleAttribute))] desc=[\(sattr(el, kAXDescriptionAttribute))] id=[\(sattr(el, kAXIdentifierAttribute))] rc=\(r.rawValue) \(axEnabled(el))")
            pressed += 1
            if pressed >= 1 { break }
        }
    }
    if pressed == 0 { out("no pressable element matched (matches=\(ms.count))") }
    return pressed
}

switch cmd {
case "list": listWindows()
case "ax": out("AXIsProcessTrusted=\(AXIsProcessTrusted())")
case "front": guard args.count > 2 else { err("front <name>") }; frontApp(args[2])
case "key": guard args.count > 2 else { err("key <text>") }; postText(args[2])
case "keycode": guard args.count > 2, let c = UInt16(args[2]) else { err("keycode <n>") }; postKeycode(CGKeyCode(c))
case "click": guard args.count > 3, let x = Double(args[2]), let y = Double(args[3]) else { err("click <x> <y>") }; clickAt(x, y)
case "cmdkey": guard args.count > 2, let c = UInt16(args[2]) else { err("cmdkey <n>") }; postKeycodeMod(CGKeyCode(c), .maskCommand)

case "axdump":
    guard args.count > 2, let pid = Int32(args[2]) else { err("axdump <pid> [depth]") }
    let maxD = args.count > 3 ? (Int(args[3]) ?? 4) : 4
    walk(appEl(pid_t(pid)), 0, maxD) { el, d in out(line(el, d)) }

case "axwinls":
    guard args.count > 2, let pid = Int32(args[2]) else { err("axwinls <pid>") }
    let wins = appWindows(pid_t(pid))
    out("windows=\(wins.count)")
    for (i, w) in wins.enumerated() {
        out("#\(i) role=\(sattr(w, kAXRoleAttribute)) sub=\(sattr(w, kAXSubroleAttribute)) title=[\(sattr(w, kAXTitleAttribute))] \(axPosStr(w))")
    }

case "axfind":
    guard args.count > 3, let pid = Int32(args[2]) else { err("axfind <pid> <needle>") }
    let ms = findMatches(pid_t(pid), args[3])
    out("matches=\(ms.count) for [\(args[3])]")
    for (el, d) in ms.prefix(40) { out(line(el, d)) }

case "axfindin":
    guard args.count > 4, let pid = Int32(args[2]) else { err("axfindin <pid> <winsubrole> <needle>") }
    guard let w = firstWindowBySubrole(pid_t(pid), args[3]) else { out("no window with sub=\(args[3])"); exit(0) }
    let ms = findIn(w, args[4])
    out("matches=\(ms.count) for [\(args[4])] in window sub=\(args[3])")
    for (el, d) in ms.prefix(40) { out(line(el, d)) }

case "axset":
    guard args.count > 4, let pid = Int32(args[2]) else { err("axset <pid> <needle> <text>") }
    let ms = findMatches(pid_t(pid), args[3])
    var done = 0
    for (el, d) in ms {
        let role = sattr(el, kAXRoleAttribute)
        if role == "AXTextField" || role == "AXTextArea" {
            let r = setValue(el, args[4])
            out("set role=\(role) sub=\(sattr(el, kAXSubroleAttribute)) id=[\(sattr(el, kAXIdentifierAttribute))] depth=\(d) rc=\(r.rawValue) readback=[\(sattr(el, kAXValueAttribute))] \(axPosStr(el))")
            done += 1
            if done >= 1 { break }
        }
    }
    if done == 0 { out("no editable element matched [\(args[3])] (matches=\(ms.count))") }

case "axpress":
    guard args.count > 3, let pid = Int32(args[2]) else { err("axpress <pid> <needle>") }
    _ = pressFirst(findMatches(pid_t(pid), args[3]))

case "axpressin":
    guard args.count > 4, let pid = Int32(args[2]) else { err("axpressin <pid> <winsubrole> <needle>") }
    guard let w = firstWindowBySubrole(pid_t(pid), args[3]) else { out("no window with sub=\(args[3])"); exit(0) }
    _ = pressFirst(findIn(w, args[4]))

case "axfillin":
    guard args.count > 4, let pid = Int32(args[2]) else { err("axfillin <pid> <winsubrole> <text>") }
    guard let w = firstWindowBySubrole(pid_t(pid), args[3]) else { out("no window with sub=\(args[3])"); exit(0) }
    var done = 0
    walk(w, 0, 18) { el, d in
        if done > 0 { return }
        let role = sattr(el, kAXRoleAttribute)
        if role == "AXTextField" || role == "AXSecureTextField" || role == "AXTextArea" {
            let r = setValue(el, args[4])
            out("fill role=\(role) sub=\(sattr(el, kAXSubroleAttribute)) id=[\(sattr(el, kAXIdentifierAttribute))] depth=\(d) rc=\(r.rawValue) readback=[\(sattr(el, kAXValueAttribute))] \(axPosStr(el))")
            done += 1
        }
    }
    if done == 0 { out("no editable element inside window sub=\(args[3])") }

case "axfocus":
    guard args.count > 3, let pid = Int32(args[2]) else { err("axfocus <pid> <needle>") }
    let ms = findMatches(pid_t(pid), args[3])
    guard let (el, d) = ms.first, let p = axPoint(el), let s = axSize(el) else { out("no element with coords matched [\(args[3])] (matches=\(ms.count))"); exit(0) }
    out("focus target depth=\(d) role=\(sattr(el, kAXRoleAttribute)) id=[\(sattr(el, kAXIdentifierAttribute))] \(axPosStr(el))")
    _ = AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    clickAt(Double(p.x + s.width/2), Double(p.y + s.height/2))

default: err("unknown \(cmd)")
}
