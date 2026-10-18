import AppKit
import Carbon

// MARK: - 사용 방법 (연습형)
//
// 이 앱에서 사용자가 **몸으로 익혀야 하는 동작은 딱 하나**다 — 입력이 꼬였을 때 푸는 법.
// 글로 "캡스락을 1초 안에 두 번 누르세요"라고 적어 두면 대부분 읽고 잊는다.
//
// 그래서 **여기서 직접 해보게 한다.** 우리는 이미 그 제스처를 판정하는 순수 함수를
// 갖고 있으므로(`isRecoveryGesture`), 성공을 실시간으로 알려줄 수 있다.
// 실패했을 때 **"방금 1.4초 걸렸습니다"** 처럼 자기 속도를 보여주는 게 핵심이다 —
// 그냥 "다시 해보세요"는 몇 번을 반복해도 나아지지 않는다.

/// 연습 판의 상태.
enum PracticeState: Equatable {
    case waiting                 // 아직 아무것도 안 눌렀다
    case armed                   // 한 번 바뀌었다 — 다음 전환을 기다린다
    case success(Int64)          // 왕복 성공 (걸린 ms)
    case tooSlow(Int64)          // 왕복은 했는데 창을 넘겼다 (걸린 ms)
}

/// 전환 두 번을 받아 연습 결과를 낸다. 순수 판정이라 테스트가 붙는다.
func practiceOutcome(firstFrom: String, secondTo: String,
                     elapsedMs: Int64, windowMs: Int64) -> PracticeState {
    guard firstFrom == secondTo else { return .armed }   // 왕복이 아니면 아직 진행 중
    return elapsedMs <= windowMs ? .success(elapsedMs) : .tooSlow(elapsedMs)
}

func makeHowToPane(_ c: SettingsWindowController) -> NSView {
    let s = uiStack()

    let h = NSTextField(labelWithString: "익혀 두실 건 하나입니다")
    h.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
    s.addArrangedSubview(h)
    s.addArrangedSubview(uiWrapLabel(
        "한/영은 알아서 맞춰집니다. 다만 원격으로 쓰다 보면 가끔 입력이 꼬여서 "
        + "한글 모드인데 영문만 나오거나 자소가 흩어질 때가 있습니다. 그때 푸는 법입니다.",
        width: uiContentWidth, size: 12))

    // ── 1. 가장 확실한 길 ──
    s.addArrangedSubview(uiSection("가장 확실한 방법"))
    let realignBtn = uiButton("실행해 보기", owner: c) {
        let r = DaemonClient.control(c.cfg, "ctl realign")
        c.alert(r == "ok" ? "정렬했습니다" : "정렬하지 못했습니다",
                r == "ok"
                ? "전 기기의 한/영을 맞추고 꼬인 입력을 풀었습니다.\n"
                  + "메뉴바 아이콘을 눌러도 같은 항목이 있습니다."
                : "데몬 응답: \(r ?? "없음")")
    }
    s.addArrangedSubview(uiCard([
        uiRow(icon: "arrow.triangle.2.circlepath",
              title: "메뉴바 → 「지금 정렬」",
              detail: "누르는 타이밍을 맞출 필요가 없어 언제 눌러도 한 번에 됩니다.",
              trailing: realignBtn,
              width: uiCardInnerWidth(), trailingWidth: 96),
    ]))

    // ── 2. 연습 ──
    s.addArrangedSubview(uiSection("손이 키보드에 있을 때 — 연습해 보세요"))
    let practice = PracticePad(windowMs: c.cfg.recoveryWindowMs)
    c.retained.append(practice)   // ⚠ 지역변수로 두면 ARC 가 걷어가 옵저버가 죽는다
    s.addArrangedSubview(practice.view)

    // ── 3. 원격 도구별 ──
    s.addArrangedSubview(uiSection("쓰시는 원격 도구에 따라"))
    s.addArrangedSubview(uiRow(icon: "keyboard",
        title: "Caps Lock 으로 바꾸신다면",
        detail: "그대로 쓰시면 됩니다. 양쪽이 함께 바뀝니다."))
    s.addArrangedSubview(uiRow(icon: "globe",
        title: "오른쪽 Command·지구본 키를 쓰신다면",
        detail: "이것도 됩니다 — macbridge 는 키를 보지 않고 「입력 소스가 바뀌었다」만 듣습니다."))
    s.addArrangedSubview(uiRow(icon: "exclamationmark.triangle",
        title: "Ctrl + Space 를 쓰신다면",
        detail: "쓰셔도 되지만 상대 맥의 입력을 가끔 꼬이게 합니다. 그때 위 방법으로 푸세요."))

    return uiScrollPane(s)
}

// MARK: - 연습 판

/// 입력 소스 변경을 **직접** 듣고 왕복을 판정한다.
/// 데몬에 묻지 않는 이유 — 연습은 이 창 안에서 끝나야 하고, 데몬이 꺼져 있어도 배울 수 있어야 한다.
final class PracticePad: NSObject {
    let view: NSView
    private let windowMs: Int64
    private let status = NSTextField(labelWithString: "")
    private let hint = NSTextField(wrappingLabelWithString: "")
    private var lastLang: String?
    private var lastAtMs: Int64 = 0
    private var state: PracticeState = .waiting { didSet { render() } }

    init(windowMs: Int64) {
        self.windowMs = windowMs
        let w = uiCardInnerWidth()
        status.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        status.translatesAutoresizingMaskIntoConstraints = false
        status.widthAnchor.constraint(equalToConstant: w).isActive = true
        // 설명은 상태에 따라 길이가 크게 달라진다 — 폭을 못 박아야 줄바꿈이 안 흔들린다
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.preferredMaxLayoutWidth = w
        hint.widthAnchor.constraint(equalToConstant: w).isActive = true
        hint.setContentCompressionResistancePriority(.required, for: .vertical)
        view = uiCard([status, hint], accent: true)
        super.init()
        lastLang = currentLanguage()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(changed),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil)
        render()
    }

    deinit { DistributedNotificationCenter.default().removeObserver(self) }

    @objc private func changed() {
        // 알림 직후에는 TIS 가 아직 옛 값을 줄 수 있어 한 틱 미룬다
        DispatchQueue.main.async { [weak self] in self?.step() }
    }

    private func step() {
        guard let now = currentLanguage(), ["ko", "en"].contains(now) else { return }
        let t = nowMs()
        defer { lastLang = now; lastAtMs = t }
        guard let prev = lastLang, prev != now else { return }   // 실제로 바뀐 것만
        if case .armed = state {
            state = practiceOutcome(firstFrom: armedFrom ?? prev, secondTo: now,
                                    elapsedMs: t - armedAtMs, windowMs: windowMs)
            if case .armed = state { armFrom(prev, at: t) }      // 왕복이 아니면 다시 무장
            return
        }
        armFrom(prev, at: t)
    }

    private var armedFrom: String?
    private var armedAtMs: Int64 = 0
    private func armFrom(_ from: String, at t: Int64) {
        armedFrom = from
        armedAtMs = t
        state = .armed
    }

    private func render() {
        switch state {
        case .waiting:
            status.stringValue = "⌨️  지금 한/영을 빠르게 두 번 바꿔 보세요"
            status.textColor = .labelColor
            hint.stringValue = "Caps Lock 을 톡톡 두 번 — \(windowMs)ms 안에 원래 언어로 "
                + "돌아오면 복구 신호로 인식합니다. 여기서 눌러도 실제와 똑같이 판정됩니다."
        case .armed:
            status.stringValue = "◐  한 번 바뀌었습니다 — 바로 한 번 더"
            status.textColor = .secondaryLabelColor
            hint.stringValue = "원래 언어로 돌아오면 성공입니다."
        case .success(let ms):
            status.stringValue = "✅  성공 — \(ms)ms 만에 왕복했습니다"
            status.textColor = .systemGreen
            hint.stringValue = "이 속도면 실제 상황에서도 잘 먹습니다. "
                + "입력이 꼬였을 때 이대로 두 번 누르시면 됩니다."
        case .tooSlow(let ms):
            status.stringValue = "◔  조금 느립니다 — 방금 \(ms)ms 걸렸습니다"
            status.textColor = .systemOrange
            hint.stringValue = "기준은 \(windowMs)ms 입니다. 조금 더 빠르게 눌러 보세요. "
                + "지구본 키처럼 반응이 느린 키라면 이 속도가 안 나올 수 있는데, "
                + "그럴 땐 위의 「지금 정렬」을 쓰시면 됩니다."
        }
    }
}
