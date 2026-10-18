import Foundation
import AppKit

enum PairingOutcome {
    case success(peerCount: Int, failed: [String])
    case failure(String)
}

/// 초대 코드로 기존 기기에 붙는다.
///
/// 1. `<시크릿> pair <내id> <내이름>` 을 상대에게 보낸다
/// 2. `paired <token> <peer…>` 를 받으면 config 에 토큰·피어를 쓰고 `ctl reload`
/// 3. 받은 목록의 **나머지 기기들에게 내가 직접** `addpeer` 로 인사한다
///    (상대가 전파하는 대신 내가 주도한다 — 경로가 하나라 부분 실패를 추적하기 쉽다)
func runPairing(with code: InviteCode, cfg: Config) -> PairingOutcome {
    let myId = cfg.deviceId ?? "unknown"
    let request = "\(code.secret) pair \(myId) \(cfg.deviceName)"
    // ⚠ **상대의 포트**(코드에 담겨 온 것)로 보낸다. 내 포트로 보내면 포트가 다를 때
    //   엉뚱한 데로 가서 "창이 안 열렸다"는 오해를 부른다(실측으로 밟았다).
    guard let reply = pairingRoundTrip(request, to: code.ip, port: code.port, timeout: 3.0) else {
        return .failure("상대 기기가 응답하지 않습니다.\n"
                        + "IP 가 맞는지, 상대 기기에서 「새 기기 추가」 창이 열려 있는지 확인하세요.")
    }
    let f = reply.split(separator: " ").map(String.init)
    if f.first == "pair-err" {
        switch f.count >= 2 ? f[1] : "" {
        case "closed":     return .failure("상대 기기의 연결 창이 열려 있지 않습니다.\n상대 기기에서 「새 기기 추가」를 먼저 누르세요.")
        case "expired":    return .failure("연결 코드의 유효 시간이 지났습니다.\n상대 기기에서 코드를 다시 만드세요.")
        case "wrong-code": return .failure("연결 코드가 맞지 않습니다.\n코드를 다시 복사해 붙여넣으세요.")
        default:           return .failure("연결이 거부됐습니다: \(reply)")
        }
    }
    guard f.first == "paired", f.count >= 2 else {
        return .failure("알 수 없는 응답입니다: \(reply)")
    }

    let token = f[1]
    let peers = Array(f.dropFirst(2))
    guard !peers.isEmpty else { return .failure("상대가 보낸 기기 목록이 비어 있습니다.") }

    if let err = updateConfigFile({ root in
        root["token"] = token
        root["peers"] = peers
    }) {
        return .failure("설정을 저장하지 못했습니다: \(err)")
    }
    // ⚠ **reload 는 아직 옛 토큰으로 보내야 한다.** 파일에는 새 토큰을 썼지만 데몬은
    //   아직 옛 토큰을 들고 있어서, 새 토큰으로 ctl 을 보내면 "토큰 불일치"로 거부된다.
    //   reload 가 끝난 뒤부터 데몬이 새 토큰을 쓴다.
    _ = DaemonClient.control(cfg, "ctl reload", timeout: 2.0)
    var updated = cfg
    updated.token = token

    // 나머지 기기들에게 인사 — 첫 번째(code.ip)는 이미 나를 안다.
    // 목록 항목은 "IP" 또는 "IP:PORT" 라 `Peer.parse` 로 포트를 꺼낸다.
    var failed: [String] = []
    for entry in peers {
        guard let p = Peer.parse(entry, defaultPort: code.port), p.host != code.ip else { continue }
        let msg = "\(token) addpeer \(myId) \(updated.deviceName)"
        if pairingRoundTrip(msg, to: p.host, port: p.port, timeout: 2.0) != "addpeer-ok" {
            failed.append(p.host)
        }
    }
    return .success(peerCount: peers.count, failed: failed)
}

/// 한 줄 보내고 한 줄 받는다. `DaemonClient` 와 달리 **임의의 상대**에게 보낸다.
func pairingRoundTrip(_ message: String, to host: String, port: UInt16,
                      timeout: Double) -> String? {
    let sock = socket(AF_INET, SOCK_DGRAM, 0)
    guard sock >= 0 else { return nil }
    defer { close(sock) }
    var tv = timeval(tv_sec: Int(timeout),
                     tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr(host)
    guard addr.sin_addr.s_addr != INADDR_NONE else { return nil }

    let bytes = Array((message + "\n").utf8)
    let sent = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            sendto(sock, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard sent > 0 else { return nil }

    var buf = [UInt8](repeating: 0, count: 2048)
    let n = recv(sock, &buf, buf.count, 0)
    guard n > 0 else { return nil }
    return String(bytes: buf[0..<n], encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
