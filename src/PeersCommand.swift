import Foundation
import AppKit

/// 로컬 데몬에게 UDP `query` 로 물어 피어 현황을 출력한다.
///
/// (계획서 초안은 "CLI 가 임시 포트로 6초간 keepalive 를 직접 듣는" 방식이었지만,
///  keepalive 는 데몬 포트로만 오므로 임시 포트에는 아무것도 도착하지 않는다.
///  query 응답 방식이라 대기 없이 즉답한다.)
func runPeersCommand(_ cfg: Config) -> Never {
    guard let r = queryDaemon(cfg) else {
        log("데몬 응답 없음 — macbridge 데몬이 떠 있는지 확인하세요 (launchctl list | grep macbridge)")
        exit(1)
    }

    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    let myRole: String = {
        guard !cfg.onlyApps.isEmpty else { return "—" }
        guard let f = front else { return "호스트" }
        return cfg.onlyApps.contains(f) ? "클라 · 뷰어 최전면" : "호스트"
    }()

    print("")
    print("   이름            IME  마지막통신  역할")
    print(" ● \(pad(cfg.deviceName, 14)) \(pad(r.myLang, 4)) \(pad("(나)", 10)) \(myRole)")
    for p in r.peers {
        let mark = p.isOnline ? "●" : "○"
        let ago = p.isOnline ? String(format: "%.1f초 전", Double(p.agoMs) / 1000) : "오프라인"
        let warn = (p.isOnline && p.lang != r.myLang) ? "  ⚠ 불일치" : ""
        print(" \(mark) \(pad(p.name, 14)) \(pad(p.lang, 4)) \(pad(ago, 10)) \(p.ip)\(warn)")
    }
    print("")
    exit(0)
}

/// 한글은 폭이 2 라서 단순 count 로는 칸이 안 맞는다. 대략적으로 보정한다.
private func pad(_ s: String, _ width: Int) -> String {
    let w = s.reduce(0) { $0 + ($1.unicodeScalars.first!.value > 0x1100 ? 2 : 1) }
    return s + String(repeating: " ", count: max(0, width - w))
}
