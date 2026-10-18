import Foundation

/// keepalive 주기의 3배가 지나면 오프라인으로 본다.
let peerOfflineAfterMs: Int64 = 15_000

struct PeerState {
    let deviceId: String
    var name: String
    var lang: String
    var lastSeenMs: Int64
    var ip: String
    /// snapshot(nowMs:) 이 계산해 채운다
    var isOnline: Bool = true
}

/// 상대들이 알려 온 상태를 모아 둔다. **여기에 담긴 값으로 남의 IME 를 바꾸지 않는다.**
final class PeerTable {
    private var byId: [String: PeerState] = [:]
    private let queue = DispatchQueue(label: "macbridge.peertable")

    /// - Returns: 이번 보고로 이 피어의 언어가 **바뀌었는가**(전이인가).
    ///   처음 보는 피어는 전이가 아니다 — 기동 직후 남을 따라가 버리면 안 되기 때문.
    ///   "상대가 혼자 바꿨으니 따라간다" 판정(`shouldFollowPeer`)의 핵심 입력이다.
    @discardableResult
    func update(_ m: StateMessage, ip: String, nowMs t: Int64) -> Bool {
        queue.sync {
            let prev = byId[m.deviceId]?.lang
            byId[m.deviceId] = PeerState(deviceId: m.deviceId, name: m.name,
                                         lang: m.lang, lastSeenMs: t, ip: ip)
            return prev != nil && prev != m.lang
        }
    }

    /// 마지막 통신 시각 기준으로 온라인 여부를 채워 돌려준다. 이름순 정렬.
    func snapshot(nowMs t: Int64) -> [PeerState] {
        queue.sync {
            byId.values.map { p in
                var q = p
                q.isOnline = (t - p.lastSeenMs) < peerOfflineAfterMs
                return q
            }.sorted { $0.name < $1.name }
        }
    }

    /// 나와 언어가 다른 **온라인** 피어들
    func mismatched(myLang: String, nowMs t: Int64) -> [PeerState] {
        snapshot(nowMs: t).filter { $0.isOnline && $0.lang != myLang }
    }
}
