import Foundation
import Security

/// 초대 코드가 담고 있는 것.
struct InviteCode: Equatable {
    let ip: String
    let port: UInt16
    let secret: String
}

let invitePrefix = "mb1"

/// `mb1.<ip>.<port>.<6자리>` — 한 줄이라 클립보드로 옮기기 쉽다.
///
/// ⚠ **포트를 반드시 담는다.** 없으면 받는 쪽이 *자기* 포트로 상대에게 보내게 되고,
/// 둘의 포트가 다르면 엉뚱한 데로 가서 "창이 안 열렸다"는 오해를 부른다(실측으로 밟았다).
func makeInviteCode(ip: String, port: UInt16, secret: String) -> String {
    "\(invitePrefix).\(ip).\(port).\(secret)"
}

/// 붙여넣은 문자열에서 IP·시크릿을 꺼낸다. 형식이 조금이라도 다르면 nil.
///
/// IP 안에 점이 들어 있으므로 토막 수(접두사 1 + IP 4 + 포트 1 + 시크릿 1 = 7)로 판정한다.
func parseInviteCode(_ raw: String) -> InviteCode? {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = s.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 7, parts[0] == invitePrefix else { return nil }
    let secret = parts[6]
    guard secret.count == 6, secret.allSatisfy(\.isNumber) else { return nil }
    guard let port = UInt16(parts[5]), port > 0 else { return nil }
    let ip = parts[1...4].joined(separator: ".")
    guard ipv4ToUInt32(ip) != nil else { return nil }
    return InviteCode(ip: ip, port: port, secret: secret)
}

/// 6자리 숫자 시크릿. **암호학적 난수**로 만든다 — 추측 가능한 난수를 쓰면 시도 제한이 무의미해진다.
func newPairingSecret() -> String {
    var bytes = [UInt8](repeating: 0, count: 4)
    if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
        // 실패해도 페어링을 막지는 않는다. 대신 시스템 난수로 대체한다.
        bytes = (0..<4).map { _ in UInt8.random(in: 0...255) }
    }
    let v = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
    return String(format: "%06u", v)
}

/// 상대가 나에게 도달할 수 있을 법한 순서로 내 IPv4 를 정렬한다.
///
/// `allow_from` 기본값이 tailscale·lan 이므로 그 순서가 곧 도달 가능성 순서다.
/// ① Tailscale(100.64/10) → ② RFC1918 사설 → ③ 나머지. 루프백은 뺀다.
func rankLocalIPs(_ addresses: [String]) -> [String] {
    func rank(_ ip: String) -> Int {
        guard let v = ipv4ToUInt32(ip) else { return 9 }
        if AllowRule.tailscale.matches(v) { return 0 }
        if AllowRule.lan.matches(v) { return 1 }
        return 2
    }
    return addresses
        .filter { !$0.hasPrefix("127.") && ipv4ToUInt32($0) != nil }
        .sorted { (rank($0), $0) < (rank($1), $1) }
}

/// 이 기기가 가진 IPv4 주소들.
///
/// 설정 UI 뿐 아니라 **데몬도 쓴다**(페어링 응답에 내 주소를 실어야 한다).
func localIPv4Addresses() -> Set<String> {
    var result = Set<String>()
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return result }
    defer { freeifaddrs(ifaddr) }
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        guard let addr = ptr.pointee.ifa_addr,
              addr.pointee.sa_family == UInt8(AF_INET) else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                       nil, 0, NI_NUMERICHOST) == 0 {
            result.insert(String(cString: host))
        }
    }
    return result
}

/// 초대 코드에 넣을 내 IP. 우선순위 첫 번째를 고른다.
func bestLocalIPForPairing() -> String {
    rankLocalIPs(Array(localIPv4Addresses())).first ?? ""
}
