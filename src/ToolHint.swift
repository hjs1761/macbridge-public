import Foundation

// MARK: - 「먼저 말 걸기」
//
// 최전면 앱이 `only_app` 목록에 없으면 macbridge 는 **조용히 아무것도 안 한다.**
// 메뉴바는 평소처럼 멀쩡해 보이고, `건너뜀` 은 로그를 열어야만 보인다.
//
// ⚠ 2026-08-08 실사용: **만든 사람조차** Parsec 을 쓰면서 "우리 앱 캡스락이 안 먹힌다"고
//   오진했다. 실제 원인은 체크박스 하나였다. 처음 쓰는 사람이 이걸 알아낼 방법은 없다.
//   그래서 앱이 먼저 말을 건다.

/// 목록에 없는 앱이 **피어와 어긋난 상태에서** IME 를 반복해 바꾸면 원격 도구로 의심한다.
///
/// ⚠ "건너뛴 횟수"만 세면 안 된다 — 로컬에서 VSCode 로 일하며 한/영을 바꾸는 건 지극히
///   정상이고, 실제 로그에도 그런 기록이 가장 많다. **피어와 실제로 어긋나 있을 때**만
///   세야 원격 도구와 평범한 앱이 갈린다. 원격 작업 중에만 불일치가 문제가 되기 때문이다.
struct ToolHintTracker {
    /// 후보로 올리기까지 필요한 횟수. 한두 번으로 말을 걸면 성가시고, 너무 높으면
    /// 정작 필요한 첫 세션에서 침묵한다.
    static let threshold = 6

    /// 원격 도구일 리 없는 것들. 시스템 UI 와 우리 자신은 후보에서 뺀다.
    static let neverSuggest: Set<String> = [
        "com.apple.finder",
        "com.apple.loginwindow",
        "com.apple.systempreferences",
        "com.apple.dock",
        "com.apple.SecurityAgent",
        "com.hjs.macbridge",
    ]

    private var counts: [String: Int] = [:]
    private var dismissed: Set<String>
    /// **우리가 원격 도구라고 아는 것들만** 제안한다. 아래 `noteSkipped` 주석 참조.
    private let known: Set<String>
    /// 지금 사용자에게 물어볼 앱. 없으면 nil.
    private(set) var candidate: String?

    init(dismissed: [String] = [], known: Set<String> = []) {
        self.dismissed = Set(dismissed)
        self.known = known
    }

    /// 목록에 없는 앱에서 IME 변경을 건너뛰었다.
    /// - Parameter mismatched: 그 순간 온라인 피어 중 나와 언어가 다른 게 있었는가.
    /// - Returns: 이번 호출로 **새로** 후보가 됐으면 true (로그를 한 번만 남기기 위함).
    @discardableResult
    mutating func noteSkipped(app: String, mismatched: Bool) -> Bool {
        // ⚠ "어긋나 있을 때만 센다"만으로는 부족했다(2026-08-08 실사용 오탐).
        //   잠기거나 방치된 기기가 하나라도 있으면 **항상** 어긋나 있어서, VSCode 로 로컬
        //   작업하며 한/영을 바꾸는 것만으로 6회를 채우고 "원격 도구 의심"이 떠 버렸다.
        //   그래서 **우리가 원격 도구라고 아는 것(knownRemoteTools)** 으로 한정한다.
        //   목록에 없는 새 도구는 설정의 「자동 감지」 버튼이 담당한다 — 재현율을 조금
        //   포기하고 정밀도를 택한다. 엉뚱한 앱을 가리키는 제안은 신뢰를 깎기 때문이다.
        guard known.contains(app),
              mismatched,
              !app.isEmpty,
              !Self.neverSuggest.contains(app),
              !dismissed.contains(app) else { return false }

        counts[app, default: 0] += 1
        guard counts[app]! >= Self.threshold else { return false }
        guard candidate != app else { return false }   // 이미 물어보는 중
        candidate = app                                 // 다른 앱이 후보였다면 최신 것이 이긴다
        return true
    }

    /// 사용자가 "이건 원격 도구 아니야" 라고 했다 — 다시는 묻지 않는다.
    mutating func dismiss(_ app: String) {
        dismissed.insert(app)
        clear(app)
    }

    /// 목록에 실제로 추가됐다 — 더는 건너뛰지 않으므로 후보에서 내린다.
    mutating func resolve(_ app: String) { clear(app) }

    private mutating func clear(_ app: String) {
        counts[app] = nil
        if candidate == app { candidate = nil }
    }

    /// config 에 영속화할 무시 목록.
    var dismissedList: [String] { dismissed.sorted() }
}
