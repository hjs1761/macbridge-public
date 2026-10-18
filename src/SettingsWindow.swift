import Foundation
import AppKit

/// 클로저를 target/action 으로 쓰기 위한 어댑터.
/// ⚠ **반드시 어딘가에 강하게 붙들어야 한다** — 지역 변수로 두면 ARC 가 해제해
///   버튼을 눌러도 아무 일이 없다(Phase 1 에서 타이머·옵저버로 같은 함정을 밟았다).
final class ActionTarget: NSObject {
    private let handler: (Any) -> Void
    init(_ handler: @escaping (Any) -> Void) { self.handler = handler }
    @objc func fire(_ sender: Any) { handler(sender) }
}

/// 설정 창. 메뉴바 프로세스에 산다(데몬은 GUI 없이 유지).
final class SettingsWindowController: NSObject, NSWindowDelegate {
    nonisolated(unsafe) static var shared: SettingsWindowController?

    private var window: NSWindow!
    private var tabView: NSTabView!
    /// ActionTarget·컨트롤을 붙들어 두는 곳 (위 ARC 함정)
    var retained: [Any] = []
    /// 현재 설정 스냅샷. 저장할 때마다 다시 읽어 화면을 맞춘다.
    private(set) var cfg: Config

    init(config: Config) {
        self.cfg = config
        super.init()
    }

    /// 이미 떠 있으면 앞으로 가져온다.
    static func show(config: Config) {
        if let s = shared {
            s.reloadFromDisk()
            s.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let c = SettingsWindowController(config: config)
        c.build()
        shared = c
        c.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let W: CGFloat = 600, H: CGFloat = 520
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "macbridge 설정"
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false   // 닫았다 다시 열 수 있게

        let barH = Self.statusBarHeight
        tabView = NSTabView(frame: NSRect(x: 0, y: barH, width: W, height: H - barH))
        tabView.autoresizingMask = [.width, .height]
        rebuildTabs()

        // 하단 바 — 버전·제작자와 늘 닿아야 하는 링크들. 어느 탭에 있든 보인다.
        // "지금 뭘 쓰고 있는지"와 "막히면 어디로 가는지"가 항상 화면에 있어야 한다.
        let bar = buildStatusBar(width: W)

        let root = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        root.addSubview(tabView)
        root.addSubview(bar)
        window.contentView = root
    }

    /// 하단 바 높이. 34 는 글자가 위아래로 끼어 답답했다 — 숨 쉴 자리를 준다.
    static let statusBarHeight: CGFloat = 44

    private func buildStatusBar(width W: CGFloat) -> NSView {
        let H = Self.statusBarHeight
        // ⚠ 높이만 늘려서는 답답함이 안 풀린다 — **배경이 같으면 바로 안 읽힌다.**
        //   살짝 다른 바탕을 깔아야 "여기는 본문이 아니라 도구줄"로 구분된다.
        let bar = FooterView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        bar.autoresizingMask = [.width]

        let ver = NSTextField(labelWithString:
            "macbridge \(appVersionString) · 제작 hjs1761")
        ver.font = NSFont.systemFont(ofSize: 11)
        ver.textColor = .tertiaryLabelColor

        let links = NSStackView(views: [
            linkButton("가이드") { openURL(guidePageURL) },
            linkButton("문의") { [weak self] in self?.composeFeedback() },
            // ⚠ 「시작하기」라고 부르면 **뭔가 시작되는 줄 안다.** 실제로 하는 일은
            //   두 번째 맥에 까는 절차를 다시 보여주는 것뿐이라 이름을 그대로 적는다.
            linkButton("설치 안내") { [weak self] in
                guard let s = self else { return }
                OnboardingWindowController.show(config: s.cfg)
            },
        ])
        links.orientation = .horizontal
        links.spacing = 18

        let gap = NSView()
        gap.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [ver, gap, links])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 22)

        let sep = NSBox(frame: NSRect(x: 0, y: H - 1, width: W, height: 1))
        sep.boxType = .separator
        sep.autoresizingMask = [.width]

        bar.addSubview(row)
        bar.addSubview(sep)

        // ⚠ NSStackView 는 `translatesAutoresizingMaskIntoConstraints` 가 **false** 라서
        //   frame 을 줘도 무시된다. 그대로 두면 크기가 내용에 맞춰지고 원점(왼쪽 **아래**)에
        //   붙어, "글자가 바닥에 붙고 위가 텅 빈" 모습이 된다. 네 변을 물려 세로 중앙에 오게 한다.
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            row.topAnchor.constraint(equalTo: bar.topAnchor),
            row.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        return bar
    }

    private func linkButton(_ title: String, _ onClick: @escaping () -> Void) -> NSButton {
        let t = ActionTarget { _ in onClick() }
        retained.append(t)
        let b = NSButton(title: title, target: t, action: #selector(ActionTarget.fire(_:)))
        b.isBordered = false
        b.contentTintColor = .controlAccentColor
        b.font = NSFont.systemFont(ofSize: 11)
        return b
    }

    /// 문의 창을 연다. 전송은 그 안에서 메일 앱으로 넘긴다(Feedback.swift 의 주석 참조).
    private func composeFeedback() {
        FeedbackWindowController.show(config: cfg)
    }

    /// 탭 내용은 설정이 바뀔 때마다 통째로 다시 그린다 — 부분 갱신보다 단순하고 어긋날 여지가 없다.
    func rebuildTabs() {
        let selected = tabView.selectedTabViewItem.map { tabView.indexOfTabViewItem($0) } ?? 0
        retained.removeAll()
        while tabView.numberOfTabViewItems > 0 {
            tabView.removeTabViewItem(tabView.tabViewItem(at: 0))
        }
        for (label, view) in [
            ("일반",      makeGeneralPane(self)),
            ("원격 도구",  makeToolsPane(self)),
            ("기기",      makeDevicesPane(self)),
            ("사용 방법",  makeHowToPane(self)),
            ("고급",      makeAdvancedPane(self)),
        ] {
            let item = NSTabViewItem(identifier: label)
            item.label = label
            item.view = view
            tabView.addTabViewItem(item)
        }
        if selected >= 0 && selected < tabView.numberOfTabViewItems {
            tabView.selectTabViewItem(at: selected)
        }
    }

    /// 디스크에서 다시 읽어 화면을 맞춘다(데몬이 그 사이 바꿨을 수 있다).
    func reloadFromDisk() {
        if let fresh = try? loadConfig(path: argValue("--config") ?? defaultConfigPath) {
            cfg = fresh
        }
        rebuildTabs()
    }

    /// 설정을 바꾸고 데몬에 알린다. **저장과 반영을 구분해서** 보고한다 —
    /// 뭉뚱그리면 둘 중 뭐가 안 됐는지 알 수 없다.
    /// - Returns: 저장에 성공하면 true
    @discardableResult
    func save(_ mutate: (inout [String: Any]) -> Void) -> Bool {
        if let err = updateConfigFile(mutate) {
            alert("저장하지 못했습니다", "사유: \(err)\n설정 파일 권한을 확인하세요.")
            reloadFromDisk()          // 화면을 실제 상태로 되돌린다(거짓 성공 금지)
            return false
        }
        let reply = DaemonClient.control(cfg, "ctl reload", timeout: 2.0)
        switch reply {
        case "ok":
            break
        case "ok restart-needed":
            alert("저장했습니다 — 재시작이 필요합니다",
                  "포트 변경은 데몬을 다시 시작해야 적용됩니다.\n"
                  + "터미널에서: launchctl kickstart -k gui/$(id -u)/com.hjs.macbridge")
        case .none:
            alert("저장은 했지만 반영하지 못했습니다",
                  "데몬이 응답하지 않습니다. 실행 중인지 확인하세요.\n"
                  + "launchctl list | grep macbridge")
        case .some(let e):
            alert("저장은 했지만 반영하지 못했습니다", "데몬 응답: \(e)")
        }
        reloadFromDisk()
        return true
    }

    func alert(_ title: String, _ body: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.alertStyle = .warning
        a.beginSheetModal(for: window, completionHandler: nil)
    }

    /// 확인이 필요한 위험한 변경용. 확인하면 true.
    func confirm(_ title: String, _ body: String, okTitle: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.alertStyle = .warning
        a.addButton(withTitle: okTitle)
        a.addButton(withTitle: "취소")
        return a.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - 폼 헬퍼

/// 세로 스택 한 장. 각 탭이 이걸로 시작한다.
func settingsStack() -> NSStackView {
    let s = NSStackView()
    s.orientation = .vertical
    s.alignment = .leading
    s.spacing = 10
    s.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
    s.translatesAutoresizingMaskIntoConstraints = true
    s.frame = NSRect(x: 0, y: 0, width: 540, height: 400)
    s.autoresizingMask = [.width, .height]
    return s
}

func settingsLabel(_ text: String, secondary: Bool = false) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    if secondary {
        l.textColor = .secondaryLabelColor
        l.font = NSFont.systemFont(ofSize: 11)
    }
    return l
}

/// 체크박스 한 줄. ⚠ `inout` 대신 컨트롤러를 받는다 — 클래스 프로퍼티에 `&` 를 쓰면
/// 같은 호출에서 클로저가 그 객체를 캡처할 때 배타적 접근 검사에 걸릴 수 있다.
func settingsCheckbox(_ title: String, checked: Bool, enabled: Bool = true,
                      owner c: SettingsWindowController,
                      _ onToggle: @escaping (Bool) -> Void) -> NSButton {
    let t = ActionTarget { sender in
        guard let b = sender as? NSButton else { return }
        onToggle(b.state == .on)
    }
    c.retained.append(t)
    let b = NSButton(checkboxWithTitle: title, target: t, action: #selector(ActionTarget.fire(_:)))
    b.state = checked ? .on : .off
    b.isEnabled = enabled
    return b
}

func settingsButton(_ title: String, owner c: SettingsWindowController,
                    _ onClick: @escaping () -> Void) -> NSButton {
    let t = ActionTarget { _ in onClick() }
    c.retained.append(t)
    let b = NSButton(title: title, target: t, action: #selector(ActionTarget.fire(_:)))
    b.bezelStyle = .rounded
    return b
}

/// 가로로 붙이는 줄.
func settingsRow(_ views: [NSView]) -> NSStackView {
    let r = NSStackView(views: views)
    r.orientation = .horizontal
    r.alignment = .centerY
    r.spacing = 8
    return r
}
