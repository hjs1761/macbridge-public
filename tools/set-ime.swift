// macbridge 를 거치지 않고 입력 소스를 바꾸는 시험용 도구 (드리프트 시뮬레이션)
import Foundation
import Carbon
let want = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "en"
let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
let list = TISCreateInputSourceList(filter, false)!.takeRetainedValue() as! [TISInputSource]
for src in list {
    guard let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages),
          let langs = Unmanaged<CFArray>.fromOpaque(p).takeUnretainedValue() as? [String],
          langs.first == want,
          let s = TISGetInputSourceProperty(src, kTISPropertyInputSourceIsSelectCapable),
          CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(s).takeUnretainedValue())
    else { continue }
    if TISSelectInputSource(src) == noErr { print("외부에서 \(want) 로 변경함"); exit(0) }
}
print("실패"); exit(1)
