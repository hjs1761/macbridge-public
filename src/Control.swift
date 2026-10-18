import Foundation

/// 메뉴바 → 데몬 제어 명령.
///
/// ⚠ 이 명령들은 **루프백에서만** 받는다(`SyncServer.process` 가 검사). 토큰을 아는 것만으로
/// 원격에서 남의 기기 동기화를 끄거나 realign 을 쏘게 두면 안 되기 때문이다.
enum ControlCommand: Equatable {
    case realign
    case sync(Bool)
    case ping
    /// config 를 다시 읽어 런타임 필드를 갈아끼운다 (설정 창이 저장 직후 보낸다)
    case reload
    /// 페어링 창을 연다(설정 창이 시크릿을 만들어 넘긴다)
    case pairStart(String)
    case pairStop
    /// 「먼저 말 걸기」 응답 — 제안한 앱을 원격 도구 목록에 넣는다
    case addTool(String)
    /// 「먼저 말 걸기」 응답 — 이 앱은 원격 도구가 아니다. 다시 묻지 않는다
    case dismissTool(String)
}

/// `<token> ctl <명령> [인자]` 파싱. `ctl` 이 아니면 nil.
func parseControl(_ parts: [String]) -> ControlCommand? {
    guard parts.count >= 3, parts[1] == "ctl" else { return nil }
    switch parts[2] {
    case "realign": return .realign
    case "ping":    return .ping
    case "reload":  return .reload
    case "pair-start":
        guard parts.count >= 4 else { return nil }
        return .pairStart(parts[3])
    case "pair-stop": return .pairStop
    case "add-tool":
        guard parts.count >= 4, !parts[3].isEmpty else { return nil }
        return .addTool(parts[3])
    case "dismiss-tool":
        guard parts.count >= 4, !parts[3].isEmpty else { return nil }
        return .dismissTool(parts[3])
    case "sync":
        guard parts.count >= 4 else { return nil }
        switch parts[3] {
        case "on":  return .sync(true)
        case "off": return .sync(false)
        default:    return nil
        }
    default: return nil
    }
}
