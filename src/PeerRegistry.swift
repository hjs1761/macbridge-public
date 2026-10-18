import Foundation

/// 송신 대상 피어 목록. **런타임에 늘어날 수 있으므로** 전용 큐로 감싼다.
///
/// 기존에는 `SyncWatcher` 가 `init` 에서 `[Peer]` 를 캡처해 두었는데, 그러면 `addpeer`(3-B)로
/// 새 기기가 붙어도 데몬을 재시작해야만 반영된다. 송신 루프가 이 목록을 순회하는 동안
/// 다른 스레드가 추가할 수 있으므로 그냥 `var` 로 바꾸면 경합이 생긴다.
final class PeerRegistry {
    private var peers: [Peer]
    private let queue = DispatchQueue(label: "macbridge.peerregistry")

    init(_ initial: [Peer]) { self.peers = initial }

    /// 순회용 스냅샷. 반환값은 복사본이라 순회 중 추가돼도 안전하다.
    func all() -> [Peer] { queue.sync { peers } }

    /// 이미 같은 host 가 있으면 추가하지 않는다.
    /// - Returns: 실제로 추가됐으면 `true`
    @discardableResult
    func add(_ p: Peer) -> Bool {
        queue.sync {
            guard !peers.contains(where: { $0.host == p.host }) else { return false }
            peers.append(p)
            return true
        }
    }

    /// - Returns: 실제로 지웠으면 `true`
    @discardableResult
    func remove(_ host: String) -> Bool {
        queue.sync {
            let before = peers.count
            peers.removeAll { $0.host == host }
            return peers.count != before
        }
    }

    /// `ctl reload` 가 config 의 peers 로 통째 갈아끼울 때 쓴다.
    func replaceAll(_ newPeers: [Peer]) { queue.sync { peers = newPeers } }

    func find(_ host: String) -> Peer? { queue.sync { peers.first { $0.host == host } } }
    var count: Int { queue.sync { peers.count } }
}
