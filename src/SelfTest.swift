import Foundation
import Carbon   // controlKey 등 modifier 상수 (핫키 파싱 테스트)

/// 외부 의존이 없는 순수 함수만 검증한다. `macbridge selftest` 로 실행.
/// 통합 동작은 스펙 §7 의 실측 표로 확인한다.
enum SelfTest {
    nonisolated(unsafe) static var passed = 0
    nonisolated(unsafe) static var failed = 0

    static func check(_ name: String, _ actual: String, _ expected: String) {
        if actual == expected { passed += 1; print("  ✓ \(name)") }
        else { failed += 1; print("  ✗ \(name)\n      기대: \(expected)\n      실제: \(actual)") }
    }

    static func check(_ name: String, _ cond: Bool) {
        if cond { passed += 1; print("  ✓ \(name)") }
        else { failed += 1; print("  ✗ \(name)") }
    }

    static func run() -> Never {
        print("macbridge selftest\n")

        print("[자소분리 판정]")
        check("정상 한글은 0", detachedJamoCount("단계") == 0)
        check("낱자만 있으면 그 수", detachedJamoCount("ㄷㅏㄴㄱㅖ") == 5)
        check("섞이면 낱자만 셈", detachedJamoCount("3단계 ㄴㅏ") == 2)
        check("영문·숫자는 0", detachedJamoCount("hello 123") == 0)
        check("빈 문자열은 0", detachedJamoCount("") == 0)

        print("\n[state 메시지 파싱]")
        let ok = parseStateMessage(["TOK", "state", "id-1", "회사미니", "ko", "1700000000000"])
        check("정상 파싱 — id", ok?.deviceId ?? "", "id-1")
        check("정상 파싱 — name", ok?.name ?? "", "회사미니")
        check("정상 파싱 — lang", ok?.lang ?? "", "ko")
        check("정상 파싱 — ts", (ok?.sentMs).map(String.init) ?? "", "1700000000000")

        let spaced = parseStateMessage(["TOK", "state", "id-2", "Mac", "mini", "office", "en", "1700000000001"])
        check("이름에 공백이 있어도 됨", spaced?.name ?? "", "Mac mini office")

        check("필드가 모자라면 nil", parseStateMessage(["TOK", "state", "id", "n", "ko"]) == nil)
        check("ts 가 숫자가 아니면 nil", parseStateMessage(["TOK", "state", "id", "n", "ko", "xx"]) == nil)
        check("모르는 언어면 nil", parseStateMessage(["TOK", "state", "id", "n", "fr", "1700000000000"]) == nil)
        check("id 가 비면 nil", parseStateMessage(["TOK", "state", "", "n", "ko", "1700000000000"]) == nil)

        print("\n[피어 테이블]")
        let t = PeerTable()
        t.update(StateMessage(deviceId: "a", name: "맥북", lang: "ko", sentMs: 0), ip: "100.1.1.1", nowMs: 1000)
        t.update(StateMessage(deviceId: "b", name: "집미니", lang: "en", sentMs: 0), ip: "100.1.1.2", nowMs: 1000)
        check("2대가 기록됨", t.snapshot(nowMs: 1000).count == 2)

        t.update(StateMessage(deviceId: "a", name: "맥북", lang: "en", sentMs: 0), ip: "100.1.1.1", nowMs: 2000)
        check("같은 id 는 갱신(중복 아님)", t.snapshot(nowMs: 2000).count == 2)
        check("언어가 갱신됨", t.snapshot(nowMs: 2000).first { $0.deviceId == "a" }?.lang ?? "", "en")

        check("15초 넘으면 오프라인", t.snapshot(nowMs: 2000 + 15_001).allSatisfy { !$0.isOnline })
        check("15초 이내면 온라인", t.snapshot(nowMs: 2000 + 1_000).contains { $0.isOnline })

        // 이 시점 a=en(2000 갱신), b=en(1000 기록) — 둘 다 en 이다.
        // snapshot 은 이름순 정렬이라 "맥북"(a) 이 "집미니"(b) 보다 앞선다.
        check("내 언어와 다르면 불일치", t.mismatched(myLang: "ko", nowMs: 2000).map(\.deviceId) == ["a", "b"])
        check("내 언어와 같으면 불일치 없음", t.mismatched(myLang: "en", nowMs: 2000).isEmpty)

        print("\n[핫키 조합 파싱]")
        let hk = parseHotkeyCombo("ctrl+opt+shift+k")
        check("keycode(k=40)", (hk?.keyCode).map(String.init) ?? "", "40")
        check("modifier 가 3개 합쳐짐",
              hk.map { $0.modifiers == UInt32(controlKey | optionKey | shiftKey) } ?? false)
        check("대소문자 무시", parseHotkeyCombo("CTRL+K")?.keyCode == 40)
        check("공백 허용", parseHotkeyCombo(" ctrl + k ")?.keyCode == 40)
        check("cmd 별칭", parseHotkeyCombo("cmd+k")?.modifiers == UInt32(cmdKey))
        check("모르는 키는 nil", parseHotkeyCombo("ctrl+구름") == nil)
        check("modifier 만 있으면 nil", parseHotkeyCombo("ctrl+shift") == nil)
        check("빈 문자열은 nil", parseHotkeyCombo("") == nil)

        print("\n[자동정정 판정]")
        func corr(my: String? = "ko", peer: String = "en", driving: Bool = true,
                  supp: Bool = false, directed: Bool = false, since: Int64 = 10_000) -> Bool {
            shouldAutoCorrect(myLang: my, peerLang: peer, driving: driving,
                              suppressed: supp, directedByPeer: directed, msSinceLast: since)
        }
        check("불일치 + 드라이빙이면 정정", corr())
        check("같으면 안 함", !corr(peer: "ko"))
        check("드라이빙 아니면 안 함", !corr(driving: false))
        check("억제 창에는 안 함", !corr(supp: true))
        check("나를 지시하는 피어는 안 건드림", !corr(directed: true))
        check("2초 안에 또 안 함", !corr(since: 1_999))
        check("내 언어를 못 읽으면 안 함", !corr(my: nil))
        check("지원 밖 언어면 안 함", !corr(my: "ja"))

        print("\n[상대를 따라갈까 (Ctrl+Space 대응)]")
        func follow(my: String? = "ko", peer: String = "en", changed: Bool = true,
                    driving: Bool = true, supp: Bool = false, sinceMine: Int64 = 10_000) -> Bool {
            shouldFollowPeer(myLang: my, peerLang: peer, peerJustChanged: changed,
                             driving: driving, suppressed: supp, msSinceMyChange: sinceMine)
        }
        check("상대만 방금 바뀌었으면 따라간다", follow())
        check("전이가 아니면(정체된 불일치) 안 따라간다 — 잠긴 기기 방어",
              !follow(changed: false))
        check("내가 방금 바꿨으면 주체는 나다", !follow(sinceMine: 2_999))
        check("3초 지났으면 상대가 주체", follow(sinceMine: 3_000))
        check("원격 세션이 아니면 남을 안 따른다", !follow(driving: false))
        check("억제 창에는 안 따른다(에코 방지)", !follow(supp: true))
        check("이미 같으면 할 일 없음", !follow(peer: "ko"))
        check("내 언어를 못 읽으면 안 함", !follow(my: nil))
        check("지원 밖 언어는 안 함", !follow(peer: "ja"))

        // 복구 제스처 판정은 아래 [복구 제스처 시간 창] 에서 실측값 기준으로 함께 본다.

        print("\n[정정 스로틀]")
        check("첫 정정은 허용", correctionAllowed(recentMs: [], now: 10_000))
        check("2초 안에는 차단", !correctionAllowed(recentMs: [9_000], now: 10_000))
        check("2초 지나면 허용", correctionAllowed(recentMs: [8_000], now: 10_000))
        // ⚠ 사용자가 Ctrl+Space 로 반복해 어긋내는 건 정상 사용이다 — 여기서 막으면 안 된다.
        //   "고쳐도 소용없는 피어" 판정은 결과 기반(연속 무효 3회)으로 noteState 가 한다.
        check("반복해 어긋내도 막지 않음(4회는 통과)",
              correctionAllowed(recentMs: [1_000, 2_000, 3_000, 4_000], now: 10_000))
        check("폭주 상한(분당 30회)은 막음",
              !correctionAllowed(recentMs: (1...30).map { Int64($0 * 100) }, now: 10_000))
        check("창 밖 이력은 안 셈",
              correctionAllowed(recentMs: (1...30).map { Int64($0 * 100) }, now: 100_000))
        check("피어별 독립 — 남의 이력은 안 넘어옴", correctionAllowed(recentMs: [], now: 10_001))

        print("\n[only_app 파싱]")
        check("문자열 하나면 1개 목록", parseOnlyApps(.string("com.a")) == ["com.a"])
        check("배열이면 그대로", parseOnlyApps(.array(["com.a", "com.b"])) == ["com.a", "com.b"])
        check("빈 문자열은 제한 없음(빈 목록)", parseOnlyApps(.string("")) == [])
        check("빈 배열도 제한 없음", parseOnlyApps(.array([])) == [])
        check("배열 속 빈 값은 걸러냄", parseOnlyApps(.array(["com.a", ""])) == ["com.a"])
        check("nil 이면 제한 없음", parseOnlyApps(nil) == [])

        print("\n[피어 레지스트리]")
        let reg = PeerRegistry([Peer(host: "10.0.0.1", port: 8765)])
        check("초기 목록", reg.all().map(\.host) == ["10.0.0.1"])
        check("추가되면 늘어남", reg.add(Peer(host: "10.0.0.2", port: 8765)))
        check("추가 후 2개", reg.all().count == 2)
        check("같은 호스트는 중복 추가 안 됨", !reg.add(Peer(host: "10.0.0.2", port: 8765)))
        check("중복 시도 후에도 2개", reg.all().count == 2)
        check("호스트로 찾기", reg.find("10.0.0.2")?.port == 8765)
        check("없는 호스트는 nil", reg.find("10.0.0.9") == nil)
        check("삭제되면 빠짐", reg.remove("10.0.0.1"))
        check("삭제 후 1개", reg.all().count == 1)
        check("없는 호스트 삭제는 false", !reg.remove("10.0.0.9"))
        reg.replaceAll([Peer(host: "10.0.0.7", port: 8765)])
        check("통째 교체", reg.all().map(\.host) == ["10.0.0.7"])

        print("\n[제어 명령 파싱]")
        check("realign", parseControl(["TOK", "ctl", "realign"]) == .realign)
        check("sync on", parseControl(["TOK", "ctl", "sync", "on"]) == .sync(true))
        check("sync off", parseControl(["TOK", "ctl", "sync", "off"]) == .sync(false))
        check("ping", parseControl(["TOK", "ctl", "ping"]) == .ping)
        check("ctl 이 아니면 nil", parseControl(["TOK", "state", "x"]) == nil)
        check("모르는 명령은 nil", parseControl(["TOK", "ctl", "explode"]) == nil)
        check("sync 인자 없으면 nil", parseControl(["TOK", "ctl", "sync"]) == nil)
        check("add-tool", parseControl(["TOK", "ctl", "add-tool", "tv.parsec.www"])
                == .addTool("tv.parsec.www"))
        check("dismiss-tool", parseControl(["TOK", "ctl", "dismiss-tool", "com.philandro.anydesk"])
                == .dismissTool("com.philandro.anydesk"))
        check("add-tool 인자 없으면 nil", parseControl(["TOK", "ctl", "add-tool"]) == nil)
        check("add-tool 빈 인자는 nil", parseControl(["TOK", "ctl", "add-tool", ""]) == nil)

        print("\n[수신 원문 비밀 가리기]")
        // 🔴 이게 없어서 토큰이 로그에 평문으로 남았다(2026-08-09). 첫 자리는 언제나 비밀이다.
        check("첫 자리는 무조건 가린다",
              redactMessage("abcd1234deadbeef ctl add-tool") == "<비밀 16자> ctl add-tool")
        check("가려도 형태는 남아 진단이 된다",
              redactMessage("TOK ctl pair-start").hasSuffix("ctl pair-start"))
        check("뒤쪽의 길고 무작위한 값도 가린다",
              redactMessage("TOK pair abcdef0123456789abcdef").contains("<가림 22자>"))
        check("짧은 값은 그대로 둔다", redactMessage("TOK state ko").hasSuffix("state ko"))
        check("빈 줄도 죽지 않는다", redactMessage("") == "(빈 줄)")

        print("\n[진단 번들 가리기]")
        let red = DiagnosticRedactor(
            token: "abcd1234deadbeefcafe",
            deviceAliases: makeDeviceAliases(myName: "홍길동의 MacBook Pro",
                                             peerNames: ["Mac mini", "mac-mini-office"]),
            keepBundleIds: ["tv.parsec.www", "com.apple.ScreenSharing"])
        check("토큰은 통째로 지운다",
              !red.line("token=abcd1234deadbeefcafe").contains("abcd1234"))
        check("내 기기 이름은 '이 기기'로",
              red.line("홍길동의 MacBook Pro 시작") == "이 기기 시작")
        check("상대 기기도 번호로", red.line("Mac mini 와 연결") == "기기2 와 연결")
        check("아는 원격 도구는 남긴다 — 진단에 필요하다",
              red.line("건너뜀: 최전면이 tv.parsec.www").hasSuffix("tv.parsec.www"))
        check("모르는 앱은 지운다 — 사생활이지 진단이 아니다",
              red.line("건너뜀: 최전면이 com.microsoft.VSCode").hasSuffix("(다른 앱)"))
        check("카카오톡도 지워진다",
              !red.line("최전면이 com.kakao.KakaoTalkMac").contains("kakao"))
        check("IP 는 마지막 옥텟만 가린다 — 대역은 진단에 쓰인다",
              red.line("peer 100.64.0.83 응답").contains("100.64.0.***"))
        check("IP 가 번들 ID 로 오인되지 않는다",
              !red.line("peer 100.64.0.83 응답").contains("다른 앱"))
        // 🔴 실측으로 발견(2026-08-09): "설정 로드: /Users/someone/…" 한 줄로 계정명이 샌다
        let redHome = DiagnosticRedactor(token: "", deviceAliases: [:], keepBundleIds: [],
                                         homePath: "/Users/someone")
        check("홈 경로의 계정명을 지운다 — 경로 한 줄로 실명이 샌다",
              redHome.line("설정 로드: /Users/someone/.config/macbridge/config.json")
                == "설정 로드: ~/.config/macbridge/config.json")

        print("\n[로그 최근 구간 뽑기]")
        let fmt = makeLogTimestampFormatter()
        let now = fmt.date(from: "2026-08-09 12:00:00.000")!
        let sample = [
            "[2026-08-09 09:00:00.000] 오래된 줄",
            "[2026-08-09 11:30:00.000] 최근 줄",
            "  이어지는 줄(시각 없음)",
            "[2026-08-09 11:59:00.000] 더 최근",
        ]
        let got = recentLogLines(sample, now: now, hours: 1, maxLines: 100, formatter: fmt)
        check("창 밖 줄은 뺀다", !got.contains { $0.contains("오래된 줄") })
        check("창 안 줄은 남긴다", got.contains { $0.contains("최근 줄") })
        check("시각 없는 줄은 직전 판정을 따른다", got.contains { $0.contains("이어지는 줄") })
        check("상한을 넘으면 뒤에서 자른다",
              recentLogLines(sample, now: now, hours: 24, maxLines: 2, formatter: fmt).count == 2)
        check("자를 때 최신 쪽을 남긴다",
              recentLogLines(sample, now: now, hours: 24, maxLines: 1,
                             formatter: fmt).first?.contains("더 최근") == true)

        print("\n[캡스락 연습 판정]")
        check("창 안에 왕복하면 성공",
              practiceOutcome(firstFrom: "ko", secondTo: "ko", elapsedMs: 300, windowMs: 1_000)
                == .success(300))
        check("경계값(딱 창)도 성공",
              practiceOutcome(firstFrom: "ko", secondTo: "ko", elapsedMs: 1_000, windowMs: 1_000)
                == .success(1_000))
        check("느리면 걸린 시간을 알려 준다 — 그냥 '다시'는 나아지지 않는다",
              practiceOutcome(firstFrom: "ko", secondTo: "ko", elapsedMs: 1_400, windowMs: 1_000)
                == .tooSlow(1_400))
        check("왕복이 아니면 아직 진행 중",
              practiceOutcome(firstFrom: "ko", secondTo: "en", elapsedMs: 200, windowMs: 1_000)
                == .armed)

        print("\n[온보딩 단계 판정]")
        check("데몬 무응답이면 설치가 덜 된 것",
              onboardingStage(daemonResponding: false, onlinePeerCount: 0) == .daemonDown)
        check("데몬이 죽었으면 피어가 있어도 daemonDown",
              onboardingStage(daemonResponding: false, onlinePeerCount: 2) == .daemonDown)
        check("혼자면 alone (첫 실행의 정상 상태)",
              onboardingStage(daemonResponding: true, onlinePeerCount: 0) == .alone)
        check("상대가 붙으면 connected",
              onboardingStage(daemonResponding: true, onlinePeerCount: 1) == .connected(1))
        check("여러 대면 수를 그대로 전한다",
              onboardingStage(daemonResponding: true, onlinePeerCount: 3) == .connected(3))

        print("\n[복구 제스처 시간 창]")
        // ⚠ 회귀 방어(2026-08-08): 창을 2초로 넓혔더니 **평범한 한/영 전환이 전부 제스처로
        //   잡혀** 매 전환마다 포커스 바운스가 터졌고, 그 바운스가 한글 조합을 깨 자소분리를
        //   만들었다. `en→ko→en` 은 구조적으로 언제나 왕복이라 창 너비가 곧 안전선이다.
        //   아래 1.2초 케이스가 그 사고의 실측값이다 — 이 줄이 초록이어야 한다.
        check("캡스락 속도(0.2초)는 잡힌다",
              isRecoveryGesture(prevFrom: "ko", prevAtMs: 0, to: "ko", atMs: 200))
        check("정상 전환 리듬(1.2초)은 제스처가 아니다 ★회귀",
              !isRecoveryGesture(prevFrom: "ko", prevAtMs: 0, to: "ko", atMs: 1_218))
        check("창을 넘으면 아니다",
              !isRecoveryGesture(prevFrom: "ko", prevAtMs: 0, to: "ko", atMs: 1_001))
        check("창을 늘리면 지구본 속도도 잡힌다(설정으로 가능)",
              isRecoveryGesture(prevFrom: "ko", prevAtMs: 0, to: "ko", atMs: 1_800,
                                windowMs: 2_000))
        check("왕복이 아니면 아니다",
              !isRecoveryGesture(prevFrom: "en", prevAtMs: 0, to: "ko", atMs: 100))
        check("직전 전이가 없으면 아니다",
              !isRecoveryGesture(prevFrom: nil, prevAtMs: 0, to: "ko", atMs: 100))
        check("놓친 왕복은 따로 잡아 로그로 알린다",
              isMissedRecoveryGesture(prevFrom: "ko", prevAtMs: 0, to: "ko", atMs: 2_500))
        check("성공한 왕복은 놓침이 아니다",
              !isMissedRecoveryGesture(prevFrom: "ko", prevAtMs: 0, to: "ko", atMs: 800))
        check("지구본 속도(1.8초)는 이제 '놓침'으로 잡혀 로그에 남는다",
              isMissedRecoveryGesture(prevFrom: "ko", prevAtMs: 0, to: "ko", atMs: 1_800))
        check("한참 뒤 왕복은 놓침도 아니다(그냥 평소 사용)",
              !isMissedRecoveryGesture(prevFrom: "ko", prevAtMs: 0, to: "ko", atMs: 9_000))

        print("\n[query 응답 파싱]")
        do {
            let r = parseQueryResponse("me ko\npeer D1 400 en 10.0.0.2 집 미니\n")
            check("내 언어", r.myLang == "ko")
            check("피어 1개", r.peers.count == 1)
            check("공백 있는 이름", r.peers.first?.name == "집 미니")
            check("제안 없으면 nil", r.suggestedTool == nil)
        }
        do {
            let r = parseQueryResponse("me ko\nsuggest tv.parsec.www\n")
            check("제안 파싱", r.suggestedTool == "tv.parsec.www")
            check("제안만 있어도 me 는 살아있다", r.myLang == "ko")
        }
        // 옛 데몬이 suggest 를 안 보내도, 새 데몬이 보낸 모르는 줄이 와도 깨지지 않아야 한다
        check("모르는 줄은 무시",
              parseQueryResponse("me en\nfuture x y z\n").myLang == "en")

        print("\n[원격 도구 힌트]")
        let KNOWN = Set(knownRemoteTools.map(\.bundleId))
        do {
            // 실사용 오탐(2026-08-08): 잠긴 기기 탓에 늘 어긋나 있어서 VSCode 가 6회를
            // 채우고 "원격 도구 의심"이 떴다. 아는 도구로 한정해 정밀도를 택했다.
            var t = ToolHintTracker(known: KNOWN)
            for _ in 0..<(ToolHintTracker.threshold * 3) {
                t.noteSkipped(app: "com.microsoft.VSCode", mismatched: true)
            }
            check("모르는 앱은 아무리 세도 제안하지 않는다", t.candidate == nil)
        }
        do {
            var t = ToolHintTracker(known: KNOWN)
            for _ in 0..<(ToolHintTracker.threshold - 1) {
                t.noteSkipped(app: "tv.parsec.www", mismatched: true)
            }
            check("임계값 전에는 조용하다", t.candidate == nil)
            let promoted = t.noteSkipped(app: "tv.parsec.www", mismatched: true)
            check("임계값에서 후보로", t.candidate == "tv.parsec.www")
            check("승격은 한 번만 true", promoted)
            check("이미 후보면 다시 true 아님",
                  !t.noteSkipped(app: "tv.parsec.www", mismatched: true))
        }
        do {
            // 어긋나지 않은 상태에서 세면 VSCode 같은 평범한 앱이 원격 도구로 오인된다
            var t = ToolHintTracker(known: KNOWN)
            for _ in 0..<(ToolHintTracker.threshold * 3) {
                t.noteSkipped(app: "com.microsoft.VSCode", mismatched: false)
            }
            check("일치 상태에서는 세지 않는다", t.candidate == nil)
        }
        do {
            var t = ToolHintTracker(known: KNOWN)
            for _ in 0..<(ToolHintTracker.threshold * 2) {
                t.noteSkipped(app: "com.apple.finder", mismatched: true)
            }
            check("시스템 앱은 후보가 아니다", t.candidate == nil)
        }
        do {
            var t = ToolHintTracker(dismissed: ["com.philandro.anydesk"], known: KNOWN.union(["com.philandro.anydesk"]))
            for _ in 0..<(ToolHintTracker.threshold * 2) {
                t.noteSkipped(app: "com.philandro.anydesk", mismatched: true)
            }
            check("무시한 앱은 다시 묻지 않는다", t.candidate == nil)
        }
        do {
            var t = ToolHintTracker(known: KNOWN)
            for _ in 0..<ToolHintTracker.threshold {
                t.noteSkipped(app: "com.philandro.anydesk", mismatched: true)
            }
            t.dismiss("com.philandro.anydesk")
            check("무시하면 후보 해제", t.candidate == nil)
            check("무시 목록에 남는다", t.dismissedList == ["com.philandro.anydesk"])
            for _ in 0..<(ToolHintTracker.threshold * 2) {
                t.noteSkipped(app: "com.philandro.anydesk", mismatched: true)
            }
            check("무시 후에는 다시 안 올라온다", t.candidate == nil)
        }
        do {
            var t = ToolHintTracker(known: KNOWN)
            for _ in 0..<ToolHintTracker.threshold {
                t.noteSkipped(app: "com.philandro.anydesk", mismatched: true)
            }
            t.resolve("com.philandro.anydesk")
            check("추가되면 후보 해제", t.candidate == nil)
            check("추가는 무시 목록에 넣지 않는다", t.dismissedList.isEmpty)
        }
        check("sync 인자가 틀리면 nil", parseControl(["TOK", "ctl", "sync", "maybe"]) == nil)
        check("필드 모자라면 nil", parseControl(["TOK", "ctl"]) == nil)
        check("reload", parseControl(["TOK", "ctl", "reload"]) == .reload)
        check("pair-start", parseControl(["TOK", "ctl", "pair-start", "482917"])
                            == .pairStart("482917"))
        check("pair-stop", parseControl(["TOK", "ctl", "pair-stop"]) == .pairStop)
        check("pair-start 인자 없으면 nil", parseControl(["TOK", "ctl", "pair-start"]) == nil)

        print("\n[원격 도구 목록]")
        let allInstalled: (String) -> Bool = { _ in true }
        let noneInstalled: (String) -> Bool = { _ in false }
        let jumpOnly = [RemoteTool(name: "Jump Desktop", bundleId: "com.jump", verified: true)]

        let r1 = remoteToolRows(selected: [], installed: allInstalled, known: jumpOnly)
        check("알려진 도구가 나옴", r1.map(\.bundleId) == ["com.jump"])
        check("고르지 않았으면 체크 해제", r1[0].checked == false)
        check("설치돼 있으면 installed", r1[0].installed)

        let r2 = remoteToolRows(selected: ["com.jump"], installed: allInstalled, known: jumpOnly)
        check("고른 것은 체크됨", r2[0].checked)

        let r3 = remoteToolRows(selected: [], installed: noneInstalled, known: jumpOnly)
        check("미설치는 installed=false", !r3[0].installed)

        let r4 = remoteToolRows(selected: ["com.unknown"], installed: noneInstalled, known: jumpOnly)
        check("목록에 없는 설정값은 직접추가 행으로", r4.count == 2)
        check("직접추가 행은 custom", r4[1].custom && r4[1].bundleId == "com.unknown")
        check("직접추가 행은 체크됨", r4[1].checked)
        check("직접추가는 뒤에 붙음", r4[0].bundleId == "com.jump")
        // 목록에 이름만 올려 두면 사용자는 "된다"고 읽는다 — 실측 여부를 화면까지 나른다
        check("검증 여부가 행에 전달된다", r1[0].verified)
        check("직접 추가한 앱은 검증됨이 아니다", !r4[1].verified)

        let r5 = remoteToolRows(selected: ["com.jump", "com.jump"], installed: allInstalled, known: jumpOnly)
        check("중복은 한 번만", r5.count == 1)

        print("\n[config 부분 갱신]")
        let tmp = NSTemporaryDirectory() + "macbridge-selftest-\(getpid()).json"
        try? #"{"port":8765,"ime_sync":{"enabled":true},"keep":"me"}"#
            .write(toFile: tmp, atomically: true, encoding: .utf8)

        check("갱신 성공은 nil", updateConfigFile(at: tmp) { $0["port"] = 9999 } == nil)
        let after = (try? JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: tmp)))) as? [String: Any]
        check("바꾼 값이 반영됨", (after?["port"] as? Int) == 9999)
        check("건드리지 않은 키는 보존", (after?["keep"] as? String) == "me")
        check("중첩 키도 보존", ((after?["ime_sync"] as? [String: Any])?["enabled"] as? Bool) == true)
        check("없는 파일은 사유 반환",
              updateConfigFile(at: "/nonexistent/x.json") { _ in } == "config-read-failed")
        try? FileManager.default.removeItem(atPath: tmp)

        print("\n[초대 코드]")
        check("형식대로 만든다", makeInviteCode(ip: "100.1.2.3", port: 8765, secret: "482917")
                                 == "mb1.100.1.2.3.8765.482917")
        let inv = parseInviteCode("mb1.100.1.2.3.8765.482917")
        check("IP 파싱", inv?.ip ?? "", "100.1.2.3")
        check("포트 파싱", (inv?.port).map(String.init) ?? "", "8765")
        check("시크릿 파싱", inv?.secret ?? "", "482917")
        check("공백은 무시", parseInviteCode("  mb1.100.1.2.3.8765.482917 \n")?.ip == "100.1.2.3")
        check("접두사가 다르면 nil", parseInviteCode("xx.100.1.2.3.8765.482917") == nil)
        check("시크릿이 6자리가 아니면 nil", parseInviteCode("mb1.100.1.2.3.8765.48291") == nil)
        check("시크릿이 숫자가 아니면 nil", parseInviteCode("mb1.100.1.2.3.8765.4829ab") == nil)
        check("포트가 숫자가 아니면 nil", parseInviteCode("mb1.100.1.2.3.abcd.482917") == nil)
        check("IP 가 아니면 nil", parseInviteCode("mb1.host.name.x.8765.482917") == nil)
        check("포트가 빠지면 nil (옛 형식)", parseInviteCode("mb1.100.1.2.3.482917") == nil)
        check("빈 문자열은 nil", parseInviteCode("") == nil)
        check("생성한 시크릿은 6자리 숫자", {
            let s = newPairingSecret()
            return s.count == 6 && s.allSatisfy(\.isNumber)
        }())

        print("\n[로컬 IP 우선순위]")
        let ips = ["192.168.0.5", "100.64.0.3", "10.0.0.2", "8.8.8.8", "127.0.0.1"]
        let ranked = rankLocalIPs(ips)
        check("Tailscale 이 첫째", ranked.first ?? "", "100.64.0.3")
        check("루프백은 빠짐", !ranked.contains("127.0.0.1"))
        check("사설망이 공인보다 앞", ranked.firstIndex(of: "10.0.0.2")!
                                      < ranked.firstIndex(of: "8.8.8.8")!)
        check("전부 4개", ranked.count == 4)
        check("빈 목록은 빈 목록", rankLocalIPs([]).isEmpty)

        print("\n[페어링 세션]")
        let ses = PairingSession()
        check("평소엔 닫혀 있다", !ses.isOpen(nowMs: 1_000))
        check("닫혀 있으면 어떤 시크릿도 거부",
              ses.verify("482917", nowMs: 1_000) == .closed)

        ses.open(secret: "482917", nowMs: 1_000, windowMs: 120_000)
        check("열면 열린다", ses.isOpen(nowMs: 1_000))
        check("틀린 시크릿은 거부", ses.verify("000000", nowMs: 2_000) == .wrongSecret)
        check("맞으면 통과", ses.verify("482917", nowMs: 2_000) == .ok)

        let ses2 = PairingSession()
        ses2.open(secret: "111111", nowMs: 0, windowMs: 120_000)
        check("만료되면 거부", ses2.verify("111111", nowMs: 120_001) == .expired)
        check("만료 후엔 닫힌 것으로 본다", !ses2.isOpen(nowMs: 120_001))

        let ses3 = PairingSession()
        ses3.open(secret: "222222", nowMs: 0, windowMs: 120_000)
        for _ in 0..<5 { _ = ses3.verify("999999", nowMs: 1_000) }
        check("5회 실패하면 폐기", ses3.verify("222222", nowMs: 1_000) == .closed)
        check("폐기되면 닫힘", !ses3.isOpen(nowMs: 1_000))

        let ses4 = PairingSession()
        ses4.open(secret: "333333", nowMs: 0, windowMs: 120_000)
        ses4.close()
        check("닫으면 즉시 무효", ses4.verify("333333", nowMs: 1_000) == .closed)

        print("\n[번들 판정]")
        check("앱 번들 안이면 true",
              isBundledExecutable(path: "/Applications/MacBridge.app/Contents/MacOS/macbridge"))
        check("~/bin 이면 false",
              !isBundledExecutable(path: "/Users/x/bin/macbridge"))
        check("빌드 산출물이면 false",
              !isBundledExecutable(path: "/Users/x/projects/macbridge/macbridge"))
        check(".app 이 경로 중간에 있어도 Contents/MacOS 가 아니면 false",
              !isBundledExecutable(path: "/Applications/MacBridge.app/Resources/macbridge"))
        check("빈 경로는 false", !isBundledExecutable(path: ""))

        print("\n\(passed) 통과 / \(failed) 실패")
        exit(failed == 0 ? 0 : 1)
    }
}
