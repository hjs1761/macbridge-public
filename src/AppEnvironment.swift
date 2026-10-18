import Foundation
import AppKit

/// 이 실행파일이 `.app` 번들 안에서 돌고 있는가.
///
/// ⚠ 더블클릭은 **인자를 주지 않는다.** 그런데 인자가 없으면 지금 코드는 데몬으로 뜬다.
/// 그래서 "번들 안 + 인자 없음"을 메뉴바로 해석해야 앱이 앱답게 동작한다.
/// 터미널에서 `~/bin/macbridge` 를 인자 없이 부르면 지금처럼 데몬이다 — 기존 동작은 그대로다.
///
/// - Parameter path: 실행파일 절대 경로(`Bundle.main.executablePath` 또는 `CommandLine.arguments[0]`)
func isBundledExecutable(path: String) -> Bool {
    path.contains(".app/Contents/MacOS/")
}

/// 지금 프로세스가 번들 안인가.
var runningInsideAppBundle: Bool {
    isBundledExecutable(path: Bundle.main.executablePath ?? CommandLine.arguments.first ?? "")
}

/// 앱 모드일 때 stdout/stderr 를 데몬과 **같은 로그 파일**로 돌린다.
///
/// ⚠ LaunchAgent 는 plist 가 stdout 을 파일로 보내 주지만, `open` 으로 띄운 앱은 아니다.
/// 그대로 두면 **앱이 남긴 기록이 어디에도 없어** 메뉴의 「로그 보기」가 반쪽이 된다(실측으로 밟았다).
func redirectAppLogToFile() {
    let path = logFilePath
    try? FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true)
    freopen(path, "a", stdout)
    freopen(path, "a", stderr)
    setvbuf(stdout, nil, _IOLBF, 0)   // 줄 단위로 흘려보내 tail -f 가 바로 보이게
}

// MARK: - 앱 표기 정보

/// 하단 바·문의 메일에 찍는 버전. 번들에서 읽고, 터미널 실행처럼 번들이 없으면 `dev`.
let appVersionString: String = {
    let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    return v.map { "v\($0)" } ?? "dev"
}()

/// 문의를 받을 주소. **앱이 직접 보내지 않는다** — 메일 앱을 열어 사용자가 확인하고 보낸다.
let feedbackEmail = "hjs1761@gmail.com"

// MARK: - 데몬 LaunchAgent (앱이 관리한다)

let daemonLabel = "com.hjs.macbridge"
let menubarLabel = "com.hjs.macbridge.menubar"

private func agentPlistPath(_ label: String) -> String {
    NSString(string: "~/Library/LaunchAgents/\(label).plist").expandingTildeInPath
}

/// `launchctl` 한 번 실행. 실패해도 던지지 않고 성공 여부만 돌려준다.
@discardableResult
func launchctl(_ args: [String]) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

/// 앱이 뜰 때 한 번 부른다.
///
/// ⚠ **옛 `install.sh` 설치본과 겹치면 데몬이 둘이 되어 같은 UDP 포트를 문다.**
/// 그러면 패킷이 어디로 갈지 알 수 없다. 그래서 순서가 중요하다:
/// ① 메뉴바 에이전트는 **없앤다**(앱 자신이 메뉴바다) ② 데몬은 **번들 경로로 덮어써서** 재등록.
/// 데몬이 실행할 사본이 놓이는 곳. **번들 밖이어야 한다.**
let daemonCopyPath = NSString(string: "~/Library/Application Support/MacBridge/macbridge")
    .expandingTildeInPath

/// 번들 안 실행파일을 번들 **밖**으로 복사한다.
///
/// 🔴 **데몬을 번들 안 경로로 실행하면 `open` 이 앱을 못 띄운다**(실측).
/// macOS 가 그 데몬 프로세스를 "이 앱의 인스턴스"로 보기 때문에, 이미 실행 중이라고 판단해
/// 새 인스턴스를 만들지 않는다. 재부팅 후 데몬이 먼저 뜨면 **사용자가 앱을 영영 못 연다.**
/// 그래서 데몬은 번들 밖 사본으로 돌린다.
private func syncDaemonCopy() -> String? {
    guard let exe = Bundle.main.executablePath else { return "실행 경로를 찾지 못했습니다" }
    let dir = (daemonCopyPath as NSString).deletingLastPathComponent
    do {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // ⚠ 실행 중인 파일을 덮어쓰면 코드 서명이 깨져 다음 실행이 SIGKILL 된다.
        //   반드시 지우고 새로 복사한다(install.sh 가 밟았던 함정과 같다).
        try? FileManager.default.removeItem(atPath: daemonCopyPath)
        try FileManager.default.copyItem(atPath: exe, toPath: daemonCopyPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: daemonCopyPath)
    } catch {
        return "데몬 사본을 만들지 못했습니다: \(error.localizedDescription)"
    }
    // adhoc 재서명 — 복사만으로는 서명이 유지되지 않는 경우가 있다
    let cs = Process()
    cs.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    cs.arguments = ["-f", "-s", "-", daemonCopyPath]
    cs.standardOutput = FileHandle.nullDevice
    cs.standardError = FileHandle.nullDevice
    try? cs.run()
    cs.waitUntilExit()
    return nil
}

func installDaemonAgentFromBundle() -> String? {
    let uid = getuid()
    // 데몬은 번들 밖 사본으로 돈다 (위 주석의 `open` 문제)
    if let err = syncDaemonCopy() { return err }
    let exe = daemonCopyPath

    // ① 옛 메뉴바 에이전트 제거 — 앱이 그 역할을 한다
    launchctl(["bootout", "gui/\(uid)/\(menubarLabel)"])
    try? FileManager.default.removeItem(atPath: agentPlistPath(menubarLabel))

    // ② 데몬을 번들 경로로 재등록
    let logPath = logFilePath
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key><string>\(daemonLabel)</string>
        <key>ProgramArguments</key>
        <array>
            <string>\(exe)</string>
            <string>both</string>
        </array>
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key><true/>
        <key>StandardOutPath</key><string>\(logPath)</string>
        <key>StandardErrorPath</key><string>\(logPath)</string>
    </dict>
    </plist>
    """
    let path = agentPlistPath(daemonLabel)
    do {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try plist.write(toFile: path, atomically: true, encoding: .utf8)
    } catch {
        return "LaunchAgent 파일을 쓰지 못했습니다: \(error.localizedDescription)"
    }
    launchctl(["bootout", "gui/\(uid)/\(daemonLabel)"])
    guard launchctl(["bootstrap", "gui/\(uid)", path]) else {
        return "데몬을 등록하지 못했습니다 (launchctl bootstrap 실패)"
    }
    log("데몬 LaunchAgent 등록 — \(exe) both")
    return nil
}

/// 데몬이 실제로 등록돼 있는가(메뉴에 사유를 보여주려고 쓴다).
func daemonIsRegistered() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = ["print", "gui/\(getuid())/\(daemonLabel)"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}
