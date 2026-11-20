import Foundation
import CoreGraphics

let a = CommandLine.arguments
guard a.count >= 5, let x1 = Double(a[1]), let y1 = Double(a[2]), let x2 = Double(a[3]), let y2 = Double(a[4]) else {
  print("usage: drag x1 y1 x2 y2 [steps]"); exit(2)
}
let steps = a.count > 5 ? (Int(a[5]) ?? 20) : 20
let src = CGEventSource(stateID: .hidSystemState)
CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x1, y: y1), mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(100000)
CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: x1, y: y1), mouseButton: .left)?.post(tap: .cghidEventTap)
for i in 1...steps {
  let t = Double(i) / Double(steps)
  let x = x1 + (x2 - x1) * t
  let y = y1 + (y2 - y1) * t
  CGEvent(mouseEventSource: src, mouseType: .leftMouseDragged, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)?.post(tap: .cghidEventTap)
  usleep(20000)
}
CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: x2, y: y2), mouseButton: .left)?.post(tap: .cghidEventTap)
print("dragged \(x1),\(y1) -> \(x2),\(y2)")
