import Foundation
import Carbon
import AppKit

struct HotkeyCombo: Equatable {
    let modifiers: UInt32
    let keyCode: UInt32
}

/// 문서화된 표기만 받는다: `ctrl` `opt`(=`alt`) `shift` `cmd` + 키 하나.
/// 예) `"ctrl+opt+shift+k"`
func parseHotkeyCombo(_ s: String) -> HotkeyCombo? {
    let tokens = s.lowercased().split(separator: "+")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    guard !tokens.isEmpty else { return nil }

    var mods: UInt32 = 0
    var key: UInt32?
    for t in tokens {
        switch t {
        case "ctrl", "control": mods |= UInt32(controlKey)
        case "opt", "option", "alt": mods |= UInt32(optionKey)
        case "shift": mods |= UInt32(shiftKey)
        case "cmd", "command": mods |= UInt32(cmdKey)
        default:
            guard key == nil, let k = hotkeyKeyCodes[t] else { return nil }
            key = k
        }
    }
    guard let k = key else { return nil }
    return HotkeyCombo(modifiers: mods, keyCode: k)
}

/// 필요한 것만 둔다. 늘릴 때는 Carbon 의 kVK_* 값을 그대로 쓴다.
let hotkeyKeyCodes: [String: UInt32] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    "space": 49, "return": 36, "escape": 53,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
    "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64, "f18": 79, "f19": 80,
]

/// 전 피어를 내 언어로 강제 정렬하고, 각자 조합 세션을 끊는다.
/// 로컬(누른 기기)도 같은 리셋을 수행한다.
///
/// `Ctrl+Space` 와 달리 **키를 원격에 보내지 않는다** — 각 기기가 자기 IME 를 로컬에서 조작한다.
func performRealign(_ cfg: Config) {
    // 「끔」은 전면 불참이다. 캡스락 왕복은 평소 타이핑 중에도 우발적으로 나오는 패턴이라,
    // 꺼 둔 사람에게 이 경로가 열려 있으면 "껐는데 전 기기가 바뀐다"가 된다.
    // 런타임 플래그를 본다 — 메뉴 토글은 cfg 를 거치지 않는다.
    guard globalServer?.imeEnabled ?? true else {
        log("realign 생략 — 이 기기의 IME 동기화가 꺼져 있다"); return
    }
    guard let lang = currentLanguage(), ["ko", "en"].contains(lang) else {
        log("realign: 현재 언어를 읽지 못해 중단"); return
    }
    let sock = socket(AF_INET, SOCK_DGRAM, 0)
    if sock >= 0 {
        defer { close(sock) }
        let bytes = Array("\(cfg.token) force \(lang) \(nowMs())\n".utf8)
        for peer in cfg.peers {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = peer.port.bigEndian
            addr.sin_addr.s_addr = inet_addr(peer.host)
            guard addr.sin_addr.s_addr != INADDR_NONE else { continue }
            for _ in 0..<3 {   // UDP 유실 대비, 기존 방식과 동일
                _ = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(sock, bytes, bytes.count, 0, $0,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }
    suppressor.suppress()
    selectLanguage(lang)   // 로컬도 재선택
    log("⌘ realign — 전 피어를 \(lang) 로 정렬 + 포커스 바운스 (\(cfg.peers.count)대)")
    // ⚠ **로컬에도 반드시 바운스한다.** IME 재선택만으로는 꼬인 입력 세션이 안 풀린다(2026-08-07 규명).
    //   한때 받는 쪽에만 바운스를 걸어 뒀는데, 정작 꼬인 세션은 **realign 을 누른 그 기기**에 있다.
    //   실측: 집미니 메모에서 자소분리 → 집미니 메뉴바에서 '지금 정렬' 클릭 → IME 만 바뀌고 안 풀림.
    //   같은 기기가 맥북에서 온 force 를 받자(=바운스 포함) 그 순간 풀렸다.
    bounceFrontmostFocus()
}

/// Carbon 전역 핫키. 입력 모니터링 권한이 필요 없고, macOS 가 앱보다 먼저 가로채므로
/// **원격 뷰어 창이 최전면이어도 로컬에서 발동한다**(키는 원격으로 넘어가지 않는다).
final class HotkeyManager {
    private var refs: [EventHotKeyRef?] = []
    nonisolated(unsafe) static var config: Config?
    /// ⚠ 이벤트 핸들러는 **한 번만** 설치한다. `ctl reload` 로 재등록할 때 또 설치하면
    ///   핸들러가 중복돼 핫키 한 번에 realign 이 두 번 돈다.
    nonisolated(unsafe) static var handlerInstalled = false

    /// 등록된 핫키를 모두 해제한다. `ctl reload` 가 조합을 바꿀 때 먼저 부른다.
    func unregisterAll() {
        for r in refs where r != nil { UnregisterEventHotKey(r!) }
        refs.removeAll()
    }

    func register(_ cfg: Config) {
        HotkeyManager.config = cfg
        guard !cfg.hotkeys.isEmpty else { return }

        if !Self.handlerInstalled {
            Self.handlerInstalled = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
                var hkID = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hkID)
                if let c = HotkeyManager.config { performRealign(c) }
                return noErr
            }, 1, &spec, nil, nil)
        }

        for (i, hk) in cfg.hotkeys.enumerated() {
            guard let combo = parseHotkeyCombo(hk.combo) else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4D42_5247), id: UInt32(i))  // 'MBRG'
            let st = RegisterEventHotKey(combo.keyCode, combo.modifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
            if st == noErr {
                refs.append(ref)
                log("핫키 등록: \(hk.combo) → \(hk.action)")
            } else {
                // ⚠ 조용히 죽지 않는다 — 다른 앱이 조합을 점유한 경우다
                log("!! 핫키 등록 실패: \(hk.combo) (err=\(st))"
                    + " — 다른 앱이 이 조합을 쓰고 있을 수 있습니다. config 에서 조합을 바꾸세요")
            }
        }
    }
}
