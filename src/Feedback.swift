import AppKit

// MARK: - 문의
//
// UX 는 앱 안에서, **전송만 메일 앱으로** 간다.
//
// ⚠ 인앱 전송을 하려면 서버(또는 서드파티 폼)가 필요하고, 그 순간 **"이 앱은 네트워크로
//   데이터를 보낼 수 있다"** 가 사실이 된다. 소스는 비공개라 사용자가 확인할 방법도 없다.
//   "외부로 아무것도 보내지 않는다"는 이 제품이 파는 신뢰의 핵심이라 그걸 내주지 않는다.
//   덤으로 메일은 **사용자 메일함에 사본이 남아** "보냈는데 답이 없다"가 되지 않는다.
//
// 대신 겉모습은 폼이다 — 제목·내용을 여기서 쓰고, 무엇이 첨부되는지 **미리 보고**,
// 마지막 한 번만 메일 앱이 열린다(다 채워지고 첨부까지 붙은 상태로).

final class FeedbackWindowController: NSObject, NSWindowDelegate {
    nonisolated(unsafe) static var shared: FeedbackWindowController?

    private var window: NSWindow!
    private let cfg: Config
    private var retained: [Any] = []
    private let subjectField = NSTextField(string: "")
    private let bodyView = NSTextView()
    private var attachDiagnostics = true

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
        let c = FeedbackWindowController(config: config)
        c.build()
        shared = c
        c.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let W: CGFloat = 560, H: CGFloat = 560
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "문의"
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false

        let s = NSStackView()
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 10
        s.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        s.translatesAutoresizingMaskIntoConstraints = false

        let head = NSTextField(labelWithString: "무엇이 잘 안 되나요?")
        head.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        s.addArrangedSubview(head)
        s.addArrangedSubview(uiWrapLabel(
            "어떤 상황에서 그랬는지 적어 주시면 원인을 훨씬 빨리 찾습니다. "
            + "「어느 맥에서 · 어느 원격 도구로 · 무엇을 하다가」 이 셋이면 충분합니다.",
            width: 516, size: 12))

        subjectField.placeholderString = "제목 — 예: 캡스락을 눌러도 상대 맥이 안 바뀝니다"
        subjectField.translatesAutoresizingMaskIntoConstraints = false
        subjectField.widthAnchor.constraint(equalToConstant: 516).isActive = true
        s.addArrangedSubview(subjectField)

        // 본문 — 스크롤 되는 여러 줄 입력
        bodyView.isRichText = false
        bodyView.font = NSFont.systemFont(ofSize: 12)
        bodyView.isEditable = true
        bodyView.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = bodyView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: 516),
            scroll.heightAnchor.constraint(equalToConstant: 190),
        ])
        s.addArrangedSubview(scroll)

        // 첨부
        s.addArrangedSubview(uiSection("함께 보낼 정보"))
        let sw = NSSwitch()
        sw.state = .on
        let t = ActionTarget { [weak self] sender in
            guard let sw = sender as? NSSwitch else { return }
            self?.attachDiagnostics = (sw.state == .on)
        }
        retained.append(t)
        sw.target = t
        sw.action = #selector(ActionTarget.fire(_:))
        s.addArrangedSubview(uiRow(icon: "doc.text.magnifyingglass",
            title: "진단 정보 함께 보내기",
            detail: "버전·macOS·연결 기기·최근 24시간 로그. "
                  + "기기 이름·IP·다른 앱 이름은 가려서 보냅니다.",
            trailing: sw, width: 516, trailingWidth: 44))
        s.addArrangedSubview(button("무엇이 담기는지 보기") { [weak self] in self?.preview() })

        s.addArrangedSubview(uiWrapLabel(
            "문의로 보내주신 정보는 문제 해결에만 쓰고 보관하지 않습니다. "
            + "앱이 직접 보내지 않으며, 메일 앱이 열리면 내용을 확인하고 직접 보내시면 됩니다.",
            width: 516, size: 11))

        let buttons = NSStackView(views: [
            button("취소") { [weak self] in self?.window.performClose(nil) },
            button("진단 파일만 저장") { [weak self] in self?.saveOnly() },
            button("메일 앱으로 보내기") { [weak self] in self?.send() },
        ])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        s.addArrangedSubview(buttons)

        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        root.autoresizingMask = [.width, .height]
        root.addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            s.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            s.topAnchor.constraint(equalTo: root.topAnchor),
        ])
        window.contentView = root
    }

    // MARK: - 동작

    private func report() -> String {
        collectDiagnosticReport(cfg: cfg,
                                options: .init(includeLog: attachDiagnostics))
    }

    /// 무엇이 담기는지 **그대로** 보여준다. 이게 이 창의 핵심이다 —
    /// 모르고 보내는 것보다 나쁜 건 없다.
    private func preview() {
        let text = report()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "함께 보낼 진단 정보"
        let tv = NSTextView()
        tv.string = text
        tv.isEditable = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.autoresizingMask = [.width]
        let sc = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 520))
        sc.hasVerticalScroller = true
        sc.autoresizingMask = [.width, .height]
        sc.documentView = tv
        win.contentView = sc
        win.center()
        retained.append(win)   // 지역변수로 두면 즉시 닫힌다
        win.makeKeyAndOrderFront(nil)
    }

    private func saveOnly() {
        guard let url = writeDiagnosticFile(report()) else {
            alert("파일을 만들지 못했습니다", "임시 폴더에 쓸 수 없습니다."); return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func send() {
        let subject = subjectField.stringValue.trimmingCharacters(in: .whitespaces)
        let body = bodyView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty || !body.isEmpty else {
            alert("내용을 적어 주세요", "무엇이 안 되는지 한 줄이라도 있어야 원인을 찾을 수 있습니다.")
            return
        }
        var items: [Any] = [body.isEmpty ? "(내용 없음)" : body]
        var fileURL: URL?
        if attachDiagnostics {
            fileURL = writeDiagnosticFile(report())
            if let u = fileURL { items.append(u) }
        }
        let title = subject.isEmpty ? "macbridge 문의" : "macbridge 문의 — \(subject)"

        // ⚠ mailto: 로는 **첨부가 불가능하다**(RFC 6068 에 첨부 필드가 없다).
        //   NSSharingService 는 기본 메일 앱을 첨부와 함께 연다.
        let service = NSSharingService(named: .composeEmail)
        service?.recipients = [feedbackEmail]
        service?.subject = title
        if service?.canPerform(withItems: items) == true {
            service?.perform(withItems: items)
            window.performClose(nil)
            return
        }

        // 폴백 — 기본 메일 클라이언트가 없는 사람(웹 Gmail 만 쓰는 경우)이 있다.
        // 조용히 실패하지 않고, 파일 위치를 열어 주면서 왜 이렇게 됐는지 말한다.
        if let u = fileURL {
            NSWorkspace.shared.activateFileViewerSelecting([u])
            alert("메일 앱을 열지 못했습니다",
                  "기본 메일 앱이 설정돼 있지 않은 것 같습니다.\n\n"
                  + "진단 파일 위치를 열어 두었습니다. \(feedbackEmail) 로 메일을 보내실 때\n"
                  + "이 파일을 첨부해 주세요.")
        } else {
            alert("메일 앱을 열지 못했습니다",
                  "\(feedbackEmail) 로 직접 보내 주세요.")
        }
    }

    private func alert(_ t: String, _ b: String) {
        let a = NSAlert()
        a.messageText = t
        a.informativeText = b
        a.addButton(withTitle: "확인")
        a.runModal()
    }

    private func button(_ title: String, _ onClick: @escaping () -> Void) -> NSButton {
        let t = ActionTarget { _ in onClick() }
        retained.append(t)
        let b = NSButton(title: title, target: t, action: #selector(ActionTarget.fire(_:)))
        b.bezelStyle = .rounded
        return b
    }

    func windowWillClose(_ notification: Notification) {
        FeedbackWindowController.shared = nil
    }
}
