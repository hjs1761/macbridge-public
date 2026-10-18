import AppKit

// MARK: - 첫 실행 온보딩
//
// ⚠ 흔한 "다음 → 다음 → 완료" 마법사가 **성립하지 않는다.** 2단계가 **다른 컴퓨터에서**
//   일어나기 때문이다. 사용자는 이 창을 열어 둔 채 저쪽 맥으로 가서 설치하고 돌아온다.
//   그래서 정적 마법사가 아니라 **상태를 계속 비추는 체크리스트**여야 한다 —
//   상대가 붙는 순간 이 창이 스스로 ✅ 로 바뀌어야 "됐구나"를 알 수 있다.
//
// ⚠ 왜 필요한가: 이 앱은 **두 대에 설치하고 연결해야** 비로소 동작한다. 그런데 첫 실행 때
//   메뉴바에 아이콘 하나 뜨고 끝이면 사용자는 "설치했는데 이제 뭐하지" 상태로 남는다.
//   목록에 없는 원격 도구를 조용히 건너뛰던 문제(ToolHint)와 같은 부류다 —
//   **아무 말도 안 하면 고장으로 읽힌다.**

/// 온보딩이 지금 어느 상태인가. 순수 판정이라 테스트가 붙는다.
enum OnboardingStage: Equatable {
    /// 데몬이 응답하지 않는다 — 연결 이전에 설치 자체가 덜 된 상태다
    case daemonDown
    /// 아직 이 맥 혼자 (첫 실행의 정상 상태)
    case alone
    /// 상대와 연결됐다
    case connected(Int)
}

func onboardingStage(daemonResponding: Bool, onlinePeerCount: Int) -> OnboardingStage {
    guard daemonResponding else { return .daemonDown }
    return onlinePeerCount > 0 ? .connected(onlinePeerCount) : .alone
}

/// 배포 페이지 — 2번째 맥에 설치하도록 안내할 주소.
let downloadPageURL = "https://github.com/hjs1761/macbridge-app/releases"
let guidePageURL = "https://hjs1761.github.io/macbridge-app/guide.html"

final class OnboardingWindowController: NSObject, NSWindowDelegate {
    nonisolated(unsafe) static var shared: OnboardingWindowController?

    private var window: NSWindow!
    private var body: NSStackView!
    private var timer: Timer?
    /// ActionTarget 을 붙들어 둔다 — 지역변수로 두면 ARC 가 즉시 걷어가 버튼이 죽는다
    private var retained: [Any] = []
    private let cfg: Config
    private var stage: OnboardingStage = .alone
    /// 같은 상태로는 다시 그리지 않는다(2초마다 화면이 깜빡이면 안 된다)
    private var drawnStage: OnboardingStage?

    init(config: Config) {
        self.cfg = config
        super.init()
    }

    static func show(config: Config) {
        if let s = shared {
            s.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let c = OnboardingWindowController(config: config)
        c.build()
        shared = c
        c.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 470),
                          styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.title = "macbridge 시작하기"
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false

        body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 12
        body.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        body.translatesAutoresizingMaskIntoConstraints = true
        body.frame = NSRect(x: 0, y: 0, width: 520, height: 470)
        body.autoresizingMask = [.width, .height]
        window.contentView = body

        refresh()
        // 저쪽 맥에서 설치·연결하는 동안 이 창은 열려 있다. 상태가 바뀌면 스스로 반영해야 한다.
        let t = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)   // 창을 드래그하는 동안에도 계속 돈다
        timer = t
    }

    // MARK: - 상태 갱신

    private func refresh() {
        let snap = queryDaemon(cfg, timeout: 0.7)
        stage = onboardingStage(daemonResponding: snap != nil,
                                onlinePeerCount: snap?.peers.filter(\.isOnline).count ?? 0)
        guard drawnStage != stage else { return }   // 바뀐 게 없으면 그대로 둔다
        drawnStage = stage
        render(peerNames: snap?.peers.filter(\.isOnline).map(\.name) ?? [])
    }

    private func render(peerNames: [String]) {
        retained.removeAll()
        body.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let title = NSTextField(labelWithString: headline())
        title.font = NSFont.systemFont(ofSize: 19, weight: .semibold)
        body.addArrangedSubview(title)
        body.addArrangedSubview(settingsLabel(subhead(peerNames), secondary: true))
        body.addArrangedSubview(spacer(6))

        // ── 단계 3개 ──
        body.addArrangedSubview(step(done: stage != .daemonDown, n: 1,
            title: "이 맥에 설치",
            detail: stage == .daemonDown
                ? "백그라운드 프로그램이 응답하지 않습니다 — 앱을 껐다 켜 보세요"
                : "메뉴바에 한/A 가 보이면 완료입니다"))

        body.addArrangedSubview(step(done: isConnected, n: 2,
            title: "다른 맥에도 설치",
            detail: "같은 앱을 두 번째 맥에 설치하세요. 한 대만으로는 맞출 상대가 없습니다."))
        body.addArrangedSubview(indented([
            button("다운로드 주소 복사") { [weak self] in self?.copyDownloadLink() },
        ]))

        body.addArrangedSubview(step(done: isConnected, n: 3,
            title: "두 맥을 연결",
            detail: "이 맥에서 연결 코드를 만들어 새 맥에 붙여넣으면 끝입니다."))
        body.addArrangedSubview(indented([
            button("연결 코드 만들기") { [weak self] in self?.makeInvite() },
        ]))

        body.addArrangedSubview(spacer(10))
        body.addArrangedSubview(statusLine(peerNames))
        body.addArrangedSubview(spacer(4))
        body.addArrangedSubview(settingsRow([
            button("가이드 열기") { openURL(guidePageURL) },
            button(isConnected ? "시작하기" : "나중에 하기") { [weak self] in self?.close() },
        ]))
    }

    private var isConnected: Bool {
        if case .connected = stage { return true }
        return false
    }

    private func headline() -> String {
        switch stage {
        case .daemonDown: return "거의 다 됐습니다"
        case .alone:      return "macbridge 가 설치됐습니다"
        case .connected:  return "연결됐습니다 — 준비 끝입니다"
        }
    }

    private func subhead(_ names: [String]) -> String {
        switch stage {
        case .daemonDown:
            return "백그라운드 프로그램이 아직 뜨지 않았습니다."
        case .alone:
            return "한/영을 맞추려면 맥이 두 대 필요합니다. 아래 순서대로 하시면 됩니다."
        case .connected:
            return "이제 한/영을 바꾸면 양쪽이 함께 바뀝니다 — Caps Lock 이든 무엇이든 상관없습니다."
        }
    }

    /// 지금 무슨 일이 벌어지고 있는지 한 줄. **이 줄이 살아 움직이는 게 이 창의 핵심이다.**
    private func statusLine(_ names: [String]) -> NSView {
        let text: String
        switch stage {
        case .daemonDown:
            text = "⚠ 백그라운드 프로그램 응답 없음"
        case .alone:
            text = "○ 아직 연결된 기기가 없습니다 — 두 번째 맥을 기다리는 중"
        case .connected:
            text = "● \(names.joined(separator: ", ")) 와(과) 연결됨"
        }
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        l.textColor = isConnected ? .systemGreen : .secondaryLabelColor
        return l
    }

    // MARK: - 동작

    private func copyDownloadLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(downloadPageURL, forType: .string)
        // 눌렀는데 아무 일도 안 일어나면 안 된 줄 안다 — 복사됐다는 걸 눈에 보이게 한다
        modalAlert("주소를 복사했습니다",
                   "\(downloadPageURL)\n\n두 번째 맥의 브라우저에 붙여넣어 내려받으세요.")
    }

    private func makeInvite() {
        presentInviteCode(cfg: cfg) { [weak self] t, b in self?.modalAlert(t, b) }
        // 코드 창을 닫은 뒤 상대가 붙었을 수 있다 — 다음 폴링을 기다리지 말고 바로 본다
        drawnStage = nil
        refresh()
    }

    private func modalAlert(_ title: String, _ msg: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = msg
        a.addButton(withTitle: "확인")
        a.runModal()
    }

    private func close() {
        window.performClose(nil)
    }

    /// 창을 닫으면 다시 띄우지 않는다. **연결이 안 끝났어도** 그렇다 —
    /// 계속 조르는 건 메뉴바(연결된 기기 0대 안내)가 맡는다. 역할을 나눈다.
    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        _ = markOnboardingDone()
        OnboardingWindowController.shared = nil
    }

    // MARK: - 작은 조각들

    private func spacer(_ h: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }

    private func step(done: Bool, n: Int, title: String, detail: String) -> NSView {
        let mark = NSTextField(labelWithString: done ? "✅" : "\(n)")
        mark.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        mark.textColor = done ? .systemGreen : .secondaryLabelColor
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let head = NSTextField(labelWithString: title)
        head.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        if done { head.textColor = .secondaryLabelColor }

        let sub = settingsLabel(detail, secondary: true)
        let texts = NSStackView(views: [head, sub])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2

        let row = NSStackView(views: [mark, texts])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 8
        return row
    }

    /// 단계 본문과 줄을 맞추기 위한 들여쓰기.
    private func indented(_ views: [NSView]) -> NSView {
        let pad = NSView()
        pad.translatesAutoresizingMaskIntoConstraints = false
        pad.widthAnchor.constraint(equalToConstant: 22).isActive = true
        return settingsRow([pad] + views)
    }

    private func button(_ title: String, _ onClick: @escaping () -> Void) -> NSButton {
        let t = ActionTarget { _ in onClick() }
        retained.append(t)
        let b = NSButton(title: title, target: t, action: #selector(ActionTarget.fire(_:)))
        b.bezelStyle = .rounded
        return b
    }
}

func openURL(_ s: String) {
    guard let u = URL(string: s) else { return }
    NSWorkspace.shared.open(u)
}
