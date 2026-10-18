import Foundation
import CoreGraphics
let f = CGEventSource.flagsState(.combinedSessionState)
var stuck: [String] = []
if f.contains(.maskCommand)   { stuck.append("⌘ Command") }
if f.contains(.maskControl)   { stuck.append("⌃ Control") }
if f.contains(.maskShift)     { stuck.append("⇧ Shift") }
if f.contains(.maskAlternate) { stuck.append("⌥ Option") }
if f.contains(.maskSecondaryFn) { stuck.append("fn") }
if f.contains(.maskAlphaShift)  { stuck.append("⇪ CapsLock(잠금)") }
print(stuck.isEmpty ? "눌린 modifier 없음 (정상)" : "🔴 눌린 채로 남음: " + stuck.joined(separator: ", "))
