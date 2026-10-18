import Foundation
import Carbon
import AppKit

// MARK: - 입력 소스 (Text Input Sources / Carbon)

/// 입력 소스의 주 언어("ko", "en" 등)
func primaryLanguage(of src: TISInputSource) -> String? {
    guard let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages) else { return nil }
    let langs = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String]
    return langs?.first
}

func inputSourceID(of src: TISInputSource) -> String? {
    guard let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return nil }
    return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
}

func isSelectable(_ src: TISInputSource) -> Bool {
    guard let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceIsSelectCapable) else { return false }
    return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue())
}

/// 현재 입력 소스의 언어.
///
/// TIS 를 1순위로 쓴다. 한때 "TIS 는 캐시돼서 못 믿는다"고 판단해 `defaults` 서브프로세스로
/// 우회했지만, 그 판단은 **ARC 버그로 감시 타이머가 아예 안 돌던 시점**의 오진이었다.
/// 버그를 고친 뒤 두 방식을 나란히 찍어 대조하니 값이 한 번도 어긋나지 않았고,
/// 속도는 **TIS 0~3ms vs defaults 112~165ms** 로 두 자릿수 차이였다.
/// 이 150ms 가 곧 "Caps Lock 누르자마자 친 키가 깨지는" 창이었다.
func currentLanguage() -> String? {
    if let lang = currentLanguageViaTIS() { return lang }
    return currentLanguageViaDefaults()   // TIS 가 실패할 때만
}

/// 느리지만 프로세스 캐시의 영향을 받지 않는 경로 — TIS 실패 시 백업
func currentLanguageViaDefaults() -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    p.arguments = ["read", "com.apple.HIToolbox", "AppleSelectedInputSources"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard let s = String(data: data, encoding: .utf8) else { return nil }

    if s.contains("Korean")   { return "ko" }
    if s.contains("Japanese") { return "ja" }
    if s.contains("SCIM") || s.contains("TCIM") { return "zh" }
    if s.contains("KeyboardLayout Name") { return "en" }
    return nil
}

func currentSourceID() -> String? {
    guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
    return inputSourceID(of: src)
}

/// 선택 가능한 키보드 입력 소스 목록
func selectableKeyboardSources() -> [TISInputSource] {
    let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
    guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }
    return list.filter(isSelectable)
}

func currentLanguageViaTIS() -> String? {
    guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
    return primaryLanguage(of: src)
}

/// 주어진 언어의 입력 소스로 전환.
/// ⚠ "이미 그 언어인지" 확인은 **호출부 책임**이다. 여기서 확인하면 상태 조회가
///   한 번 더 들어가 전환 지연이 두 배가 된다(실측 85ms 중 68ms 가 그 비용이었다).
@discardableResult
func selectLanguage(_ lang: String) -> Bool {
    for src in selectableKeyboardSources() where primaryLanguage(of: src) == lang {
        let err = TISSelectInputSource(src)
        if err == noErr {
            log("입력 소스 전환 → \(lang) (\(inputSourceID(of: src) ?? "?"))")
            return true
        }
        log("전환 실패(err=\(err)): \(inputSourceID(of: src) ?? "?")")
    }
    log("'\(lang)' 언어의 선택 가능한 입력 소스를 찾지 못함")
    return false
}

// MARK: - 에코 루프 방지
//
// 수신해서 내 입력 소스를 바꾸면 변경 알림이 또 발생한다.
// 그대로 두면 상대에게 되쏘아 무한 왕복이 되므로, 수신 직후 짧게 송신을 억제한다.
// 양방향(both)에서는 이 억제가 유일한 방어선이다.

final class Suppressor {
    private var until = Date.distantPast
    private let queue = DispatchQueue(label: "macbridge.suppressor")
    private let window: TimeInterval

    init(window: TimeInterval = 1.0) { self.window = window }

    func suppress() { queue.sync { until = Date().addingTimeInterval(window) } }
    var isSuppressed: Bool { queue.sync { Date() < until } }
}

let suppressor = Suppressor()

// MARK: - TIS 캐시 갱신기
//
// TIS 의 프로세스 내 캐시는 분산 알림을 받아야 갱신된다(실측 — 폴링만으로는 옛 값이 읽힌다).
// 수신 경로가 "이미 그 언어인가"를 실제 상태로 판정하게 되면서 이 신선도가 정확성에 직결됐다.
// 감시자를 켜지 않는 `serve` 전용 모드에도 구멍이 없도록 **모드와 무관하게** 등록한다.

final class InputSourceCacheRefresher: NSObject {
    func start() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(refresh),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }
    @objc private func refresh() { _ = currentLanguage() }
}
