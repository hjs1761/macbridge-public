import Foundation

// MARK: - 데몬 질의 (CLI/probe → 데몬)
//
// 상대들의 keepalive 는 **데몬 포트로만** 오므로, 별개 프로세스가 임시 포트로 듣는 것으로는
// 아무것도 받을 수 없다. 대신 로컬 데몬에게 UDP `query` 를 보내고 응답 한 패킷을 받는다.
// (데몬 메모리를 읽는 유일한 통로 — 본격 IPC 는 Phase 3 메뉴바 앱에서 함께 설계한다)

/// 데몬 query 응답의 한 줄 (`peer <id> <agoMs> <lang> <ip> <name...>`)
struct QueriedPeer {
    let deviceId: String
    let agoMs: Int64
    let lang: String
    let ip: String
    let name: String
    var isOnline: Bool { agoMs < peerOfflineAfterMs }
}

struct QueryResult {
    let myLang: String
    let peers: [QueriedPeer]
    /// 「먼저 말 걸기」 — 원격 도구로 의심되는데 목록에 없는 앱의 번들 ID.
    let suggestedTool: String?
}

/// query 응답 텍스트 파서. **순수 함수라 회귀 테스트가 붙는다** — 프로토콜을 늘릴 때
/// 옛 필드가 조용히 깨지는 걸 여기서 잡는다.
func parseQueryResponse(_ text: String) -> QueryResult {
    var myLang = "?"
    var peers: [QueriedPeer] = []
    var suggested: String?
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: " ").map(String.init)
        if parts.count == 2, parts[0] == "me" { myLang = parts[1]; continue }
        if parts.count == 2, parts[0] == "suggest" { suggested = parts[1]; continue }
        // peer <id> <agoMs> <lang> <ip> <name...> — 이름은 공백 포함 가능이라 맨 뒤에 둔다
        guard parts.count >= 6, parts[0] == "peer", let ago = Int64(parts[2]) else { continue }
        peers.append(QueriedPeer(deviceId: parts[1], agoMs: ago, lang: parts[3],
                                 ip: parts[4], name: parts[5...].joined(separator: " ")))
    }
    return QueryResult(myLang: myLang, peers: peers, suggestedTool: suggested)
}

/// 로컬 데몬(127.0.0.1:port)에 `query` 를 보내 피어 현황을 받아온다.
/// 데몬이 없거나 시간 내 응답이 없으면 nil.
func queryDaemon(_ cfg: Config, timeout: Double = 1.0) -> QueryResult? {
    let sock = socket(AF_INET, SOCK_DGRAM, 0)
    guard sock >= 0 else { return nil }
    defer { close(sock) }
    var tv = timeval(tv_sec: Int(timeout),
                     tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = cfg.port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let msg = Array("\(cfg.token) query\n".utf8)
    let sent = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            sendto(sock, msg, msg.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard sent > 0 else { return nil }

    var buf = [UInt8](repeating: 0, count: 4096)
    let n = recv(sock, &buf, buf.count, 0)
    guard n > 0, let text = String(bytes: buf[0..<n], encoding: .utf8) else { return nil }

    let r = parseQueryResponse(text)
    return r
}
