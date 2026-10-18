import Foundation
import AppKit

func makeToolsPane(_ c: SettingsWindowController) -> NSView {
    let s = uiStack()

    let h = NSTextField(labelWithString: "이 앱으로 원격할 때만 한/영을 맞춥니다")
    h.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
    s.addArrangedSubview(h)
    s.addArrangedSubview(uiWrapLabel(
        "아무것도 고르지 않으면 항상 맞춥니다. 목록에 없는 도구는 맨 아래 「자동 감지」로 잡으세요.",
        width: uiContentWidth, size: 12))

    let rows = remoteToolRows(selected: c.cfg.onlyApps, installed: isAppInstalled)
    let verified = rows.filter { $0.verified }
    let others = rows.filter { !$0.verified }

    func add(_ row: RemoteToolRow) {
        // 미설치인데 고르지도 않았으면 켤 수 없다(있지도 않은 앱을 지정해 봐야 의미가 없다).
        let enabled = row.installed || row.checked
        var notes: [String] = []
        if !row.installed { notes.append("이 맥에 설치돼 있지 않습니다") }
        if row.custom { notes.append("직접 추가한 앱입니다") }
        if !row.verified && !row.custom { notes.append("원리상 동작하지만 아직 실측하지 않았습니다") }

        let sw = uiSwitch(on: row.checked, owner: c) { on in
            var next = c.cfg.onlyApps
            if on {
                if !next.contains(row.bundleId) { next.append(row.bundleId) }
            } else {
                next.removeAll { $0 == row.bundleId }
            }
            c.save { root in
                var ime = root["ime_sync"] as? [String: Any] ?? [:]
                ime["only_app"] = next
                root["ime_sync"] = ime
            }
        }
        (sw as? NSSwitch)?.isEnabled = enabled
        s.addArrangedSubview(uiRow(icon: row.installed ? "app.badge.checkmark" : "app.dashed",
                                   title: row.name,
                                   detail: notes.isEmpty ? row.bundleId
                                                         : notes.joined(separator: " · "),
                                   trailing: sw, trailingWidth: 44))
    }

    if !verified.isEmpty {
        s.addArrangedSubview(uiSection("실측으로 확인한 도구"))
        verified.forEach(add)
    }
    if !others.isEmpty {
        s.addArrangedSubview(uiSection("그 밖의 도구"))
        others.forEach(add)
    }

    s.addArrangedSubview(uiSection("목록에 없는 도구를 쓰신다면"))
    s.addArrangedSubview(uiRow(icon: "sparkle.magnifyingglass",
        title: "지금 쓰는 원격 앱 자동 감지",
        detail: "누른 뒤 5초 안에 원격 창을 최전면으로 가져오세요. 번들 ID 를 몰라도 됩니다.",
        trailing: uiButton("감지", owner: c) { startAutoDetect(c) },
        trailingWidth: 60))
    return uiScrollPane(s)
}

/// 5초 뒤 최전면 앱을 잡아 목록에 더한다.
///
/// ⚠ 설정 창이 최전면인 채로 끝나면 macbridge 자신이 잡힌다 — 그건 거부하고 이유를 알려 준다.
private func startAutoDetect(_ c: SettingsWindowController) {
    let panel = NSAlert()
    panel.messageText = "원격 창을 최전면으로 가져오세요"
    panel.informativeText = "5초 뒤에 맨 앞 앱을 원격 도구로 등록합니다."
    panel.addButton(withTitle: "취소")

    var remaining = 5
    let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { t in
        remaining -= 1
        if remaining <= 0 {
            t.invalidate()
            NSApp.abortModal()
        }
    }
    RunLoop.main.add(timer, forMode: .modalPanel)
    let response = panel.runModal()
    timer.invalidate()
    guard response != .alertFirstButtonReturn else { return }   // 취소

    guard let app = NSWorkspace.shared.frontmostApplication,
          let id = app.bundleIdentifier else {
        c.alert("앱을 잡지 못했습니다", "다시 시도해 주세요.")
        return
    }
    let mine = Bundle.main.bundleIdentifier ?? ""
    let excluded = [mine, "com.apple.finder", "com.apple.loginwindow"].filter { !$0.isEmpty }
    guard !excluded.contains(id),
          app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
        c.alert("원격 창이 최전면이 아니었습니다",
                "버튼을 누른 뒤 5초 안에 원격 창을 클릭해 맨 앞으로 가져오세요.")
        return
    }
    guard !c.cfg.onlyApps.contains(id) else {
        c.alert("이미 등록된 앱입니다", "\(app.localizedName ?? id)")
        return
    }
    if id == "com.google.Chrome" {
        guard c.confirm("Chrome 을 원격 도구로 등록할까요?",
                        "Chrome 원격 데스크톱은 브라우저 안에서 돌기 때문에, 등록하면 "
                        + "평소 웹서핑 중에도 한/영 동기화가 걸립니다.",
                        okTitle: "그래도 등록") else { return }
    }

    var next = c.cfg.onlyApps
    next.append(id)
    if c.save({ root in
        var ime = root["ime_sync"] as? [String: Any] ?? [:]
        ime["only_app"] = next
        root["ime_sync"] = ime
    }) {
        c.alert("등록했습니다", "\(app.localizedName ?? id)\n\(id)")
    }
}
