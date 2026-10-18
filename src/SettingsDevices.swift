import Foundation
import AppKit

func makeDevicesPane(_ c: SettingsWindowController) -> NSView {
    let s = uiStack()
    let snapshot = queryDaemon(c.cfg, timeout: 0.7)

    s.addArrangedSubview(uiSection("연결된 기기", topGap: 0))
    if c.cfg.peers.isEmpty {
        s.addArrangedSubview(uiCard([
            uiWrapLabel("아직 없습니다. 아래 「새 기기 추가」로 연결 코드를 만들어 "
                        + "두 번째 맥에 붙여넣으세요.",
                        width: uiCardInnerWidth(), size: 12),
        ]))
    }

    for peer in c.cfg.peers {
        let live = snapshot?.peers.first { $0.ip == peer.host }
        let online = live?.isOnline ?? false
        let name = live?.name ?? peer.host
        let state: String = {
            guard let l = live else { return "응답 없음 — 꺼져 있거나 방화벽에 막혔습니다" }
            return l.isOnline
                ? "\(l.lang == "ko" ? "한글" : "영문") · "
                  + String(format: "%.1f초 전", Double(l.agoMs) / 1000) + " · \(peer.host)"
                : "오프라인 · \(peer.host)"
        }()
        s.addArrangedSubview(uiRow(icon: online ? "checkmark.circle.fill" : "circle.dashed",
            title: name, detail: state,
            trailing: uiButton("삭제", owner: c) {
                guard c.confirm("\(name) 을(를) 목록에서 뺄까요?",
                                "이 기기와 더 이상 한/영을 맞추지 않습니다.\n"
                                + "상대 기기에서도 이 기기를 빼 주세요.",
                                okTitle: "삭제") else { return }
                let rest = c.cfg.peers.filter { $0.host != peer.host }.map(\.host)
                c.save { root in root["peers"] = rest }
            }, trailingWidth: 60))
    }

    if !c.cfg.peers.isEmpty {
        s.addArrangedSubview(uiRow(icon: "waveform.path.ecg", title: "연결 테스트",
            detail: "기기별 왕복 시간을 재서 방화벽·코드 불일치·주소 변경을 가려냅니다",
            trailing: uiButton("실행", owner: c) { runLinkTest(c) }, trailingWidth: 60))
    }

    s.addArrangedSubview(uiSection("기기 추가"))
    s.addArrangedSubview(uiRow(icon: "plus.circle", title: "새 기기 추가",
        detail: "이 맥에서 연결 코드를 만듭니다. 새 맥에 붙여넣으면 끝입니다.",
        trailing: uiButton("코드 만들기", owner: c) { showInviteSheet(c) }, trailingWidth: 100))
    s.addArrangedSubview(uiRow(icon: "arrow.down.circle", title: "기존 기기에 연결",
        detail: "다른 맥에서 만든 코드를 여기에 붙여넣습니다.",
        trailing: uiButton("코드 입력", owner: c) { showJoinSheet(c) }, trailingWidth: 100))

    // IP 직접 입력은 코드가 안 될 때의 뒷문이다 — 평소엔 눈에 덜 띄어야 한다.
    s.addArrangedSubview(uiSection("IP 로 직접 추가 (코드가 안 될 때)"))
    let ipField = NSTextField(string: "")
    ipField.placeholderString = "100.64.0.3"
    ipField.translatesAutoresizingMaskIntoConstraints = false
    ipField.widthAnchor.constraint(equalToConstant: 150).isActive = true
    s.addArrangedSubview(uiRow(icon: "number", title: "주소 직접 입력",
        detail: "이름이 아니라 숫자 IP 를 넣으세요",
        trailing: NSStackView(views: [ipField,
                                      uiButton("추가", owner: c) {
                                          addPeer(c, raw: ipField.stringValue)
                                      }]),
        trailingWidth: 210))

    return uiScrollPane(s)
}

// MARK: - 페어링 UI

/// 이 기기에서 초대 코드를 만들어 보여준다. 창이 떠 있는 동안만 상대의 연결을 받는다.
///
/// ⚠ **설정 창과 온보딩 창이 함께 쓴다.** 사용자에겐 "연결 코드를 만든다"는 **같은 한 순간**이라,
///   두 벌로 두면 문구·유효시간·pair-stop 처리가 조용히 어긋난다.
func presentInviteCode(cfg: Config, alert: (String, String) -> Void) {
    let candidates = rankLocalIPs(Array(localIPv4Addresses()))
    guard let ip = candidates.first else {
        alert("이 기기의 IP 를 찾지 못했습니다", "네트워크 연결을 확인하세요.")
        return
    }
    let secret = newPairingSecret()
    let code = makeInviteCode(ip: ip, port: cfg.port, secret: secret)

    guard DaemonClient.control(cfg, "ctl pair-start \(secret)", timeout: 2.0) == "ok" else {
        alert("연결 창을 열지 못했습니다", "데몬이 응답하지 않습니다.")
        return
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(code, forType: .string)

    let a = NSAlert()
    a.messageText = "새 기기에서 이 코드를 붙여넣으세요"
    a.informativeText = "\(code)\n\n"
        + "클립보드에 복사했습니다. 120초 동안 유효합니다.\n"
        + "새 기기의 설정 → 기기 → 「기존 기기에 연결…」 에 붙여넣으세요."
        + (candidates.count > 1
           ? "\n\n다른 주소: \(candidates.dropFirst().joined(separator: ", "))"
           : "")
    a.addButton(withTitle: "완료")
    a.runModal()

    // 창을 닫으면 즉시 무효 — 열어 둔 채 방치하지 않는다
    _ = DaemonClient.control(cfg, "ctl pair-stop", timeout: 2.0)
}

private func showInviteSheet(_ c: SettingsWindowController) {
    presentInviteCode(cfg: c.cfg) { c.alert($0, $1) }
    c.reloadFromDisk()
}

/// 받은 코드를 붙여넣어 기존 기기에 붙는다.
private func showJoinSheet(_ c: SettingsWindowController) {
    let a = NSAlert()
    a.messageText = "기존 기기에 연결"
    a.informativeText = "기존 기기에서 만든 연결 코드를 붙여넣으세요.\n예: mb1.100.64.0.3.8765.482917"
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
    if let s = NSPasteboard.general.string(forType: .string), parseInviteCode(s) != nil {
        field.stringValue = s.trimmingCharacters(in: .whitespacesAndNewlines)  // 클립보드에 있으면 미리 채운다
    }
    a.accessoryView = field
    a.addButton(withTitle: "연결")
    a.addButton(withTitle: "취소")
    guard a.runModal() == .alertFirstButtonReturn else { return }

    guard let code = parseInviteCode(field.stringValue) else {
        c.alert("연결 코드 형식이 아닙니다", "mb1. 로 시작하는 코드를 그대로 붙여넣으세요.")
        return
    }
    guard !localIPv4Addresses().contains(code.ip) else {
        c.alert("이 기기의 코드입니다", "다른 기기에서 만든 코드를 붙여넣으세요.")
        return
    }

    switch runPairing(with: code, cfg: c.cfg) {
    case .failure(let why):
        c.alert("연결하지 못했습니다", why)
    case .success(let count, let failed):
        if failed.isEmpty {
            c.alert("연결했습니다", "기기 \(count)대와 한/영을 맞춥니다.")
        } else {
            // 부분 실패를 감추지 않는다 — 어느 기기가 안 됐는지 그대로 알린다
            c.alert("일부만 연결됐습니다",
                    "기기 \(count)대 중 아래는 인사하지 못했습니다:\n"
                    + failed.joined(separator: "\n")
                    + "\n\n그 기기가 꺼져 있거나 방화벽에 막혔을 수 있습니다. "
                    + "나중에 「연결 테스트」로 확인하세요.")
        }
    }
    c.reloadFromDisk()
}

private func addPeer(_ c: SettingsWindowController, raw: String) {
    let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !v.isEmpty else { return }
    guard let peer = Peer.parse(v, defaultPort: c.cfg.port) else {
        c.alert("주소 형식이 올바르지 않습니다", "예: 100.64.0.3 또는 100.64.0.3:8765")
        return
    }
    guard ipv4ToUInt32(peer.host) != nil else {
        c.alert("IP 주소만 넣을 수 있습니다", "이름 대신 숫자 IP 를 넣어 주세요. 예: 100.64.0.3")
        return
    }
    guard !c.cfg.peers.contains(where: { $0.host == peer.host }) else {
        c.alert("이미 등록된 기기입니다", peer.host); return
    }
    guard !localIPv4Addresses().contains(peer.host) else {
        c.alert("이 기기의 주소입니다", "자기 자신은 추가할 수 없습니다."); return
    }
    let rest = c.cfg.peers.map(\.host) + [peer.host]
    c.save { root in root["peers"] = rest }
}

/// 피어별 `echo` 왕복. 메뉴바의 「연결 테스트」와 같은 경로다.
private func runLinkTest(_ c: SettingsWindowController) {
    let peers = c.cfg.peers
    guard !peers.isEmpty else { c.alert("연결 테스트", "등록된 기기가 없습니다."); return }
    DispatchQueue.global().async {
        let lines = peers.map { p -> String in
            if let ms = DaemonClient.echoRoundTrip(c.cfg, peer: p) {
                return "\(p.host)   \(ms)ms   ✅"
            }
            return "\(p.host)   응답 없음   ❌"
        }
        DispatchQueue.main.async {
            c.alert("연결 테스트", lines.joined(separator: "\n")
                    + "\n\n❌ 이면 방화벽·연결 코드 불일치·IP 변경·데몬 중지 중 하나입니다.")
        }
    }
}
