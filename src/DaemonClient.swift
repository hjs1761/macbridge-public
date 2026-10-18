import Foundation

/// 메뉴바 프로세스가 로컬 데몬과 대화하는 통로.
///
/// 데몬과 메뉴바는 별개 프로세스다(UI 크래시가 IME 동기화를 죽이지 않도록).
/// 읽기는 기존 `query`, 조작은 `ctl`(루프백 전용), 피어 도달성은 `echo` 왕복을 쓴다.
enum DaemonClient {

    /// `ctl` 명령을 보내고 한 줄 응답을 받는다. 데몬 무응답이면 nil.
    static func control(_ cfg: Config, _ command: String, timeout: Double = 1.0) -> String? {
        sendAndReceive("\(cfg.token) \(command)", to: "127.0.0.1",
                       port: cfg.port, timeout: timeout)
    }

    /// 피어 한 대에 `echo` 를 보내고 왕복 시간(ms)을 잰다. 응답이 없으면 nil.
    static func echoRoundTrip(_ cfg: Config, peer: Peer, timeout: Double = 1.5) -> Int64? {
        let sent = nowMs()
        let reply = sendAndReceive("\(cfg.token) echo \(sent)",
                                   to: peer.host, port: peer.port, timeout: timeout)
        guard let r = reply, r.hasPrefix("\(cfg.token) echoed ") else { return nil }
        return nowMs() - sent
    }

    /// UDP 한 번 보내고 한 줄 받는다. 응답 없으면 nil.
    private static func sendAndReceive(_ message: String,
                                       to host: String, port: UInt16,
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
}
