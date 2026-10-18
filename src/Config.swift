import Foundation

// MARK: - 설정

/// 수신을 허용할 발신지 규칙.
/// 루프백은 규칙과 무관하게 항상 허용한다(자기 자신 테스트).
enum AllowRule {
    case tailscale                  // 100.64.0.0/10 (CGNAT)
    case lan                        // RFC1918 사설 대역
    case any                        // ⚠ 토큰만으로 방어 — 신뢰된 망에서만
    case cidr(net: UInt32, mask: UInt32)

    static func parse(_ s: String) -> AllowRule? {
        switch s.lowercased() {
        case "tailscale", "ts": return .tailscale
        case "lan", "private":  return .lan
        case "any", "*":        return .any
        default: break
        }
        // "10.0.0.0/8" 형태
        let parts = s.split(separator: "/")
        guard parts.count == 2,
              let bits = UInt8(parts[1]), bits <= 32,
              let net = ipv4ToUInt32(String(parts[0])) else { return nil }
        let mask: UInt32 = bits == 0 ? 0 : (~UInt32(0) << (32 - UInt32(bits)))
        return .cidr(net: net & mask, mask: mask)
    }

    func matches(_ ip: UInt32) -> Bool {
        switch self {
        case .any: return true
        case .tailscale:
            return (ip & 0xFFC0_0000) == 0x6440_0000        // 100.64.0.0/10
        case .lan:
            return (ip & 0xFF00_0000) == 0x0A00_0000        // 10.0.0.0/8
                || (ip & 0xFFF0_0000) == 0xAC10_0000        // 172.16.0.0/12
                || (ip & 0xFFFF_0000) == 0xC0A8_0000        // 192.168.0.0/16
        case .cidr(let net, let mask):
            return (ip & mask) == net
        }
    }

    var label: String {
        switch self {
        case .any: return "any"
        case .tailscale: return "tailscale(100.64/10)"
        case .lan: return "lan(RFC1918)"
        case .cidr(let net, let mask):
            return "\(uint32ToIPv4(net))/\(mask == 0 ? 0 : 32 - mask.trailingZeroBitCount)"
        }
    }
}

func ipv4ToUInt32(_ s: String) -> UInt32? {
    let o = s.split(separator: ".", omittingEmptySubsequences: false)
    guard o.count == 4 else { return nil }
    var v: UInt32 = 0
    for part in o {
        guard let b = UInt8(part) else { return nil }
        v = (v << 8) | UInt32(b)
    }
    return v
}

func uint32ToIPv4(_ v: UInt32) -> String {
    "\((v >> 24) & 0xFF).\((v >> 16) & 0xFF).\((v >> 8) & 0xFF).\(v & 0xFF)"
}

struct Peer: CustomStringConvertible {
    let host: String
    let port: UInt16
    var description: String { "\(host):\(port)" }

    /// "100.64.0.1" 또는 "100.64.0.1:8765"
    /// ⚠ IP 만 받는다. 이름 해석은 전송 경로에 지연을 얹으므로 넣지 않았다.
    static func parse(_ s: String, defaultPort: UInt16) -> Peer? {
        let comps = s.split(separator: ":")
        if comps.count == 1 { return Peer(host: String(comps[0]), port: defaultPort) }
        guard comps.count == 2, let p = UInt16(comps[1]) else { return nil }
        return Peer(host: String(comps[0]), port: p)
    }
}

enum Mode: String { case serve, watch, both }

struct Config {
    var mode: Mode = .both
    var port: UInt16 = 8765
    var token: String = ""
    var peers: [Peer] = []
    var allowFrom: [AllowRule] = [.tailscale, .lan]
    var imeSyncEnabled: Bool = true
    /// 이 앱들 중 하나가 최전면일 때만 송신한다. **빈 목록 = 제한 없음(항상 송신)**.
    /// Jump 뷰어 외의 원격 도구(화면 공유 등)를 함께 쓰려면 여기에 나열한다.
    var onlyApps: [String] = []
    /// 진단 출력용 표기
    var onlyAppLabel: String { onlyApps.isEmpty ? "(제한 없음)" : onlyApps.joined(separator: ", ") }
    /// 「먼저 말 걸기」에서 사용자가 "원격 도구 아님"이라 답한 앱들. 다시 묻지 않는다.
    var dismissedTools: [String] = []
    /// 첫 실행 온보딩 창을 이미 봤는가.
    var onboardingDone: Bool = false
    /// 복구 제스처(한/영 빠른 왕복)로 인정할 시간(ms). 전환 키마다 체감 속도가 달라 조절 여지를 둔다.
    var recoveryWindowMs: Int64 = defaultRecoveryGestureWindowMs
    /// 변화가 없어도 현재 언어를 되풀이해 알리는 주기(초). 0 이면 끔. **기본은 끔.**
    ///
    /// ⚠ 2026-08-06 실사용에서 **역효과가 확인돼 기본을 끔으로 되돌렸다.**
    ///   수신측의 `currentLanguage()` 가 stale 하게 읽히면 "다르다"고 판단해 **같은 값을 재적용**하는데,
    ///   `TISSelectInputSource` 재호출은 **조합 중인 한글을 리셋한다** → 주기마다 자소분리가 났다.
    ///   (자소분리를 고치려고 넣은 기능이 자소분리를 만들었다)
    ///   다시 켜려면 **"같은 값 재적용 금지" 가드가 선행되어야 한다** — 읽은 값에 기대지 말고
    ///   "마지막 적용 이후 이 기기에서 IME 변경 알림이 있었나"로 판정할 것. §Phase 1.5 참조.
    var heartbeatSec: Double = 0
    /// 자동정정 시 **포커스 바운스까지** 수행할지. 꼬인 입력 세션은 IME 정렬로는 안 풀리고
    /// 포커스 전환만이 푼다(2026-08-07 규명). 끄면 IME 정렬만 하고 세션 복구는 사용자 몫
    /// (캡스락 1초 내 두 번). 자동 바운스는 화면이 잠깐 깜빡이는 대가가 있다.
    var autoRecover: Bool = true
    /// 기기 고유 ID. `install.sh` 가 생성하며 불변. 없으면 nil 로 두고 경고만 남긴다
    /// (구버전 config 하위호환 — 그 기기는 상태를 알리지 않아 peers 목록에 안 뜬다).
    var deviceId: String? = nil
    /// 사람이 읽는 기기 이름. 기본값은 ComputerName.
    var deviceName: String = Host.current().localizedName ?? "unknown"
    /// 조합 문자열 → 액션 이름. 지금은 "realign" 하나만 지원한다.
    var hotkeys: [(combo: String, action: String)] = []

    var listens: Bool { mode == .serve || mode == .both }
    var watches: Bool { mode == .watch || mode == .both }
}

/// 파일에서 읽는 원본. 전 필드 옵셔널 — 빠진 키는 기본값으로 채운다.
/// (모르는 키는 Codable 이 알아서 무시하므로 앞으로 늘려도 하위호환이 깨지지 않는다)
private struct RawConfig: Decodable {
    struct RawImeSync: Decodable {
        var enabled: Bool?
        var only_app: OnlyAppValue?
        var heartbeat_sec: Double?
        var auto_recover: Bool?
        /// 「먼저 말 걸기」에서 사용자가 "원격 도구 아님"이라고 답한 앱들. 다시 묻지 않는다.
        var dismissed_tools: [String]?
        /// 복구 제스처(한/영 빠른 왕복)로 인정할 시간(ms).
        var recovery_window_ms: Int64?
    }
    struct RawDevice: Decodable {
        var id: String?
        var name: String?
    }
    struct RawHotkey: Decodable {
        var combo: String?
        var action: String?
    }
    /// 첫 실행 온보딩 창을 이미 봤는가. 한 번 닫으면 다시 띄우지 않는다.
    var onboarding_done: Bool?
    var mode: String?
    var port: UInt16?
    var token: String?
    var peers: [String]?
    var allow_from: [String]?
    var ime_sync: RawImeSync?
    var device: RawDevice?
    var hotkeys: [RawHotkey]?
}

enum ConfigError: Error, CustomStringConvertible {
    case unreadable(String, String)
    case invalid(String)
    var description: String {
        switch self {
        case .unreadable(let path, let why): return "설정 파일을 읽지 못했습니다 (\(path)): \(why)"
        case .invalid(let why):              return "설정이 올바르지 않습니다: \(why)"
        }
    }
}

let defaultConfigPath = NSString(string: "~/.config/macbridge/config.json").expandingTildeInPath
/// v0(ime-sync) 시절 토큰. 설정 파일에 token 이 없을 때만 참고한다.
let legacyTokenPaths = [
    NSString(string: "~/.config/macbridge/token").expandingTildeInPath,
    NSString(string: "~/.config/ime-sync/token").expandingTildeInPath,
]

func loadConfig(path: String) throws -> Config {
    guard let data = FileManager.default.contents(atPath: path) else {
        throw ConfigError.unreadable(path, "파일 없음")
    }
    let raw: RawConfig
    do {
        raw = try JSONDecoder().decode(RawConfig.self, from: data)
    } catch {
        throw ConfigError.unreadable(path, "\(error)")
    }

    var cfg = Config()

    if let m = raw.mode {
        guard let parsed = Mode(rawValue: m) else {
            throw ConfigError.invalid("mode 는 serve/watch/both 중 하나여야 합니다 (받은 값: \(m))")
        }
        cfg.mode = parsed
    }
    if let p = raw.port { cfg.port = p }
    if let t = raw.token { cfg.token = t }

    if let ps = raw.peers {
        cfg.peers = try ps.map {
            guard let peer = Peer.parse($0, defaultPort: cfg.port) else {
                throw ConfigError.invalid("peers 항목 형식 오류(IP 또는 IP:PORT): \($0)")
            }
            return peer
        }
    }
    if let af = raw.allow_from {
        cfg.allowFrom = try af.map {
            guard let rule = AllowRule.parse($0) else {
                throw ConfigError.invalid("allow_from 항목을 해석하지 못했습니다: \($0)")
            }
            return rule
        }
    }
    if let dev = raw.device {
        if let i = dev.id, !i.isEmpty { cfg.deviceId = i }
        if let n = dev.name, !n.isEmpty { cfg.deviceName = n }
    }
    if let hks = raw.hotkeys {
        cfg.hotkeys = try hks.map { h in
            guard let c = h.combo, let a = h.action, !c.isEmpty, !a.isEmpty else {
                throw ConfigError.invalid("hotkeys 항목에 combo/action 이 모두 있어야 합니다")
            }
            guard a == "realign" else {
                throw ConfigError.invalid("지원하지 않는 action: \(a) (현재 realign 만)")
            }
            guard parseHotkeyCombo(c) != nil else {
                throw ConfigError.invalid("핫키 조합을 해석하지 못했습니다: \(c)")
            }
            return (combo: c, action: a)
        }
    }
    if let ob = raw.onboarding_done { cfg.onboardingDone = ob }
    if let ime = raw.ime_sync {
        if let e = ime.enabled { cfg.imeSyncEnabled = e }
        // 빈 문자열/빈 배열은 "제한 없음"으로 본다 (install.sh 가 빈 값을 쓸 수 있어서)
        if ime.only_app != nil { cfg.onlyApps = parseOnlyApps(ime.only_app) }
        if let ar = ime.auto_recover { cfg.autoRecover = ar }
        if let dt = ime.dismissed_tools { cfg.dismissedTools = dt }
        if let rw = ime.recovery_window_ms {
            guard rw >= 200, rw <= 10_000 else {
                throw ConfigError.invalid(
                    "ime_sync.recovery_window_ms 는 200~10000 이어야 합니다 (받은 값: \(rw))")
            }
            cfg.recoveryWindowMs = rw
        }
        if let h = ime.heartbeat_sec {
            guard h == 0 || h >= 0.2 else {
                throw ConfigError.invalid("ime_sync.heartbeat_sec 은 0(끔) 또는 0.2 이상이어야 합니다 (받은 값: \(h))")
            }
            cfg.heartbeatSec = h
        }
    }
    return cfg
}

func readLegacyToken() -> String? {
    for p in legacyTokenPaths {
        if let s = try? String(contentsOfFile: p, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
    }
    return nil
}

/// 설정 파일 → CLI 인자 순으로 채운다. CLI 인자는 언제나 파일을 덮어쓴다(디버깅용).
func resolveConfig() -> Config {
    var cfg = Config()
    let explicitPath = argValue("--config")
    let path = explicitPath ?? defaultConfigPath

    do {
        cfg = try loadConfig(path: path)
        log("설정 로드: \(path)")
    } catch {
        // --config 로 명시한 경로가 잘못됐다면 조용히 넘어가면 안 된다
        if explicitPath != nil {
            log("!! \(error)")
            exit(1)
        }
        log("설정 파일 없음(\(path)) — CLI 인자로 동작합니다")
    }

    // --- CLI 오버라이드 ---
    if let m = CommandLine.arguments.dropFirst().first,
       !m.hasPrefix("-"), let parsed = Mode(rawValue: m) {
        cfg.mode = parsed
    }
    if let ps = argValue("--port"), let p = UInt16(ps) { cfg.port = p }
    if let t = argValue("--token") { cfg.token = t }
    if let a = argValue("--only-app") { cfg.onlyApps = a.isEmpty ? [] : [a] }
    // --peer 는 여러 번 줄 수 있다
    let cliPeers = argValues("--peer").compactMap { Peer.parse($0, defaultPort: cfg.port) }
    if !cliPeers.isEmpty { cfg.peers = cliPeers }

    if cfg.token.isEmpty, let t = readLegacyToken() {
        cfg.token = t
        log("토큰: 기존 token 파일에서 읽음")
    }

    // --- 검증 ---
    if cfg.token.isEmpty {
        log("!! token 이 없습니다. config.json 의 token 또는 --token 을 지정하세요")
        exit(1)
    }
    // ⚠ peers 가 비어도 **죽지 않는다.** 갓 설치한 기기는 아직 상대를 모르고,
    //   바로 그 상태에서 페어링으로 채워 넣어야 하기 때문이다.
    //   (한때 여기서 exit(1) 했더니 새 기기가 데몬을 못 띄워 페어링 자체가 막혔다)
    if cfg.watches && cfg.peers.isEmpty {
        log("연결된 기기가 없습니다 — 설정 → 기기 → 「기존 기기에 연결…」 로 붙이세요")
    }
    if cfg.deviceId == nil {
        log("!! device.id 가 없습니다 — 이 기기는 상태를 알리지 않아 상대의 peers 목록에 나타나지 않습니다."
            + " install.sh 를 다시 실행하면 생성됩니다")
    }
    if cfg.allowFrom.isEmpty {
        log("!! allow_from 이 비어 있으면 아무것도 수신할 수 없습니다")
        exit(1)
    }
    return cfg
}

/// `only_app` 은 문자열 하나 또는 문자열 배열 둘 다 받는다(기존 config 하위호환).
enum OnlyAppValue: Decodable, Equatable {
    case string(String)
    case array([String])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s); return }
        self = .array(try c.decode([String].self))
    }
}

/// 빈 값은 걸러내고 목록으로 정규화한다. 빈 목록 = 제한 없음.
func parseOnlyApps(_ v: OnlyAppValue?) -> [String] {
    switch v {
    case .none: return []
    case .string(let s): return s.isEmpty ? [] : [s]
    case .array(let a): return a.filter { !$0.isEmpty }
    }
}

/// `ime_sync.enabled` 영속화. 구현은 `ConfigWriter` 에 있다.
func persistSyncEnabled(_ on: Bool) -> String? { updateImeSyncKey("enabled", on) }

/// 원격 도구 목록 영속화 (「먼저 말 걸기」의 [추가]).
func persistOnlyApps(_ apps: [String]) -> String? { updateImeSyncKey("only_app", apps) }

/// 「원격 도구 아님」 목록 영속화 — 이 앱들은 다시 묻지 않는다.
func persistDismissedTools(_ apps: [String]) -> String? { updateImeSyncKey("dismissed_tools", apps) }

/// 온보딩 창을 봤다고 기록. 연결이 끝났든 아니든 **닫으면** 기록한다 —
/// 계속 조르는 역할은 메뉴바가 맡는다.
func markOnboardingDone() -> String? {
    updateConfigFile { root in root["onboarding_done"] = true }
}
