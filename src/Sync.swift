import Foundation
import Carbon
import AppKit

// MARK: - 서버 (수신측)

/// UDP 로 받는다. TCP 는 데이터 한 줄 보내려고 3-way 핸드셰이크를 먼저 하는데,
/// 그 왕복이 곧 "Caps Lock 누르자마자 친 키가 깨지는" 경합 창이 된다.
/// UDP 는 연결 수립이 없어 그 구간이 통째로 사라진다.
/// 유실 대비는 송신측의 3회 중복 전송으로 한다(같은 값이면 수신측이 무시).
final class SyncServer {
    private let port: UInt16
    /// ⚠ `ctl reload` 가 런타임에 갈아끼운다. 수신 스레드가 읽는 값이라 큐로 감싼다.
    private var tokenStorage: String
    private var allowFromStorage: [AllowRule]
    private let settingsQueue = DispatchQueue(label: "macbridge.server.settings")
    var token: String {
        get { settingsQueue.sync { tokenStorage } }
        set { settingsQueue.sync { tokenStorage = newValue } }
    }
    var allowFrom: [AllowRule] {
        get { settingsQueue.sync { allowFromStorage } }
        set { settingsQueue.sync { allowFromStorage = newValue } }
    }
    /// 런타임에 메뉴바가 끄고 켤 수 있다 — 수신 스레드와 main 큐가 동시에 만지므로 큐로 감싼다.
    private var imeEnabledStorage: Bool
    private let imeEnabledQueue = DispatchQueue(label: "macbridge.imeenabled")
    var imeEnabled: Bool {
        get { imeEnabledQueue.sync { imeEnabledStorage } }
        set { imeEnabledQueue.sync { imeEnabledStorage = newValue } }
    }
    private var fd: Int32 = -1
    private var lastForceTs: Int64 = 0
    private var lastRecoverTs: Int64 = 0

    init(config: Config) {
        self.port = config.port
        self.tokenStorage = config.token
        self.allowFromStorage = config.allowFrom
        self.imeEnabledStorage = config.imeSyncEnabled
    }

    func start() throws {
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "macbridge", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "소켓 생성 실패"])
        }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw NSError(domain: "macbridge", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "포트 \(port) bind 실패 (이미 사용 중?)"])
        }

        Thread.detachNewThread { [weak self] in self?.receiveLoop() }
        log("수신 대기 시작(UDP) — 포트 \(port) · 허용 발신지 \(allowFrom.map(\.label).joined(separator: ", "))")
    }

    /// 루프백은 항상 허용, 그 외에는 allow_from 규칙 중 하나라도 맞아야 한다
    private func isAllowed(_ ip: String) -> Bool {
        if ip.hasPrefix("127.") { return true }
        guard let v = ipv4ToUInt32(ip) else { return false }
        return allowFrom.contains { $0.matches(v) }
    }

    private func receiveLoop() {
        var buf = [UInt8](repeating: 0, count: 512)
        while true {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { fp in
                fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(fd, &buf, buf.count, 0, sa, &fromLen)
                }
            }
            guard n > 0 else { continue }

            let ip = String(cString: inet_ntoa(from.sin_addr))
            guard isAllowed(ip) else { log("거부된 발신지: \(ip)"); continue }
            guard let line = String(bytes: buf[0..<n], encoding: .utf8) else { continue }
            process(line.trimmingCharacters(in: .whitespacesAndNewlines), from: ip, addr: from)
        }
    }

    /// 프로토콜: "<token> <lang> [송신시각ms]"  예) "abc123 ko 1785916234567"
    /// (Phase 2 에서 "<token> act <이름> <ts>" 를 더한다 — 그때도 이 형식은 그대로 둔다)
    private func process(_ line: String, from ip: String, addr: sockaddr_in) {
        let recvMs = nowMs()
        let parts = line.split(separator: " ").map(String.init)
        // 🔴 받은 줄을 그대로 찍으면 **맨 앞의 토큰이 로그에 평문으로 남는다**(2026-08-09 발견).
        //    로그는 남에게 보낼 수도 있고(문의 첨부) 백업·동기화로도 새어 나간다. 형태만 남긴다.
        guard parts.count >= 2 else { log("잘못된 형식: \(redactMessage(line)) (\(ip))"); return }
        // ⚠ 페어링 요청만은 **토큰 검사 앞**에 온다 — 새 기기는 아직 토큰이 없다.
        //   대신 **시크릿이 토큰 자리를 대신**하고, 페어링 창이 열려 있을 때만 처리된다.
        //   (allow_from 은 이미 receiveLoop 에서 통과했다)
        if parts.count >= 4, parts[1] == "pair" {
            handlePair(parts, from: ip, addr: addr)
            return
        }

        guard parts[0] == token else { log("토큰 불일치 — 무시 (\(ip))"); return }

        // 상태 알림 — 기록만 하고 **절대 적용하지 않는다**.
        // 이 경로에서 TISSelectInputSource 를 부르지 않으므로 조합이 깨질 수 없다
        // (하트비트를 롤백하게 만든 "같은 값 재적용 → 조합 리셋" 실패 모드가 구조적으로 없다).
        if parts[1] == "state" {
            guard let m = parseStateMessage(parts) else {
                log("state 형식 오류 — 무시 (\(ip))"); return
            }
            let peerChanged = globalPeers.update(m, ip: ip, nowMs: recvMs)
            // 자동정정 판단은 감시자 몫 (드라이빙 기기만 정정 권한을 갖는다)
            DispatchQueue.main.async {
                globalWatcher?.noteState(lang: m.lang, from: ip, justChanged: peerChanged)
            }
            return
        }

        // 피어 현황 질의 — 별개 프로세스(CLI `peers`·`probe`)가 데몬의 피어 테이블을 읽는 통로.
        // 상대들의 keepalive 는 이 소켓(데몬 포트)으로만 오므로 CLI 가 직접 들을 수 없다.
        // 요청과 같은 인증(토큰 + allow_from)을 통과한 발신 주소로 한 패킷을 되돌려 준다.
        if parts[1] == "query" {
            let fd = self.fd
            DispatchQueue.main.async {   // currentLanguage() 는 main 에서 읽는다 (TIS 신선도)
                let t = nowMs()
                var lines = ["me \(currentLanguage() ?? "?")"]
                for p in globalPeers.snapshot(nowMs: t) {
                    lines.append("peer \(p.deviceId) \(t - p.lastSeenMs) \(p.lang) \(p.ip) \(p.name)")
                }
                // 「먼저 말 걸기」 — 메뉴바가 이 줄을 보고 사용자에게 묻는다
                if let hint = globalWatcher?.toolHintCandidate { lines.append("suggest \(hint)") }
                let bytes = Array((lines.joined(separator: "\n") + "\n").utf8)
                var to = addr
                _ = withUnsafePointer(to: &to) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            return
        }

        // 도달성 확인 — 읽기 전용 왕복. allow_from 을 그대로 따른다.
        if parts[1] == "echo" {
            guard parts.count >= 3 else { return }
            let bytes = Array("\(token) echoed \(parts[2])\n".utf8)
            var to = addr
            let fd = self.fd
            _ = withUnsafePointer(to: &to) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            return
        }
        // 상대의 echo 응답은 데몬에선 쓸 일이 없다(메뉴바가 자기 소켓으로 받는다) — 조용히 버린다
        if parts[1] == "echoed" { return }

        // 제어 명령 — 🔒 **루프백에서만** 받는다.
        if parts[1] == "ctl" {
            guard ip.hasPrefix("127.") else {
                log("!! ctl 거부 — 루프백이 아닌 \(ip) 에서 옴 (제어는 로컬 전용)")
                return
            }
            guard let cmd = parseControl(parts) else {
                log("ctl 형식 오류 — 무시: \(redactMessage(line))")
                replyCtl("err bad-command", to: addr)
                return
            }
            handleControl(cmd, replyTo: addr)
            return
        }

        // 새로 붙은 기기가 자기를 알려 온다. 토큰 인증을 이미 통과했다.
        // ⚠ 추가하는 주소는 **요청의 발신 IP** 다 — 요청자가 임의 IP 를 넣지 못한다.
        if parts[1] == "addpeer" {
            let name = parts.count >= 4 ? parts[3...].joined(separator: " ") : ip
            let added = globalWatcher?.addPeerHost(ip, port: port) ?? false
            _ = persistPeerAdd(ip)   // serve 모드여도 파일에는 남긴다
            log("새 기기 등록 — \(name) (\(ip))"
                + (added ? "" : " (런타임 추가 생략 — 이미 있거나 serve 모드)"))
            replyCtl("addpeer-ok", to: addr)
            return
        }

        // 강제 정렬 — "이미 같으면 skip" 과 역류 방지를 **둘 다 무시**한다.
        // 사용자가 명시적으로 누른 것이므로 넘겨짚지 않는다.
        // IME 정렬에 더해 **포커스 바운스**로 꼬인 입력 세션까지 리셋한다
        // (IME 재선택만으로는 꼬임이 안 풀린다 — 2026-08-07 실측).
        if parts[1] == "force" {
            // 남이 누른 것이라도 **이 기기가 불참이면 적용하지 않는다.**
            // 「끔」은 "이 기기는 한/영 동기화에 참여하지 않는다"는 뜻이어야 한다.
            guard imeEnabled else { log("  ↳ \(ip) · force 무시 (이 기기 동기화 꺼짐)"); return }
            guard parts.count >= 3 else { log("force 형식 오류 — 무시 (\(ip))"); return }
            let lang = parts[2]
            guard ["ko", "en"].contains(lang) else { log("force: 알 수 없는 언어 \(lang)"); return }
            // UDP 유실 대비 3연발이 오므로 ts 로 중복 제거 — 바운스가 3번 튀면 안 된다
            let ts = parts.count >= 4 ? Int64(parts[3]) ?? 0 : 0
            if ts != 0, ts == lastForceTs { return }
            lastForceTs = ts
            DispatchQueue.main.async {
                // 잠긴 기기는 IME 를 en 으로 강제 유지하고 최전면은 로그인 창이다 — 건드리지 않는다
                guard !isScreenLocked() else { log("  ↳ \(ip) · force 생략 (화면 잠김)"); return }
                suppressor.suppress()
                selectLanguage(lang)          // 이미 그 언어여도 재선택 = 조합 세션 리셋
                log("  ↳ \(ip) · force 정렬 → \(lang) + 포커스 바운스")
                bounceFrontmostFocus()
            }
            return
        }

        // 자동복구 — `force` 의 안전판. 자동으로 오는 지시라 **실제로 다를 때만** 손댄다.
        // 이미 같으면 아무것도 하지 않는다(같은 값 재적용이 조합을 깨는 하트비트 사고 회피).
        // 적용했다면 포커스 바운스까지 — IME 정렬만으로는 꼬인 세션이 안 풀리기 때문.
        if parts[1] == "recover" {
            // ⚠ 여기 게이트가 없어서 「끔」이 사실상 안 먹었다(2026-08-08 실사용 신고).
            //   일반 state 수신만 막혀 있었고, 상대의 자동정정이 이 구멍으로 그대로 들어와
            //   껐는데도 IME 가 바뀌었다. 자동으로 오는 지시라 더더욱 막아야 한다.
            guard imeEnabled else { log("  ↳ \(ip) · recover 무시 (이 기기 동기화 꺼짐)"); return }
            guard parts.count >= 3 else { log("recover 형식 오류 — 무시 (\(ip))"); return }
            let lang = parts[2]
            guard ["ko", "en"].contains(lang) else { log("recover: 알 수 없는 언어 \(lang)"); return }
            let ts = parts.count >= 4 ? Int64(parts[3]) ?? 0 : 0
            if ts != 0, ts == lastRecoverTs { return }   // UDP 3연발 중복 제거 (바운스 1회만)
            lastRecoverTs = ts
            DispatchQueue.main.async {
                // 잠긴 화면은 IME 를 en 으로 강제 유지하므로 손대봐야 되돌려지고,
                // 바운스는 로그인 창을 건드린다. 아무도 안 쓰는 기기라 그냥 두는 게 맞다.
                guard !isScreenLocked() else { log("  ↳ \(ip) · 자동복구 생략 (화면 잠김)"); return }
                guard currentLanguage() != lang else { return }
                globalWatcher?.noteReceived(lang: lang, from: ip)
                suppressor.suppress()
                selectLanguage(lang)
                log("  ↳ \(ip) · 자동복구 → \(lang) + 포커스 바운스")
                bounceFrontmostFocus()
            }
            return
        }

        let lang = parts[1]
        guard ["ko", "en"].contains(lang) else { log("알 수 없는 언어: \(lang)"); return }
        guard imeEnabled else { return }
        // 두 기기 시계가 NTP 로 맞춰져 있다는 전제의 근사값
        let netMs = parts.count >= 3 ? Int64(parts[2]).map { recvMs - $0 } : nil

        DispatchQueue.main.async {
            // ⚠ 판정은 **실제 상태**로 한다. 한때 "마지막으로 적용한 값"을 캐시해 비교했는데,
            //   그건 "macbridge 만이 이 기기의 입력 소스를 바꾼다"는 틀린 가정이었다.
            //   실제로는 사용자·앱(예: 앱별 입력 소스 기억)이 독립적으로 바꾼다. 캐시가 실제와
            //   어긋나면 **정정 요청이 조용히 무시돼 자소분리가 고착된다**(2026-08-06 실사용 발생:
            //   집미니가 스스로 ko 로 드리프트 → 캐시는 en → 맥북이 보낸 en 이 무시됨).
            //   원래 캐시를 둔 이유는 상태 조회가 `defaults` 서브프로세스로 68ms 였기 때문인데,
            //   지금은 TIS 로 0~3ms 라 근거 자체가 사라졌다. 중복 전송분도 이 비교로 함께 걸러진다.
            guard currentLanguage() != lang else { return }
            globalWatcher?.noteReceived(lang: lang, from: ip)   // 이 피어에게 되쏘지 않도록 기록
            suppressor.suppress()                      // 내 변경이 되쏘이지 않도록
            let t0 = nowMs()
            selectLanguage(lang)
            let applyMs = nowMs() - t0
            let net = netMs.map { "\($0)ms" } ?? "?"
            log("  ↳ \(ip) · 편도 \(net) · 수신→전환 \(nowMs() - recvMs)ms (전환자체 \(applyMs)ms)")

            // ⚠ 적용됐는지 되읽어 확인한다. `TISSelectInputSource` 는 **noErr 를 돌려주면서도
            //   실제 전환을 하지 않는 경우가 있다** (2026-08-06 회사미니 실측: "전환 성공" 로그를
            //   10회 연속 찍는 동안 실제 상태는 내내 그대로였다). 반환값만 믿으면 조용히 어긋난 채
            //   남고, 로그가 오히려 거짓 알리바이를 준다.
            //   ⏱ 즉시 읽지 않고 200ms 뒤에 읽는다 — TIS 의 프로세스 내 캐시가 분산 알림으로
            //     갱신될 시간을 줘야 거짓 경보가 안 뜬다.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let after = currentLanguage()
                guard after != lang else { return }
                log("  ⚠ 전환 미반영 — 요청 \(lang) · 0.2초 뒤 실제 \(after ?? "?")"
                    + "  (다른 무언가가 되돌렸거나, 시스템이 요청을 무시함)")
            }
        }
    }
}

extension SyncServer {
    func replyCtl(_ text: String, to addr: sockaddr_in) {
        let bytes = Array("\(text)\n".utf8)
        var to = addr
        let fd = self.fd
        _ = withUnsafePointer(to: &to) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    func handleControl(_ cmd: ControlCommand, replyTo addr: sockaddr_in) {
        switch cmd {
        case .ping:
            replyCtl("ok", to: addr)
        case .reload:
            DispatchQueue.main.async {
                let (msg, ok) = reloadSettings()
                self.replyCtl(ok ? msg : "err \(msg)", to: addr)
            }
        case .pairStart(let secret):
            globalPairing.open(secret: secret, nowMs: nowMs())
            log("페어링 창 열림 — 120초 동안 새 기기의 연결을 받는다")
            replyCtl("ok", to: addr)
        case .pairStop:
            globalPairing.close()
            log("페어링 창 닫음")
            replyCtl("ok", to: addr)
        case .realign:
            DispatchQueue.main.async {
                guard let cfg = HotkeyManager.config else {
                    self.replyCtl("err no-config", to: addr); return
                }
                log("메뉴바 요청 — realign")
                performRealign(cfg)
                self.replyCtl("ok", to: addr)
            }
        case .sync(let on):
            DispatchQueue.main.async {
                self.setImeEnabled(on)
                log("메뉴바 요청 — IME 동기화 \(on ? "켬" : "끔")")
                if let err = persistSyncEnabled(on) {
                    self.replyCtl("err \(err)", to: addr)
                } else {
                    self.replyCtl("ok", to: addr)
                }
            }

        // ---- 「먼저 말 걸기」 응답 ----
        case .addTool(let app):
            DispatchQueue.main.async {
                guard let w = globalWatcher else { self.replyCtl("err no-watcher", to: addr); return }
                var next = w.onlyApps
                if !next.contains(app) { next.append(app) }
                if let err = persistOnlyApps(next) {
                    self.replyCtl("err \(err)", to: addr); return
                }
                w.onlyApps = next          // 파일뿐 아니라 런타임도 즉시 — 재시작 없이 먹어야 한다
                w.resolveTool(app)
                log("메뉴바 요청 — 원격 도구에 추가: \(app)")
                self.replyCtl("ok", to: addr)
            }
        case .dismissTool(let app):
            DispatchQueue.main.async {
                guard let w = globalWatcher else { self.replyCtl("err no-watcher", to: addr); return }
                let list = w.dismissTool(app)
                if let err = persistDismissedTools(list) {
                    self.replyCtl("err \(err)", to: addr); return
                }
                log("메뉴바 요청 — 원격 도구 아님으로 표시: \(app) (다시 묻지 않는다)")
                self.replyCtl("ok", to: addr)
            }
        }
    }

    /// `<시크릿> pair <id> <이름...>` → `paired <token> <peer…>`
    ///
    /// 성공하면 상대를 내 peers 에도 넣는다(양쪽이 서로를 알아야 동기화가 성립한다).
    func handlePair(_ parts: [String], from ip: String, addr: sockaddr_in) {
        let secret = parts[0]
        let name = parts[3...].joined(separator: " ")
        switch globalPairing.verify(secret, nowMs: nowMs()) {
        case .closed:
            log("페어링 거부 — 창이 열려 있지 않다 (\(ip))")
            replyCtl("pair-err closed", to: addr)
        case .expired:
            log("페어링 거부 — 시간이 지났다 (\(ip))")
            replyCtl("pair-err expired", to: addr)
        case .wrongSecret:
            log("페어링 거부 — 코드가 틀렸다 (\(ip))")
            replyCtl("pair-err wrong-code", to: addr)
        case .ok:
            // ⚠ 파일에는 **언제나** 남긴다 — `serve` 전용 모드면 watcher 가 없어서
            //   런타임 추가는 실패하지만, 그래도 다음 기동 때 반영돼야 한다.
            let added = globalWatcher?.addPeerHost(ip, port: port) ?? false
            _ = persistPeerAdd(ip)
            log("페어링 성공 — \(name) (\(ip))"
                + (added ? " 를 목록에 추가" : " (런타임 추가 생략 — 이미 있거나 serve 모드)"))
            // 내 토큰과 **나를 포함한** 전체 목록을 넘긴다.
            // 새 기기는 이 목록으로 나머지 기기들에게 직접 인사한다.
            // 항목은 "IP:PORT" 로 보낸다 — 기기마다 포트가 다를 수 있고,
            // 받는 쪽은 `Peer.parse` 로 그대로 읽는다(config 의 peers 형식과 같다).
            let mine = localIPv4Addresses()
            let others = (globalWatcher?.peerEntries() ?? [])
                .filter { !$0.hasPrefix("\(ip):") && !mine.contains($0.split(separator: ":").first.map(String.init) ?? $0) }
            let me = bestLocalIPForPairing()
            let list = ((me.isEmpty ? [] : ["\(me):\(port)"]) + others)
            replyCtl("paired \(token) \(list.joined(separator: " "))", to: addr)
            globalPairing.close()   // 한 번 쓰면 닫는다
            log("페어링 창 닫음 (연결 완료)")
        }
    }

    func setImeEnabled(_ on: Bool) { imeEnabled = on }

    /// reload 가 포트 변경을 감지하는 데 쓴다(소켓 재바인딩은 재시작 몫).
    var boundPort: UInt16 { port }
}

// MARK: - 감시자 (송신측)

final class SyncWatcher: NSObject {
    private let registry: PeerRegistry
    /// ⚠ `ctl reload` 가 런타임에 갈아끼운다. 폴링 타이머(main)와 reload 가 함께 만지므로 큐로 감싼다.
    private var tokenStorage: String
    private var onlyAppsStorage: [String]
    private var deviceNameStorage: String
    private let settingsQueue = DispatchQueue(label: "macbridge.watcher.settings")
    var token: String {
        get { settingsQueue.sync { tokenStorage } }
        set { settingsQueue.sync { tokenStorage = newValue } }
    }
    var onlyApps: [String] {
        get { settingsQueue.sync { onlyAppsStorage } }
        set { settingsQueue.sync { onlyAppsStorage = newValue } }
    }
    var deviceName: String {
        get { settingsQueue.sync { deviceNameStorage } }
        set { settingsQueue.sync { deviceNameStorage = newValue } }
    }
    private let heartbeatSec: Double
    /// 복구 제스처 인정 시간. 전환 키(캡스락 vs 지구본)마다 왕복 속도가 크게 달라 조절 여지를 둔다.
    private let recoveryWindowMs: Int64
    private let deviceId: String?
    private let config: Config          // 복구 제스처의 realign 발사용
    private var autoRecoverStorage: Bool
    var autoRecover: Bool { autoRecoverStorage }
    private var lastSent: String?
    /// 직전 언어 전이 (from→to, 시각) — 복구 제스처(빠른 왕복) 판정용
    private var lastTransition: (from: String, at: Int64)?
    /// 내가 **스스로** 마지막으로 바꾼 시각. "상대를 따라갈까"의 판정 입력 —
    /// 내가 방금 바꿨다면 의도의 주체는 나이므로 남을 따라가면 안 된다.
    /// 수신해서 적용한 변경은 억제 창에 걸려 여기 기록되지 않는다.
    private var lastLocalChangeMs: Int64 = 0

    /// 「먼저 말 걸기」 — 목록에 없는 앱이 원격 도구인지 의심하는 카운터.
    /// 폴링(main)과 ctl(수신 큐)이 함께 만지므로 큐로 감싼다.
    private var hintStorage: ToolHintTracker
    private let hintQueue = DispatchQueue(label: "macbridge.watcher.toolhint")
    /// 지금 사용자에게 물어볼 앱 (메뉴바가 query 로 가져간다)
    var toolHintCandidate: String? { hintQueue.sync { hintStorage.candidate } }
    func noteToolSkipped(_ app: String, mismatched: Bool) {
        let promoted = hintQueue.sync { hintStorage.noteSkipped(app: app, mismatched: mismatched) }
        if promoted {
            log("원격 도구 의심 — \(app) 이(가) 목록에 없는데 어긋난 채로 "
                + "\(ToolHintTracker.threshold)회 건너뜀. 메뉴바에서 물어본다")
        }
    }
    /// 무시 처리 후 영속화할 목록을 돌려준다.
    func dismissTool(_ app: String) -> [String] {
        hintQueue.sync { hintStorage.dismiss(app); return hintStorage.dismissedList }
    }
    func resolveTool(_ app: String) { hintQueue.sync { hintStorage.resolve(app) } }

    init(config: Config) {
        self.registry = PeerRegistry(config.peers)
        self.tokenStorage = config.token
        self.onlyAppsStorage = config.onlyApps
        self.heartbeatSec = config.heartbeatSec
        self.recoveryWindowMs = config.recoveryWindowMs
        self.deviceId = config.deviceId
        self.deviceNameStorage = config.deviceName
        self.config = config
        self.autoRecoverStorage = config.autoRecover
        self.hintStorage = ToolHintTracker(dismissed: config.dismissedTools,
                                          known: Set(knownRemoteTools.map(\.bundleId)))
        super.init()
    }

    private var timer: DispatchSourceTimer?
    private var heartbeatTimer: DispatchSourceTimer?
    private var stateTimer: DispatchSourceTimer?
    private var lastSeen: String?

    /// 피어별로 **그 피어가 마지막에 알려 온 값**. 역류(되쏘기) 방지에 쓴다.
    ///
    /// 체인 원격(A→B→C)에서 중간 기기 B 는 뷰어가 최전면이라 **클라 행세를 하며 A 에게 되쏜다.**
    /// 그러면 정작 사람이 키를 치는 A 를 B 가 끌고 가, 어긋남이 **영영 안 풀린다**
    /// (2026-08-06 실측: 회사미니↔맥북이 서로 40건씩 주고받고 있었다).
    /// "그 피어가 준 값을 그 피어에게 되돌려 보내지 않는다"만 지켜도 이 고리가 끊긴다 —
    /// 그 값은 애초에 그쪽이 이미 갖고 있는 값이기 때문. 방향을 미리 정할 필요가 없어
    /// 양방향 구성이 그대로 유지된다.
    /// 그 피어로부터 **마지막으로 지시를 받은 시각**.
    ///
    /// 규칙: **나에게 지시하는 쪽에게는 내가 지시하지 않는다.** 그게 권한 방향이다.
    /// 값이 아니라 **방향**을 봐야 한다 — 값으로 판정하면 중간 기기가 스스로 바뀐 경우
    /// (예: Ctrl+Space) 값이 달라서 그대로 되쏘고, 정작 사람이 키를 치는 기기를 끌고 간다.
    ///
    /// 체인 원격(A→B→C)에서 B 는 뷰어가 최전면이라 클라 조건을 만족하지만, 동시에 A 에게
    /// 원격당하는 호스트다. macbridge 는 그걸 직접 알 수 없지만, **"최근 A 가 나에게 알려 왔다"**
    /// 는 사실만으로 방향을 정할 수 있다. B 는 A 에게 침묵하고 C 로만 흘려보낸다.
    ///
    /// TTL 을 두는 이유: 원격을 끊으면 역할이 바뀔 수 있어야 한다. 지시가 끊기고 이 시간이
    /// 지나면 다시 스스로 권한자가 된다.
    private var lastDirectedBy: [String: Int64] = [:]
    private let directedTTL: Int64 = 5_000

    private func recentlyDirectedBy(_ peer: String) -> Bool {
        guard let at = lastDirectedBy[peer] else { return false }
        return nowMs() - at < directedTTL
    }

    /// 수신측(SyncServer)이 호출한다. 반드시 main 큐에서.
    func noteReceived(lang: String, from ip: String) { lastDirectedBy[ip] = nowMs() }

    /// 최전면 앱이 `only_app` 과 맞는가 = "지금 이 기기가 원격을 걸고 있는가"
    private var isDriving: Bool {
        guard !onlyApps.isEmpty else { return true }
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return onlyApps.contains(front)
    }

    func start() {
        // ⚠ 핵심: NSApplication 이 없는 CLI 프로세스는 분산 알림 센터에서 "정지됨"으로
        // 취급돼 알림이 보류된다. .deliverImmediately 를 명시해야 실제로 도착한다.
        // 이 알림을 받아야 TIS 의 프로세스 내 캐시도 갱신되므로, 폴링만으로는 안 된다
        // (폴링해도 캐시된 옛 값만 읽힌다 — 실측).
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(inputSourceChanged),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )

        // 폴링. TIS 읽기가 0~3ms 라 촘촘히 돌려도 부담이 없다.
        // 실측상 알림보다 폴링이 먼저 잡는 경우도 많아, 이쪽이 사실상 주력이다.
        lastSeen = currentLanguage()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.05, repeating: 0.05)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = currentLanguage()
            guard now != self.lastSeen else { return }
            self.lastSeen = now
            self.onChange(via: "폴링")
        }
        t.resume()
        timer = t

        // 상태 keepalive — 5초. 변화가 없어도 "나는 지금 이렇다"를 알린다.
        // ⚠ 하트비트와 다르다: 이건 "이 값으로 바꿔라"가 아니라 "나는 지금 이렇다"이고,
        //   받는 쪽이 기록만 할 뿐 적용하지 않으므로 재적용 부작용이 없다.
        let st = DispatchSource.makeTimerSource(queue: .main)
        st.schedule(deadline: .now() + 1.0, repeating: 5.0)
        st.setEventHandler { [weak self] in self?.announceState() }
        st.resume()
        stateTimer = st

        // 하트비트 — 변화가 없어도 현재 언어를 되풀이해 알린다.
        // 변화 감지만으로는 **상대가 몰래 바뀐 경우를 영영 모른다**(그 사이 내내 자소분리).
        // 되풀이해 알리면 무엇이 되돌리든 한 주기 안에 정정된다.
        // ⚠ 원격을 걸고 있을 때(`only_app` 최전면)만 뛴다 — 로컬 작업 중에 남의 IME 를 흔들지 않도록.
        if heartbeatSec > 0 {
            let hb = DispatchSource.makeTimerSource(queue: .main)
            hb.schedule(deadline: .now() + heartbeatSec, repeating: heartbeatSec)
            hb.setEventHandler { [weak self] in self?.beat() }
            hb.resume()
            heartbeatTimer = hb
        }

        log("입력 소스 변경 감시 시작(알림+폴링, UDP 전송) → \(registry.all().map(\.description).joined(separator: ", "))"
            + (onlyApps.isEmpty ? " (앱 제한 없음)" : " (앱 한정: \(onlyApps.joined(separator: ", ")))")
            + (heartbeatSec > 0 ? " · 하트비트 \(heartbeatSec)초" : " · 하트비트 끔"))
    }

    /// 주기적으로 현재 언어를 재확인시킨다. 수신측은 이미 같으면 아무것도 하지 않으므로
    /// 정상 상태에서는 완전히 조용하고, **어긋났을 때만 정정 로그가 남는다**(그게 곧 진단 신호다).
    ///
    /// 다만 **"하트비트가 뛰고는 있는가"** 자체가 안 보이면 진단이 막힌다(실제로 한 번 막혔다).
    /// 그래서 뛰든 쉬든 `beatLogSec` 마다 한 줄만 상태를 남긴다 — 매초 찍으면 로그를 못 읽고,
    /// 아예 안 찍으면 "안 뛰는 건지 어긋남이 없는 건지" 구분이 안 된다.
    private var lastBeatLog: Int64 = 0
    private let beatLogSec: Int64 = 10_000

    private func beat() {
        var skip: String?
        if !isDriving {
            skip = "최전면이 \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")"
        } else if suppressor.isSuppressed {
            skip = "수신 직후 억제 창"
        }
        let lang = currentLanguage()
        if skip == nil {
            if let l = lang {
                if !["ko", "en"].contains(l) { skip = "지원 밖 언어 \(l)" }
            } else {
                skip = "현재 언어를 읽지 못함"
            }
        }

        let now = nowMs()
        if now - lastBeatLog >= beatLogSec {
            lastBeatLog = now
            log(skip.map { "하트비트 쉼 — \($0)" }
                ?? "하트비트 동작 중 — \(lang ?? "?") 로 유지 통보 중")
        }

        guard skip == nil, let lang else { return }
        send(lang, readMs: 0, via: "하트비트", quiet: true)
    }

    @objc private func inputSourceChanged() {
        // 지연이 곧 자소분리로 이어지므로 최대한 빨리 처리한다.
        // 알림이 실제 전환보다 근소하게 빠른 경우가 있어 아주 짧은 틱만 둔다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { [weak self] in
            guard let self else { return }
            self.lastSeen = currentLanguage()
            self.onChange(via: "알림")
        }
    }

    private func onChange(via source: String) {
        let t0 = nowMs()
        let lang = currentLanguage() ?? "?"
        let readMs = nowMs() - t0

        // 상태 통보는 **사실 보고**라 게이트(억제·앱 한정)와 무관하게 즉시 나간다.
        // 상대는 기록만 하므로 에코 위험이 없고, 드라이빙 기기의 자동정정이 이 보고를 근거로 삼는다.
        if ["ko", "en"].contains(lang) { announceState() }

        // 상태 보고(위)는 꺼져 있어도 계속 내보낸다 — 상대 메뉴바에 내 현황이 보여야 하기 때문.
        // 그걸 근거로 상대가 자동정정을 쏘더라도 이제 수신에서 막히고, 3회 연속 무효인 피어는
        // 5분 백오프로 알아서 조용해진다. 반면 **지시**는 여기서 끊는다.
        // ⚠ cfg 가 아니라 런타임 플래그를 본다 — 메뉴 토글은 파일을 거치지 않고 즉시 반영된다.
        guard globalServer?.imeEnabled ?? true else { return }

        guard lang != lastSent else { return }          // 중복 트리거 — 조용히 통과
        guard !suppressor.isSuppressed else { return }  // 수신 직후 에코 차단
        guard ["ko", "en"].contains(lang) else { return }

        // 여기까지 왔다 = **내가 스스로** 바꿨다(수신 적용분은 위 억제 창에서 걸러졌다).
        // 앱 한정 가드보다 앞에 둔다 — 어느 앱에서 바꿨든 "내가 방금 바꿨다"는 사실은 같다.
        lastLocalChangeMs = t0

        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "(알수없음)"
        if !onlyApps.isEmpty, !onlyApps.contains(front) {
            log("감지(\(source)) \(lang) — 건너뜀: 최전면이 \(front)")
            // 이 침묵이 곧 "고장난 것 같다"로 읽힌다. 어긋난 채로 반복되면 앱이 먼저 말을 건다.
            let mismatched = globalPeers.snapshot(nowMs: nowMs())
                .contains { $0.isOnline && $0.lang != lang }
            noteToolSkipped(front, mismatched: mismatched)
            return
        }
        let prevLang = lastSent   // 드라이빙 연속 구간에서 = 직전 언어
        lastSent = lang
        send(lang, readMs: readMs, via: source)

        // 복구 제스처 — 한/영 빠른 두 번(왕복). 같은 값으로 돌아와 호스트에 순효과가 없는
        // 패턴을 명시적 복구 신호로 해석한다: 전 피어 force 정렬 + 포커스 바운스.
        // 캡스락은 뷰어 최전면에서도 로컬에 먹으므로, ⌃⌥⇧K 가 뷰어에 삼켜지는 문제를 우회한다.
        let win = recoveryWindowMs
        let gap = t0 - (lastTransition?.at ?? 0)
        if isRecoveryGesture(prevFrom: lastTransition?.from, prevAtMs: lastTransition?.at ?? 0,
                             to: lang, atMs: t0, windowMs: win) {
            log("복구 제스처 감지 (\(lang) 왕복 \(gap)ms ≤ \(win)ms) → 전 피어 realign + 포커스 바운스")
            performRealign(config)
        } else if isMissedRecoveryGesture(prevFrom: lastTransition?.from,
                                          prevAtMs: lastTransition?.at ?? 0,
                                          to: lang, atMs: t0, windowMs: win) {
            // 놓친 제스처를 반드시 남긴다. 안 그러면 "눌러도 아무 반응이 없다"로만 보여
            // 원인을 짐작할 수가 없다 — 지구본 키 사용자가 정확히 이 상태였다(2026-08-08).
            log("복구 제스처 놓침 (\(lang) 왕복 \(gap)ms > \(win)ms) — 더 빨리 두 번 누르거나 "
                + "ime_sync.recovery_window_ms 를 늘리세요")
        }
        if let pv = prevLang, pv != lang { lastTransition = (from: pv, at: t0) }
    }

    /// reload 가 peers 를 통째로 갈아끼운다.
    func applyPeers(_ peers: [Peer]) { registry.replaceAll(peers) }

    /// 런타임에 피어 하나를 더한다. 이미 있으면 false.
    @discardableResult
    func addPeerHost(_ host: String, port: UInt16) -> Bool {
        registry.add(Peer(host: host, port: port))
    }

    func peerHosts() -> [String] { registry.all().map(\.host) }

    /// "IP:PORT" 형태 — 페어링 응답과 config `peers` 가 같은 형식을 쓴다.
    func peerEntries() -> [String] { registry.all().map(\.description) }

    /// reload 가 자동복구 on/off 를 바꾼다. (읽기·쓰기 모두 main 큐라 별도 잠금 불필요)
    func setAutoRecover(_ on: Bool) { autoRecoverStorage = on }

    /// 피어의 state 보고를 받았을 때(SyncServer 가 main 큐에서 호출) — 자동정정 판단.
    ///
    /// 백오프: 유휴 GUI 세션(예: 아무도 안 쓰는 회사미니)은 TIS 쓰기를 무시하므로
    /// 정정이 영원히 무효다 — 그대로 두면 keepalive 마다 5초 간격 무한 정정이 된다(실측).
    /// 정정을 보냈는데도 다음 보고가 여전히 불일치면 무효로 세고, 3회 연속이면 5분 쉰다.
    /// 일치 보고가 오면(기기가 깨어나 정렬되면) 즉시 원상복귀.
    /// ⚠ **반드시 피어별**이어야 한다. 전역 하나로 뒀더니 잠금 화면 기기가 5초마다 슬롯을
    /// 독점해 정작 사람이 쓰는 호스트가 정정을 **한 번도 못 받았다**(2026-08-07 실측).
    private var correctionHistory: [String: [Int64]] = [:]
    private var throttleAnnounced: Set<String> = []
    /// 정정을 보내 놓고 아직 결과(다음 state 보고)를 못 본 피어
    private var pendingCorrection: Set<String> = []
    /// 정정을 보냈는데도 여전히 어긋난 채로 보고해 온 **연속** 횟수
    private var correctionFailStreak: [String: Int] = [:]
    private var correctionBackoffUntil: [String: Int64] = [:]

    func noteState(lang peerLang: String, from ip: String, justChanged: Bool = false) {
        let my = currentLanguage()
        let now = nowMs()

        // 상대가 **혼자** 바꿨으면 되돌리지 말고 따라간다.
        // Jump Desktop 의 Ctrl+Space 처럼 뷰어가 키를 삼켜 호스트만 바꾸는 경우가 여기다.
        // 되돌리면 사용자에겐 "우리 앱이 한영전환을 막는" 것으로 보인다.
        if shouldFollowPeer(myLang: my, peerLang: peerLang, peerJustChanged: justChanged,
                            driving: isDriving, suppressed: suppressor.isSuppressed,
                            msSinceMyChange: now - lastLocalChangeMs) {
            // 잠긴 기기는 en 이 강제된 것이지 사용자 의도가 아니다 — 이 가드가 최후 방어선이다.
            guard !isScreenLocked() else { return }
            guard currentLanguage() != peerLang else { return }
            suppressor.suppress()                 // 따라간 결과가 되쏘이지 않도록
            selectLanguage(peerLang)
            lastSent = peerLang                   // 내 변경으로 오인해 되쏘지 않게
            log("상대가 혼자 바꿨다 — \(ip) 의 \(peerLang) 를 따라간다(되돌리지 않음) + 포커스 바운스")
            bounceFrontmostFocus()                // Ctrl+Space 가 심은 꼬임까지 함께 푼다
            pendingCorrection.remove(ip)
            correctionFailStreak[ip] = 0
            return
        }
        if let m = my, peerLang == m {
            // 정렬됨 — 정정이 먹혔다는 뜻이므로 실패 이력을 전부 푼다.
            // ⚠ 사용자가 Ctrl+Space 로 반복해 어긋내도 매번 여기를 지나므로 누적되지 않는다.
            pendingCorrection.remove(ip)
            correctionFailStreak[ip] = 0
            correctionBackoffUntil[ip] = nil
            correctionHistory[ip] = nil
            throttleAnnounced.remove(ip)
            return
        }

        // 어긋난 채로 보고해 왔다. 직전에 정정을 보냈다면 **그 정정은 무효였다.**
        // 잠긴 기기는 적용 자체를 거부하므로(잠금 가드) 영영 여기로 온다 — 그게 이 카운터의 표적이다.
        if pendingCorrection.remove(ip) != nil {
            let n = (correctionFailStreak[ip] ?? 0) + 1
            correctionFailStreak[ip] = n
            if n >= 3 {
                correctionBackoffUntil[ip] = now + 300_000
                if !throttleAnnounced.contains(ip) {
                    throttleAnnounced.insert(ip)
                    log("자동정정 백오프 — \(ip) 정정 \(n)회 연속 무효(잠김·유휴 세션?) → 5분 쉼")
                }
                return
            }
        }
        if let until = correctionBackoffUntil[ip], now < until { return }

        var hist = (correctionHistory[ip] ?? []).filter { now - $0 <= 60_000 }
        guard correctionAllowed(recentMs: hist, now: now) else { return }   // 폭주 방지만
        guard shouldAutoCorrect(myLang: my, peerLang: peerLang, driving: isDriving,
                                suppressed: suppressor.isSuppressed,
                                directedByPeer: recentlyDirectedBy(ip),
                                msSinceLast: now - (hist.last ?? 0)) else { return }
        hist.append(now)
        correctionHistory[ip] = hist
        pendingCorrection.insert(ip)    // 다음 보고로 이 정정이 먹혔는지 판정한다
        let lang = my ?? "?"
        // 드문 분기 — 로그를 남긴다 (조용한 성공은 진단을 막는다, 2026-08-06 교훈)
        log("자동정정 — \(ip) 보고 \(peerLang) ≠ 나 \(lang) → \(lang) 재전송"
            + (autoRecover ? " + 포커스 바운스 요청" : ""))
        // ⚠ 보고한 그 피어에게만 보낸다 — 전체 브로드캐스트는 멀쩡한 기기까지 흔든다
        sendRecover(lang, to: ip, bounce: autoRecover)
    }

    /// 불일치를 보고한 피어 하나에게만 복구 지시. UDP 유실 대비 3연발(수신측이 ts 로 중복 제거).
    /// - Parameter bounce: `recover`(정렬 + 포커스 바운스) / `false` 면 기존 lang 메시지(정렬만)
    private func sendRecover(_ lang: String, to host: String, bounce: Bool) {
        guard let peer = registry.find(host) else {
            log("  ⚠ 자동정정 대상 \(host) 가 peers 에 없음 — 전송 생략"); return
        }
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { log("  ⚠ 자동정정 전송 실패: 소켓 생성 불가"); return }
        defer { close(sock) }
        let body = bounce ? "recover \(lang)" : lang
        let bytes = Array("\(token) \(body) \(nowMs())\n".utf8)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = peer.port.bigEndian
        addr.sin_addr.s_addr = inet_addr(peer.host)
        guard addr.sin_addr.s_addr != INADDR_NONE else {
            log("  ⚠ 자동정정 전송 실패: \(peer) 주소 해석 불가"); return
        }
        var sent = 0
        for _ in 0..<3 {
            let n = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(sock, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if n > 0 { sent += 1 }
        }
        if sent == 0 { log("  ⚠ 자동정정 전송 실패: \(peer) sendto 오류") }
    }

    /// 내 상태를 전 피어에 알린다. 상대는 기록만 하므로 IME 를 바꾸지 않는다.
    /// 역류 방지 대상이 아니다 — 적용 요청이 아니라 사실 통보이기 때문.
    func announceState() {
        guard let id = deviceId, let lang = currentLanguage(),
              ["ko", "en"].contains(lang) else { return }
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return }
        defer { close(sock) }
        let bytes = Array("\(token) state \(id) \(deviceName) \(lang) \(nowMs())\n".utf8)
        for peer in registry.all() {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = peer.port.bigEndian
            addr.sin_addr.s_addr = inet_addr(peer.host)
            guard addr.sin_addr.s_addr != INADDR_NONE else { continue }
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(sock, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// UDP 로 즉시 던진다. 연결 수립이 없어 지연이 최소다.
    /// 도착 확인이 없는 대신 **같은 값을 3번 연달아** 보내 유실에 대비한다
    /// (수신측은 이미 같은 언어면 무시하므로 중복은 무해하다).
    /// - Parameter quiet: 성공 시 로그를 남기지 않는다(하트비트용 — 매초 찍히면 로그를 못 읽는다).
    ///                    실패는 quiet 여부와 무관하게 남긴다.
    private func send(_ lang: String, readMs: Int64, via source: String, quiet: Bool = false) {
        let sendStart = nowMs()
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { log("전송 실패: 소켓 생성 불가"); return }
        defer { close(sock) }

        // 송신 시각을 함께 실어 보내면 수신측이 편도 지연을 계산할 수 있다
        let bytes = Array("\(token) \(lang) \(nowMs())\n".utf8)
        var ok: [String] = []
        var failed: [String] = []

        var skipped: [String] = []
        for peer in registry.all() {
            // 역류 방지 — 최근 나에게 지시한 쪽에게는 되쏘지 않는다(그쪽이 권한자다)
            if recentlyDirectedBy(peer.host) { skipped.append(peer.host); continue }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = peer.port.bigEndian
            addr.sin_addr.s_addr = inet_addr(peer.host)
            guard addr.sin_addr.s_addr != INADDR_NONE else {
                failed.append("\(peer)(주소 해석 불가 — IP 로 지정해야 합니다)")
                continue
            }
            var sent = 0
            for _ in 0..<3 {
                let n = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(sock, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if n > 0 { sent += 1 }
            }
            if sent > 0 { ok.append(peer.description) } else { failed.append("\(peer)(sendto 오류)") }
        }

        if quiet && failed.isEmpty { return }
        var line = "감지(\(source))→전송 \(lang)  [상태읽기 \(readMs)ms · 발송 \(nowMs() - sendStart)ms]"
        if !ok.isEmpty { line += " → \(ok.joined(separator: ", "))" }
        if !skipped.isEmpty { line += "  (역류방지 생략: \(skipped.joined(separator: ", ")))" }
        if !failed.isEmpty { line += "  ⚠ 실패: \(failed.joined(separator: ", "))" }
        log(line)   // ⚠ 전부 역류방지로 생략된 경우에도 남긴다 — 조용하면 "작동한 건지 안 한 건지"를 못 가린다
    }
}

// MARK: - 설정 다시 읽기 (ctl reload)

/// config 를 다시 읽어 런타임 필드를 갈아끼운다.
///
/// 포트만 예외다 — 소켓을 이미 bind 했으므로 바꾸려면 재시작해야 한다.
/// - Returns: (응답 문자열, 성공 여부)
func reloadSettings() -> (String, Bool) {
    let path = argValue("--config") ?? defaultConfigPath
    let cfg: Config
    do { cfg = try loadConfig(path: path) } catch { return ("\(error)", false) }

    let portChanged = globalServer.map { $0.boundPort != cfg.port } ?? false

    globalServer?.token = cfg.token
    globalServer?.allowFrom = cfg.allowFrom
    globalServer?.setImeEnabled(cfg.imeSyncEnabled)

    globalWatcher?.token = cfg.token
    globalWatcher?.onlyApps = cfg.onlyApps
    globalWatcher?.deviceName = cfg.deviceName
    globalWatcher?.applyPeers(cfg.peers)
    globalWatcher?.setAutoRecover(cfg.autoRecover)

    HotkeyManager.config = cfg
    globalHotkeys?.unregisterAll()
    globalHotkeys?.register(cfg)

    log("설정 다시 읽음 — 앱한정 \(cfg.onlyAppLabel) · 피어 \(cfg.peers.count)대"
        + " · 동기화 \(cfg.imeSyncEnabled ? "켬" : "끔") · 자동복구 \(cfg.autoRecover ? "켬" : "끔")"
        + (portChanged ? " · ⚠ 포트 변경은 재시작이 필요합니다" : ""))
    return (portChanged ? "ok restart-needed" : "ok", true)
}
