import Foundation
import AppKit

// MARK: - 일반

func makeGeneralPane(_ c: SettingsWindowController) -> NSView {
    let s = uiStack()

    // 맨 위에 **지금 잘 되고 있는지**부터 보여준다. 설정만 나열하면 값은 보이는데
    // "그래서 되고 있나?"를 알 수 없다 — 사용자가 제일 먼저 궁금해하는 건 그쪽이다.
    let summary = StatusSummary(cfg: c.cfg)
    c.retained.append(summary)   // ⚠ 놓으면 ARC 가 걷어가 타이머가 죽는다
    s.addArrangedSubview(summary.view)

    s.addArrangedSubview(uiSection("이 기기"))
    let nameField = NSTextField(string: c.cfg.deviceName)
    nameField.translatesAutoresizingMaskIntoConstraints = false
    nameField.widthAnchor.constraint(equalToConstant: 170).isActive = true
    let nameTarget = ActionTarget { sender in
        guard let f = sender as? NSTextField else { return }
        let v = f.stringValue.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, v != c.cfg.deviceName else { return }
        c.save { root in
            var dev = root["device"] as? [String: Any] ?? [:]
            dev["name"] = v
            root["device"] = dev
        }
    }
    c.retained.append(nameTarget)
    nameField.target = nameTarget
    nameField.action = #selector(ActionTarget.fire(_:))
    // Enter 뿐 아니라 **포커스가 빠질 때도** 저장한다. 이게 없으면 값을 고치고
    // 다른 탭으로 넘어갔을 때 조용히 사라진다.
    (nameField.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
    s.addArrangedSubview(uiRow(icon: "desktopcomputer", title: "기기 이름",
                               detail: "다른 기기의 목록에 이 이름으로 보입니다",
                               trailing: nameField, trailingWidth: 170))

    s.addArrangedSubview(uiSection("한/영"))
    s.addArrangedSubview(uiRow(icon: "arrow.left.arrow.right", title: "한/영 자동 동기화",
        detail: "끄면 이 기기는 동기화에 참여하지 않습니다 — 보내지도 받지도 않습니다",
        trailing: uiSwitch(on: c.cfg.imeSyncEnabled, owner: c) { on in
            c.save { root in
                var ime = root["ime_sync"] as? [String: Any] ?? [:]
                ime["enabled"] = on
                root["ime_sync"] = ime
            }
        }))
    s.addArrangedSubview(uiRow(icon: "wand.and.stars", title: "자소분리 자동복구",
        detail: "어긋나면 스스로 맞추고 창을 한 번 전환해 꼬인 입력을 풉니다 (잠깐 깜빡입니다)",
        trailing: uiSwitch(on: c.cfg.autoRecover, owner: c) { on in
            c.save { root in
                var ime = root["ime_sync"] as? [String: Any] ?? [:]
                ime["auto_recover"] = on
                root["ime_sync"] = ime
            }
        }))

    // 앱으로 설치했을 때만 보여준다 — 터미널 설치본은 LaunchAgent 가 그 일을 한다
    if LoginItem.isSupported {
        s.addArrangedSubview(uiSection("시작"))
        s.addArrangedSubview(uiRow(icon: "power", title: "로그인할 때 자동 시작",
            detail: "맥을 켜면 백그라운드에서 알아서 뜹니다",
            trailing: uiSwitch(on: LoginItem.isEnabled, owner: c) { on in
                if let err = LoginItem.set(on) {
                    c.alert("자동 시작을 바꾸지 못했습니다", err)
                }
                c.rebuildTabs()   // 실제 상태로 다시 그린다(거짓 성공 금지)
            }))
    }

    return uiScrollPane(s)
}

/// 「지금 잘 되고 있나」 한 장.
///
/// ⚠ **스스로 갱신해야 한다.** 탭을 그릴 때 한 번만 계산하면, 복구한 뒤에도
///   "어긋나 있습니다"가 그대로 남아 **화면이 거짓말을 한다**(2026-08-08 실사용 지적).
final class StatusSummary: NSObject {
    let view: NSView
    private let cfg: Config
    private let head = NSTextField(wrappingLabelWithString: "")
    private let sub = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?

    init(cfg: Config) {
        self.cfg = cfg
        let w = uiCardInnerWidth()
        for (l, size) in [(head, CGFloat(14)), (sub, CGFloat(11))] {
            l.font = NSFont.systemFont(ofSize: size, weight: size > 12 ? .semibold : .regular)
            l.translatesAutoresizingMaskIntoConstraints = false
            l.preferredMaxLayoutWidth = w
            l.widthAnchor.constraint(equalToConstant: w).isActive = true
            l.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        sub.textColor = .secondaryLabelColor
        view = uiCard([head, sub])
        super.init()
        refresh()
        let t = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit { timer?.invalidate() }

    private func refresh() {
        let snap = queryDaemon(cfg, timeout: 0.7)
        let online = snap?.peers.filter(\.isOnline) ?? []
        let mine = snap?.myLang ?? "?"
        let diff = online.filter { $0.lang != mine }

        if snap == nil {
            head.stringValue = "⚠  백그라운드 프로그램이 응답하지 않습니다"
            head.textColor = .systemOrange
            sub.stringValue = "앱을 껐다 켜 보세요. 계속되면 하단 「문의」로 알려 주세요."
        } else if online.isEmpty {
            head.stringValue = "○  아직 연결된 기기가 없습니다"
            head.textColor = .secondaryLabelColor
            sub.stringValue = "맥 두 대가 연결돼야 한/영이 맞춰집니다. "
                + "하단 「설치 안내」를 눌러 보세요."
        } else if diff.isEmpty {
            head.stringValue = "●  \(online.map(\.name).joined(separator: ", ")) 와(과) 맞춰져 있습니다"
            head.textColor = .systemGreen
            sub.stringValue = "지금 모두 \(mine == "ko" ? "한글" : "영문") 입니다."
        } else {
            // ⚠ 경고로 쓰지 않는다. 잠긴 맥은 잠금 화면이 입력 소스를 영문으로 **강제**하므로
            //   늘 달라 보인다 — 그게 정상인데 붉게 띄우면 매번 놀란다.
            head.stringValue = "◐  \(diff.map(\.name).joined(separator: ", ")) 의 한/영이 다릅니다"
            head.textColor = .secondaryLabelColor
            sub.stringValue = "그 맥이 잠겨 있으면 정상입니다 — 잠금 화면은 영문으로 고정됩니다. "
                + "쓰는 중인데도 다르면 「사용 방법」 탭의 복구를 써 보세요."
        }
    }
}

// MARK: - 고급

func makeAdvancedPane(_ c: SettingsWindowController) -> NSView {
    let s = uiStack()

    // --- 연결 코드(토큰) ---
    let masked = c.cfg.token.count > 8
        ? String(c.cfg.token.prefix(8)) + "…"
        : c.cfg.token
    s.addArrangedSubview(uiSection("연결 코드", topGap: 0))
    s.addArrangedSubview(uiRow(icon: "key", title: masked,
        detail: "연결할 모든 기기가 같은 코드를 써야 합니다",
        trailing: uiButton("복사", owner: c) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(c.cfg.token, forType: .string)
        }, trailingWidth: 60))
    s.addArrangedSubview(uiRow(icon: "arrow.triangle.swap", title: "다른 기기의 코드로 바꾸기",
        detail: "지금 연결된 기기들과 즉시 끊어집니다",
        trailing: uiButton("바꾸기", owner: c) { promptReplaceToken(c) }, trailingWidth: 70))

    // --- 포트 ---
    s.addArrangedSubview(uiSection("네트워크"))
    let portField = NSTextField(string: String(c.cfg.port))
    portField.translatesAutoresizingMaskIntoConstraints = false
    portField.widthAnchor.constraint(equalToConstant: 90).isActive = true
    let portTarget = ActionTarget { sender in
        guard let f = sender as? NSTextField else { return }
        let raw = f.stringValue.trimmingCharacters(in: .whitespaces)
        guard let p = UInt16(raw), p >= 1024 else {
            c.alert("포트가 올바르지 않습니다", "1024 이상 65535 이하의 숫자를 넣으세요.")
            c.reloadFromDisk()
            return
        }
        guard p != c.cfg.port else { return }
        c.save { root in root["port"] = Int(p) }
    }
    c.retained.append(portTarget)
    portField.target = portTarget
    portField.action = #selector(ActionTarget.fire(_:))
    (portField.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
    s.addArrangedSubview(uiRow(icon: "network", title: "수신 포트",
        detail: "바꾸면 데몬을 다시 시작해야 적용됩니다",
        trailing: portField, trailingWidth: 90))

    // --- 허용 대역 ---
    s.addArrangedSubview(uiSection("수신을 허용할 대역"))
    let labels = c.cfg.allowFrom.map(\.label)
    let hasTS  = labels.contains { $0.hasPrefix("tailscale") }
    let hasLAN = labels.contains { $0.hasPrefix("lan") }
    let hasAny = labels.contains("any")

    func writeAllow(ts: Bool, lan: Bool, any: Bool) {
        var v: [String] = []
        if any { v = ["any"] } else {
            if ts { v.append("tailscale") }
            if lan { v.append("lan") }
        }
        guard !v.isEmpty else {
            c.alert("최소 하나는 켜야 합니다", "모두 끄면 아무 기기와도 통신할 수 없습니다.")
            c.reloadFromDisk()
            return
        }
        c.save { root in root["allow_from"] = v }
    }

    let tsSwitch = uiSwitch(on: hasTS, owner: c) { on in
        writeAllow(ts: on, lan: hasLAN, any: false)
    }
    (tsSwitch as? NSSwitch)?.isEnabled = !hasAny
    s.addArrangedSubview(uiRow(icon: "point.3.connected.trianglepath.dotted",
        title: "Tailscale", detail: "100.64.0.0/10",
        trailing: tsSwitch, trailingWidth: 44))

    let lanSwitch = uiSwitch(on: hasLAN, owner: c) { on in
        writeAllow(ts: hasTS, lan: on, any: false)
    }
    (lanSwitch as? NSSwitch)?.isEnabled = !hasAny
    s.addArrangedSubview(uiRow(icon: "house", title: "사설망 (LAN)",
        detail: "같은 공유기에 물린 기기", trailing: lanSwitch, trailingWidth: 44))

    s.addArrangedSubview(uiRow(icon: "globe.badge.chevron.backward", title: "전체 허용",
        detail: "어느 망에서든 연결 코드만 맞으면 이 기기의 한/영을 바꿀 수 있습니다",
        trailing: uiSwitch(on: hasAny, owner: c) { on in
            if on {
                guard c.confirm("전체 허용으로 바꿀까요?",
                                "어느 망에서든 연결 코드만 맞으면 이 기기의 한/영을 바꿀 수 있게 됩니다.\n"
                                + "신뢰된 망에서만 쓰세요.",
                                okTitle: "전체 허용") else { c.reloadFromDisk(); return }
                writeAllow(ts: false, lan: false, any: true)
            } else {
                writeAllow(ts: true, lan: true, any: false)
            }
        }, trailingWidth: 44))

    s.addArrangedSubview(uiSection("진단"))
    s.addArrangedSubview(uiRow(icon: "doc.text", title: "설정 파일 열기",
        detail: defaultConfigPath,
        trailing: uiButton("열기", owner: c) {
            NSWorkspace.shared.open(URL(fileURLWithPath: defaultConfigPath))
        }, trailingWidth: 60))
    s.addArrangedSubview(uiRow(icon: "list.bullet.rectangle", title: "로그 보기",
        detail: "~/Library/Logs/macbridge.log — 문의하실 때 함께 보내 주시면 좋습니다",
        trailing: uiButton("열기", owner: c) {
            let logURL = URL(fileURLWithPath:
                logFilePath)
            let console = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
            NSWorkspace.shared.open([logURL], withApplicationAt: console,
                                    configuration: NSWorkspace.OpenConfiguration())
        }, trailingWidth: 60))

    return uiScrollPane(s)
}

/// 다른 기기의 연결 코드를 붙여넣어 교체한다.
private func promptReplaceToken(_ c: SettingsWindowController) {
    let a = NSAlert()
    a.messageText = "다른 기기의 연결 코드로 바꾸기"
    a.informativeText = "⚠ 지금 연결된 기기들과 즉시 끊어집니다.\n"
        + "새로 연결할 기기의 [고급] 탭에서 복사한 코드를 붙여넣으세요."
    a.alertStyle = .warning
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
    a.accessoryView = field
    a.addButton(withTitle: "바꾸기")
    a.addButton(withTitle: "취소")
    guard a.runModal() == .alertFirstButtonReturn else { return }

    let v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard v.count >= 8 else {
        c.alert("연결 코드가 너무 짧습니다", "복사한 코드를 그대로 붙여넣었는지 확인하세요.")
        return
    }
    c.save { root in root["token"] = v }
}
