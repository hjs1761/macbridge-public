import Foundation
import AppKit

/// 메뉴바 상태 아이템. 데몬과 별개 프로세스로 돈다.
///
/// 아이콘은 현재 언어(`한`/`A`)를 텍스트로 보여주고, **온라인 피어와 언어가 다르면 주황색**이 된다.
/// macOS 기본 입력 소스 메뉴와 겹치지만 **불일치 경고**는 기본 메뉴가 못 하는 일이고 그게 존재 이유다.
/// ⚠ `NSStatusItem` 은 **앱 기동이 끝난 뒤**(`applicationDidFinishLaunching`) 만들어야 한다.
/// `app.run()` 전에 만들면 `isVisible == true` 로 보고되면서도 **화면에 나타나지 않는다**(실측).
/// 그래서 이 컨트롤러가 앱 델리게이트를 겸한다.
final class MenuBarController: NSObject, NSMenuDelegate, NSApplicationDelegate {
    private let cfg: Config
    private var item: NSStatusItem!
    private var timer: DispatchSourceTimer?
    private var latest: QueryResult?
    /// 데몬의 현재 동기화 on/off. 시작 시 config 값으로 두고 토글할 때 갱신한다.
    /// (`cfg` 는 값 타입이라 직접 못 바꾼다)
    private var syncEnabled: Bool
    /// 「먼저 말 걸기」로 지금 물어보고 있는 앱. 메뉴를 그릴 때 세팅되고 항목 핸들러가 읽는다.
    private var suggestedTool: String?

    init(config: Config) {
        self.cfg = config
        self.syncEnabled = config.imeSyncEnabled
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) { start() }

    private func start() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 사용자가 ⌘드래그로 옮긴 위치를 기억한다. Ice·Bartender 같은 메뉴바 관리 앱을 쓰면
        // 새 아이템이 **숨김 영역**에 들어가 안 보일 수 있는데(실측), 한 번 꺼내 두면 유지된다.
        item.autosaveName = "macbridge"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refresh()

        // 평상시 2초 주기. 루프백 UDP 1패킷이라 부담이 없다.
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t

        // ⚠ 계측: 상태 아이템이 실제로 화면에 자리를 잡았는지. 메뉴바가 꽉 차면 macOS 가
        //   조용히 숨기므로(특히 노치 모델), "떴는데 안 보임"을 로그로 구분할 수 있어야 한다.
        let f = item.button?.window?.frame
        log("메뉴바 시작 — 아이템 위치 \(f.map { "x=\(Int($0.origin.x)) y=\(Int($0.origin.y)) w=\(Int($0.width))" } ?? "(창 없음)")"
            + " · 표시 \(item.isVisible ? "O" : "X") · 제목 \"\(item.button?.attributedTitle.string ?? "?")\"")
    }

    /// 메뉴를 여는 순간 최신값으로 다시 그린다(2초 지연을 사용자가 보지 않도록).
    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        rebuild(menu)
    }

    private func refresh() {
        latest = queryDaemon(cfg, timeout: 0.5)
        guard let r = latest else {
            item.button?.attributedTitle = Self.title("⚠", color: .systemRed)
            return
        }
        let mismatch = r.peers.contains { $0.isOnline && $0.lang != r.myLang }
        let label = r.myLang == "ko" ? "한" : (r.myLang == "en" ? "A" : "?")
        item.button?.attributedTitle = Self.title(label,
                                                  color: mismatch ? .systemOrange : .labelColor)
    }

    private static func title(_ s: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        ])
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        guard let r = latest else {
            // 조용히 "응답 없음"만 띄우지 않는다 — 등록 자체가 실패했으면 그 사유가 진짜 원인이다
            if let err = globalDaemonSetupError {
                menu.addItem(disabled("⚠ 데몬을 등록하지 못했습니다"))
                menu.addItem(disabled("   \(err)"))
            } else {
                menu.addItem(disabled("데몬 응답 없음 — launchctl list | grep macbridge"))
            }
            menu.addItem(.separator())
            menu.addItem(action("로그 보기", #selector(openLog)))
            menu.addItem(action("메뉴바 종료", #selector(quitMenuBar)))
            return
        }

        menu.addItem(disabled(" ● \(cfg.deviceName)(나)   \(r.myLang)"))
        for p in r.peers {
            let mark = p.isOnline ? "●" : "○"
            let ago = p.isOnline ? String(format: "%.1f초 전", Double(p.agoMs) / 1000) : "오프라인"
            let warn = (p.isOnline && p.lang != r.myLang) ? "  ⚠" : ""
            menu.addItem(disabled(" \(mark) \(p.name)   \(p.isOnline ? p.lang : "—")   \(ago)\(warn)"))
        }

        // 연결된 기기가 없으면 이 앱은 **아무 일도 하지 않는다.** 맞출 상대가 없으니까.
        // 조용히 두면 "설치했는데 안 되네"로 읽히므로 맨 위에서 먼저 말한다.
        // (온보딩 창은 한 번 닫으면 다시 안 뜬다 — 계속 조르는 역할은 여기가 맡는다)
        if r.peers.isEmpty {
            menu.addItem(disabled("⚠ 아직 연결된 기기가 없습니다"))
            menu.addItem(disabled("   맥 두 대가 연결돼야 한/영이 맞춰집니다"))
            menu.addItem(action("   → 시작하기 열기", #selector(openOnboarding)))
            menu.addItem(.separator())
        }

        // 「먼저 말 걸기」 — 목록에 없는 앱 때문에 조용히 동기화가 꺼져 있는 상태를 **앱이 먼저 알린다.**
        // 이게 없으면 사용자는 로그를 열어야만 원인을 알 수 있고, 실제로는 "고장났다"고 판단한다.
        // 맨 위에 둔다 — 메뉴를 연 사람이 제일 먼저 봐야 할 내용이다.
        if let id = r.suggestedTool {
            suggestedTool = id
            menu.addItem(disabled("⚠ \(appDisplayName(id)) 은(는) 원격 도구 목록에 없습니다"))
            menu.addItem(disabled("   그래서 지금 한/영이 동기화되지 않습니다"))
            menu.addItem(action("   → 원격 도구에 추가", #selector(acceptToolHint)))
            menu.addItem(action("   → 원격 도구 아닙니다 (다시 묻지 않음)", #selector(dismissToolHint)))
            menu.addItem(.separator())
        } else {
            suggestedTool = nil
        }

        menu.addItem(.separator())
        // 동기화를 끄면 realign 도 안 나간다(전면 불참). 항목을 그대로 두면 눌러도 아무 일이
        // 없어 고장으로 보이므로, 왜 안 되는지를 항목 자체가 말하게 한다.
        // ⚠ autoenablesItems 기본값 탓에 isEnabled=false 는 무시된다 — action 을 비워야 회색이 된다.
        if syncEnabled {
            let realign = action("지금 정렬", #selector(doRealign))
            realign.keyEquivalent = "k"
            realign.keyEquivalentModifierMask = [.control, .option, .shift]
            menu.addItem(realign)
        } else {
            menu.addItem(disabled("지금 정렬 — 동기화가 꺼져 있습니다"))
        }

        let toggle = action("IME 동기화", #selector(toggleSync))
        toggle.state = syncEnabled ? .on : .off
        menu.addItem(toggle)

        menu.addItem(action("연결 테스트", #selector(testLinks)))
        menu.addItem(action("자소분리 관측 창 열기", #selector(openProbe)))

        menu.addItem(.separator())
        menu.addItem(action("로그 보기", #selector(openLog)))
        // 문제를 겪는 순간이 곧 문의하고 싶은 순간이다 — 설정까지 들어가게 하지 않는다
        menu.addItem(action("문의하기…", #selector(openFeedback)))
        menu.addItem(action("설정…", #selector(openSettings)))
        menu.addItem(action("메뉴바 종료", #selector(quitMenuBar)))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func action(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    // MARK: - 「먼저 말 걸기」

    /// 번들 ID 대신 사람이 아는 이름으로 보여준다 — `tv.parsec.www` 는 아무 의미가 없다.
    /// 앱이 실행 중이 아니면 번들 ID 그대로 (거짓 이름을 지어내지 않는다).
    private func appDisplayName(_ bundleId: String) -> String {
        if let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleId }),
           let name = app.localizedName { return name }
        return bundleId
    }

    @objc private func acceptToolHint() {
        guard let id = suggestedTool else { return }
        let r = DaemonClient.control(cfg, "ctl add-tool \(id)")
        if r == "ok" {
            // cfg 를 다시 읽지 않는다 — 목록을 쓰는 건 데몬이고 이미 런타임까지 갱신됐다.
            // 메뉴바의 cfg 는 토큰·포트·기기이름만 쓴다.
            notify("추가했습니다", "\(appDisplayName(id)) 이(가) 최전면일 때 한/영을 맞춥니다.")
        } else {
            notify("추가 실패", r ?? "데몬 응답 없음")
        }
        suggestedTool = nil
        refresh()
    }

    @objc private func dismissToolHint() {
        guard let id = suggestedTool else { return }
        let r = DaemonClient.control(cfg, "ctl dismiss-tool \(id)")
        if r != "ok" { notify("처리 실패", r ?? "데몬 응답 없음") }
        suggestedTool = nil
        refresh()
    }

    // MARK: - 동작

    @objc private func openOnboarding() {
        OnboardingWindowController.show(config: cfg)
    }

    @objc private func openFeedback() {
        FeedbackWindowController.show(config: cfg)
    }

    @objc private func doRealign() {
        let r = DaemonClient.control(cfg, "ctl realign")
        if r != "ok" { notify("정렬 실패", r ?? "데몬 응답 없음") }
        refresh()
    }

    @objc private func toggleSync() {
        let next = !syncEnabled
        let r = DaemonClient.control(cfg, "ctl sync \(next ? "on" : "off")")
        if r == "ok" { syncEnabled = next }          // config 영속화는 데몬이 했다
        else { notify("동기화 전환 실패", r ?? "데몬 응답 없음") }
        refresh()
    }

    @objc private func testLinks() {
        let peers = cfg.peers
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            var lines: [String] = []
            for p in peers {
                if let ms = DaemonClient.echoRoundTrip(self.cfg, peer: p) {
                    lines.append("\(p.host)  \(ms)ms  ✅")
                } else {
                    lines.append("\(p.host)  응답 없음  ❌")
                }
            }
            DispatchQueue.main.async {
                self.notify("연결 테스트", lines.isEmpty ? "피어 없음" : lines.joined(separator: "\n"))
            }
        }
    }

    @objc private func openProbe() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: NSString(string: "~/bin/macbridge").expandingTildeInPath)
        p.arguments = ["probe"]
        try? p.run()
    }

    /// Console.app 으로 연다. 로그는 평문이라 Console 이 tail 처럼 따라 붙는다.
    @objc private func openLog() {
        let logURL = URL(fileURLWithPath:
            logFilePath)
        let console = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.open([logURL], withApplicationAt: console,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func openSettings() {
        // 창을 열 때마다 디스크에서 다시 읽는다 — 데몬이 그 사이 바꿨을 수 있다.
        let fresh = (try? loadConfig(path: argValue("--config") ?? defaultConfigPath)) ?? cfg
        SettingsWindowController.show(config: fresh)
    }

    /// ⚠ `NSApp.terminate` 만으로는 **꺼지지 않는다.** LaunchAgent 가 `KeepAlive=true` 라
    /// launchd 가 즉시 되살린다(실측: 죽인 지 4초 만에 새 pid 로 부활).
    /// 메뉴가 말한 대로 동작하려면 에이전트를 내려야 한다. 다음 로그인 때는 다시 켜진다.
    @objc private func quitMenuBar() {
        let a = NSAlert()
        a.messageText = "메뉴바 아이콘을 끕니다"
        a.informativeText = "한/영 동기화는 계속 동작합니다.\n\n"
            + "다시 켜려면 터미널에서 아래를 실행하거나, 다시 로그인하세요.\n"
            + "    ~/bin/macbridge menubar"
        a.addButton(withTitle: "끄기")
        a.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "gui/\(getuid())/com.hjs.macbridge.menubar"]
        try? p.run()          // 이 호출이 자기 자신을 내린다
        p.waitUntilExit()
        NSApp.terminate(nil)  // bootout 이 실패했을 때의 폴백
    }

    private func notify(_ title: String, _ body: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
