import Foundation

enum PairingVerdict: Equatable {
    case ok
    case wrongSecret
    case expired
    /// 아예 열려 있지 않다(평소 상태이거나, 시도 초과로 폐기됐거나, 사용자가 닫았다)
    case closed
}

/// 데몬이 갖는 페어링 창.
///
/// ⚠ **평소에는 닫혀 있다.** 사용자가 설정 창에서 「새 기기 추가」를 눌렀을 때만 열린다.
/// 6자리 시크릿은 그 자체로는 약하지만, **수동 개시 + 짧은 창 + 시도 제한 + 1회용**을 겹쳐 좁힌다.
final class PairingSession {
    static let attemptLimit = 5

    private var secret: String?
    private var expiresAtMs: Int64 = 0
    private var failures = 0
    private let queue = DispatchQueue(label: "macbridge.pairing")

    func open(secret: String, nowMs: Int64, windowMs: Int64 = 120_000) {
        queue.sync {
            self.secret = secret
            self.expiresAtMs = nowMs + windowMs
            self.failures = 0
        }
    }

    func close() {
        queue.sync { secret = nil; expiresAtMs = 0; failures = 0 }
    }

    func isOpen(nowMs: Int64) -> Bool {
        queue.sync { secret != nil && nowMs < expiresAtMs }
    }

    /// 남은 시간(초). 닫혀 있으면 0.
    func remainingSec(nowMs: Int64) -> Int {
        queue.sync {
            guard secret != nil, nowMs < expiresAtMs else { return 0 }
            return Int((expiresAtMs - nowMs + 999) / 1000)
        }
    }

    func verify(_ candidate: String, nowMs: Int64) -> PairingVerdict {
        queue.sync {
            guard let s = secret else { return .closed }
            guard nowMs < expiresAtMs else { return .expired }
            if candidate == s { return .ok }
            failures += 1
            if failures >= Self.attemptLimit {
                // 무차별 대입 차단 — 폐기하고 사용자가 다시 열게 한다
                secret = nil; expiresAtMs = 0
            }
            return .wrongSecret
        }
    }
}

/// 데몬 프로세스가 하나만 갖는다.
let globalPairing = PairingSession()
