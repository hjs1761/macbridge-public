import Foundation
import AppKit

// MARK: - 포커스 바운스 (꼬인 입력 세션 리셋)
//
// 자소분리의 정체는 IME 불일치가 아니라 포커스된 필드의 **입력 세션 꼬임**이다(2026-08-07 규명).
// IME 재선택으로는 안 풀리고, **포커스 전환(입력 컨텍스트 리셋)** 만이 푼다 — 사용자가 손으로
// "다른 창 클릭 후 복귀"로 확인한 것의 프로그램판. 자기 앱 활성화 + NSRunningApplication.activate
// 뿐이라 **권한이 필요 없다.**

/// 화면이 잠겨 있거나 로그인 창인가.
///
/// ⚠ 잠금 화면은 **비밀번호 입력을 위해 IME 를 강제로 ABC(en) 로 유지한다.** 여기에 대고
/// 한글을 적용하면 로그가 성공을 찍어도 즉시 되돌려지고, 다음 keepalive 에 또 불일치를 보고해
/// **무한 정정 루프**가 된다(2026-08-07 회사미니 실측 — 5초마다 로그인 창에 포커스 바운스까지
/// 때리고 있었다). 잠긴 기기의 IME 는 **손대지 않는 게 맞다** — 아무도 그 기기로 타이핑하지 않는다.
func isScreenLocked() -> Bool {
    if let d = CGSessionCopyCurrentDictionary() as? [String: Any] {
        if let locked = d["CGSSessionScreenIsLocked"] as? Bool, locked { return true }
        if let locked = d["CGSSessionScreenIsLocked"] as? Int, locked != 0 { return true }
        if let onConsole = d["kCGSSessionOnConsoleKey"] as? Bool, !onConsole { return true }
    }
    return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow"
}

/// 최전면 앱을 잠깐 비활성화했다가 되돌린다.
func bounceFrontmostFocus() {
    guard let front = NSWorkspace.shared.frontmostApplication,
          front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
    NSApp.activate(ignoringOtherApps: true)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        let ok = front.activate(options: [])
        log("포커스 바운스 — \(front.bundleIdentifier ?? front.localizedName ?? "?") 재활성"
            + (ok ? " (입력 세션 리셋)" : " ⚠ 재활성 실패 — 0.3초 뒤 재시도"))
        if !ok {
            // 사용자를 포커스 없는 상태로 남겨두면 안 된다 — 한 번 더 시도
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                _ = front.activate(options: [])
            }
        }
    }
}

// MARK: - 복구 제스처 (한/영 빠른 두 번)
//
// 짧은 시간 내 왕복(예: ko→en→ko)은 순동기화 관점에선 무의미한 패턴이다(같은 값으로
// 되돌아오므로 호스트에 아무 효과가 없다). 이를 **명시적 복구 신호**로 해석한다 —
// 캡스락은 뷰어가 최전면이어도 로컬에 먹으므로, ⌃⌥⇧K 가 뷰어에 삼켜지는 문제를 우회한다.

/// 기본 왕복 인정 시간.
///
/// ⚠ **2,000ms 로 넓혔다가 같은 날 1,000ms 로 되돌렸다**(2026-08-08). 되돌린 이유가 중요하다.
///
///   넓힌 이유는 지구본(Fn) 키였다 — macOS 가 "길게 눌러 이모지 팝업"을 구분하려 지연을 둬서
///   왕복이 1.2~1.8초 걸리고, 1초 창에서는 대부분 놓쳤다.
///
///   그런데 넓히자 **평범한 한/영 전환이 전부 제스처로 잡혔다.** `en→ko→en` 은 구조적으로
///   언제나 "왕복"이라, 창이 2초면 정상 전환 리듬(실측 1.218·1.287·1.477·1.522·1.625·1.985초)이
///   통째로 걸린다. 매 전환마다 포커스 바운스가 터지고, **그 바운스가 방금 시작한 한글 조합을
///   깨뜨려 자소분리를 만들었다** — 고치려던 증상을 우리가 만들어낸 셈이다.
///
///   오발동 비용은 "무해한 정렬 한 번"이 아니라 **자소분리**다. 그래서 안전한 쪽으로 돌아온다.
///   실측상 캡스락 왕복(0.014~0.230초)과 정상 전환(1.2초 이상) 사이가 넉넉히 벌어져 있어
///   1초는 좋은 경계다. 지구본 키 사용자는 `ime_sync.recovery_window_ms` 로 늘릴 수 있고,
///   놓침이 반복되면 메뉴바가 먼저 알려 준다.
let defaultRecoveryGestureWindowMs: Int64 = 1_000

/// 직전 전이(prevFrom→…, prevAtMs)에 이어 `to` 로 돌아오는 빠른 왕복인가.
func isRecoveryGesture(prevFrom: String?, prevAtMs: Int64, to: String, atMs: Int64,
                       windowMs: Int64 = defaultRecoveryGestureWindowMs) -> Bool {
    guard let f = prevFrom else { return false }
    return f == to && atMs - prevAtMs <= windowMs
}

/// 왕복이긴 한데 창을 넘겼는가 — **놓친 제스처를 로그로 보이게** 하려고 따로 판정한다.
/// 안 그러면 "눌러도 아무 반응이 없다"로만 나타나서 원인을 짐작할 수가 없다
/// (지구본 키 사용자가 정확히 이 상태였다).
func isMissedRecoveryGesture(prevFrom: String?, prevAtMs: Int64, to: String, atMs: Int64,
                             windowMs: Int64 = defaultRecoveryGestureWindowMs,
                             graceMs: Int64 = 2_000) -> Bool {
    guard let f = prevFrom, f == to else { return false }
    let dt = atMs - prevAtMs
    return dt > windowMs && dt <= windowMs + graceMs
}
