// macbridge — 두 대 이상의 맥 사이에서 한/영 입력 소스를 맞추고, 약속된 액션을 건네는 다리
//
// 배경: Jump Desktop(Fluid, Mac→Mac)은 클라이언트에서 조합을 끝낸 문자를 보내기 때문에
//       양쪽 입력 소스가 일치해야만 정상 입력된다(A/한=먹통, 한/A=자소분리).
//       Karabiner 로 키를 주입해 원격에 전달하려는 시도는 전부 실패했다 —
//       Jump Desktop 이 가상 키보드에서 나온 키 이벤트를 원격으로 넘기지 않기 때문.
// 접근: 키를 보내지 않는다. 로컬 입력 소스가 "바뀐 사실"을 감지해서
//       상대 맥에 알리고, 상대는 자기 입력 소스를 같은 언어로 맞춘다.
//       받는 쪽이 자기 머신에서 로컬로 실행하므로 원격 도구가 경로에 없다.
//
// 사용:
//   macbridge                      ~/.config/macbridge/config.json 대로 실행
//   macbridge --config <PATH>      다른 설정 파일로 실행
//   macbridge status               현재 입력 소스와 선택 가능한 목록
//   macbridge config               해석된 설정을 확인 (진단용)
//
//   (v0 호환) macbridge serve|watch|both --port <P> --peer <H:P> --token <T> [--only-app <ID>]
//
// 구조: 이 파일은 CLI 디스패치만 담당한다. 책임별 구현은 src/ 아래에 있다
//   (Log / Config / InputSource / Sync / Hangul / SelfTest).
//   ⚠ top-level 실행문이 있는 파일은 다중 파일 빌드에서 main.swift 여야 한다.

import Foundation
import Carbon
import AppKit

// MARK: - CLI

func argValue(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

/// 같은 플래그를 여러 번 준 경우 전부 모은다 (`--peer A --peer B`)
func argValues(_ name: String) -> [String] {
    let args = CommandLine.arguments
    var out: [String] = []
    for (i, a) in args.enumerated() where a == name && i + 1 < args.count {
        out.append(args[i + 1])
    }
    return out
}

func usage() -> Never {
    print("""
    macbridge — 맥 사이 한/영 입력 소스 동기화

      macbridge                     ~/.config/macbridge/config.json 대로 실행
      macbridge --config <PATH>     다른 설정 파일로 실행
      macbridge status              현재 입력 소스와 선택 가능한 목록
      macbridge config              해석된 설정 확인 (진단용)
      macbridge peers               연결된 기기와 IME 현황 (데몬에 질의)
      macbridge probe               자소분리 관측 창 (호스트에서 실행)
      macbridge menubar            메뉴바 상태 아이템 (데몬과 별개 프로세스)
      macbridge onboarding         「시작하기」 창 다시 열기
      macbridge settings           설정 창 단독으로 열기
      macbridge feedback           문의 창 열기
      macbridge diagnostics        문의에 첨부되는 진단 정보를 그대로 출력
      macbridge pair <코드>        연결 코드로 기존 기기에 붙기 (보통은 설정 창에서 한다)

    설정 파일 없이 쓰려면(v0 호환):
      macbridge both  --port <PORT> --peer <IP[:PORT]> --token <TOKEN> [--only-app <BUNDLEID>]
      macbridge serve --port <PORT> --token <TOKEN>
      macbridge watch --peer <IP[:PORT]> --token <TOKEN>

    --only-app : 그 앱이 최전면일 때만 상대에게 알림
                 (예: com.p5sys.jump.mac.viewer — Jump Desktop 쓸 때만 동기화)
    """)
    exit(1)
}

// ⚠ 전역에 보관해야 한다. 지역 변수로 두면 스코프를 벗어나며 ARC 가 해제해
//   타이머·옵저버가 같이 죽는다(실제로 이 버그로 감시가 전혀 동작하지 않았다).
var globalServer: SyncServer?
var globalWatcher: SyncWatcher?
var globalRefresher: InputSourceCacheRefresher?
/// 상대들이 알려 온 상태(state 메시지)의 저장소. 데몬 프로세스에만 채워진다 —
/// 별개 프로세스(CLI `peers`·`probe`)는 UDP `query` 로 데몬에게 물어서 읽는다.
let globalPeers = PeerTable()
var globalProbe: ProbeController?
var globalHotkeys: HotkeyManager?
var globalMenuBar: MenuBarController?
/// 앱 기동 시 데몬 등록이 실패했으면 그 사유. 메뉴에 그대로 보여준다.
var globalDaemonSetupError: String?

let firstArg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""

switch firstArg {
case "selftest":
    SelfTest.run()

case "status":
    print("현재 입력 소스: \(currentSourceID() ?? "?")  언어: \(currentLanguage() ?? "?")")
    print("선택 가능한 소스:")
    for src in selectableKeyboardSources() {
        print("  - \(inputSourceID(of: src) ?? "?")  [\(primaryLanguage(of: src) ?? "?")]")
    }
    exit(0)

case "config":
    let c = resolveConfig()
    print("""

    모드        : \(c.mode.rawValue)
    수신 포트   : \(c.listens ? String(c.port) : "(수신 안 함)")
    피어        : \(c.peers.isEmpty ? "(없음)" : c.peers.map(\.description).joined(separator: ", "))
    허용 발신지 : \(c.allowFrom.map(\.label).joined(separator: ", "))
    토큰        : \(String(c.token.prefix(4)))… (\(c.token.count)자)
    IME 동기화  : \(c.imeSyncEnabled ? "켬" : "끔")
    앱 한정     : \(c.onlyAppLabel)
    하트비트    : \(c.heartbeatSec > 0 ? "\(c.heartbeatSec)초마다 재확인" : "끔")
    자동복구    : \(c.autoRecover ? "켬 (자동정정 시 포커스 바운스)" : "끔 (IME 정렬만)")
    """)
    exit(0)

case "pair":
    // 헤드리스 페어링 — 설정 창 없이 코드만으로 붙는다(검증·원격 셸용).
    // ⚠ UI 와 달리 "내 IP 인가" 검사를 하지 않는다. 루프백으로 자기 자신과 붙여 보는
    //   2인 1역 시험을 막지 않기 위해서다.
    guard CommandLine.arguments.count > 2,
          let code = parseInviteCode(CommandLine.arguments[2]) else {
        print("사용법: macbridge pair mb1.<IP>.<6자리>  [--config <PATH>]")
        exit(1)
    }
    let pcfg = resolveConfig()
    switch runPairing(with: code, cfg: pcfg) {
    case .failure(let why):
        print("연결 실패 — \(why)")
        exit(1)
    case .success(let count, let failed):
        print("연결 성공 — 기기 \(count)대")
        if !failed.isEmpty { print("⚠ 인사 실패: \(failed.joined(separator: ", "))") }
        exit(0)
    }

case "peers":
    runPeersCommand(resolveConfig())

case "diagnostics":
    // 진단 번들을 표준출력으로. 문의 창이 첨부하는 것과 **같은 내용**이라,
    // 무엇이 나가는지 터미널에서도 확인할 수 있다.
    // ⚠ 로그를 끈다 — 여기선 출력이 곧 결과물이라 "설정 로드: …" 가 섞이면 안 된다.
    logSuppressed = true
    print(collectDiagnosticReport(cfg: resolveConfig()))
    exit(0)

case "feedback":
    let cfg = resolveConfig()
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    FeedbackWindowController.show(config: cfg)
    app.run()

case "settings":
    // 설정 창만 단독으로 연다. 메뉴바를 거치지 않고 확인·수정할 수 있어
    // 지원 안내("설정 → 기기 탭을 열어 주세요")에도 쓰인다.
    let cfg = resolveConfig()
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    SettingsWindowController.show(config: cfg)
    app.run()

case "onboarding":
    // 첫 실행 창을 다시 연다. 지원 문의("설치했는데 뭘 해야 하나요")에 바로 답이 되고,
    // 개발 중에 화면을 확인하는 통로이기도 하다.
    let cfg = resolveConfig()
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)   // 단독 실행이라 Dock 에 떠야 창이 앞으로 온다
    OnboardingWindowController.show(config: cfg)
    app.run()

case "menubar":
    let cfg = resolveConfig()
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let bar = MenuBarController(config: cfg)
    globalMenuBar = bar
    app.delegate = bar          // 상태 아이템은 기동 완료 후 델리게이트에서 만든다
    app.run()

case "probe":
    let cfg = resolveConfig()
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let refresher = InputSourceCacheRefresher()
    refresher.start()
    globalRefresher = refresher
    let probe = ProbeController(config: cfg)
    probe.show()
    globalProbe = probe
    log("probe 시작 — 창에 한글을 입력하세요 (자소분리 감지 시 피어 상태를 데몬에 질의해 함께 기록)")
    app.run()

case "-h", "--help", "help":
    usage()

default:
    // 🔴 앱을 더블클릭하면 **인자가 없다.** 그대로 두면 데몬으로 떠서 메뉴바가 안 나온다.
    //    번들 안 + 인자 없음 = 메뉴바로 해석한다. 터미널 실행은 지금 그대로 데몬.
    if firstArg.isEmpty, runningInsideAppBundle {
        redirectAppLogToFile()   // 앱 기록도 데몬과 같은 파일로 (「로그 보기」가 반쪽이 되지 않게)
        log("MacBridge 앱 시작 — \(Bundle.main.bundlePath)")
        let cfg = resolveConfig()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if let err = installDaemonAgentFromBundle() {
            log("!! \(err)")
            globalDaemonSetupError = err
        }
        let bar = MenuBarController(config: cfg)
        globalMenuBar = bar
        app.delegate = bar
        // 첫 실행이면 뭘 해야 하는지 알려 준다. 이 앱은 **두 대에 설치하고 연결해야** 동작하는데,
        // 아무 안내가 없으면 메뉴바 아이콘만 뜬 채로 "설치했는데 이제 뭐하지"로 끝난다.
        if !cfg.onboardingDone {
            DispatchQueue.main.async { OnboardingWindowController.show(config: cfg) }
        }
        app.run()
    }

    // 모드 이름도 플래그도 아닌 알 수 없는 인자면 사용법을 보여준다
    if !firstArg.isEmpty, !firstArg.hasPrefix("-"), Mode(rawValue: firstArg) == nil { usage() }

    let cfg = resolveConfig()

    // 로그가 무한히 자라지 않게 여기서 한 번만 자른다. 돌아가는 중에 건드리면
    // 그 순간 쓰이던 줄과 엉키므로, **기동 시점**이 유일하게 안전한 자리다.
    if rotateLogIfNeeded() { log("로그를 잘랐습니다 (앞부분 삭제)") }

    let refresher = InputSourceCacheRefresher()
    refresher.start()
    globalRefresher = refresher

    let hotkeys = HotkeyManager()
    hotkeys.register(cfg)
    globalHotkeys = hotkeys

    if cfg.listens {
        let server = SyncServer(config: cfg)
        do { try server.start() } catch { log("서버 시작 실패: \(error)"); exit(1) }
        globalServer = server
    }
    if cfg.watches {
        let watcher = SyncWatcher(config: cfg)
        watcher.start()
        globalWatcher = watcher
    }

    log("macbridge 시작 (모드: \(cfg.mode.rawValue)) — 현재 언어: \(currentLanguage() ?? "?")")

    // ⚠ 순수 CLI 프로세스(CFRunLoopRun)로 돌리면 HIToolbox 에 제대로 연결되지 않아
    //   LaunchAgent 컨텍스트에서 실제 입력 소스 변경을 전혀 감지하지 못한다(실측).
    //   NSApplication 을 accessory 모드로 띄워 GUI 앱 컨텍스트를 확보한다.
    //   (.accessory = Dock·메뉴바에 나타나지 않는 백그라운드 앱)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.run()
}
