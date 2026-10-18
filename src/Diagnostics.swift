import Foundation
import AppKit

// MARK: - 진단 번들
//
// 문의에 첨부할 텍스트 한 장. **로그 원본이 아니다.**
//
// 담는 원칙:
//  · 연결 코드(토큰)는 **절대** 담지 않는다 — 유출되면 남이 내 IME 를 바꾸고 페어링까지 한다
//  · 기기 이름은 대체 이름으로 (실명이 흔하다)
//  · IP 는 마지막 옥텟만 가린다 (대역은 tailscale/lan 진단에 쓰인다)
//  · 앱 번들 ID 는 **원격 도구만** 남긴다 — 나머지는 사생활이지 진단이 아니다
//  · 로그는 최근 구간만
//
// 그리고 **보내기 전에 사용자에게 그대로 보여준다.** 무엇을 보내는지 모르고 보내는 게
// 제일 나쁘다 — 이 제품은 "외부로 아무것도 안 보낸다"를 신뢰의 근거로 팔고 있다.

struct DiagnosticOptions {
    var hours: Double = 24
    var maxLines: Int = 2_000
    var includeLog: Bool = true
}

/// 진단 텍스트를 조립한다. 바깥 세계(파일·시스템)를 인자로 받아 **테스트가 붙게** 한다.
func buildDiagnosticReport(cfg: Config,
                           snapshot: QueryResult?,
                           now: Date,
                           rawLogLines: [String],
                           options: DiagnosticOptions,
                           appVersion: String,
                           systemVersion: String,
                           daemonRegistered: Bool,
                           formatter: DateFormatter) -> String {
    let peers = snapshot?.peers ?? []
    let redactor = DiagnosticRedactor(
        token: cfg.token,
        deviceAliases: makeDeviceAliases(myName: cfg.deviceName, peerNames: peers.map(\.name)),
        keepBundleIds: Set(knownRemoteTools.map(\.bundleId)).union(cfg.onlyApps))
    let alias = makeDeviceAliases(myName: cfg.deviceName, peerNames: peers.map(\.name))

    var out: [String] = []
    out.append("macbridge 진단 정보")
    out.append("생성: \(formatter.string(from: now))")
    out.append("")
    out.append("[앱]")
    out.append("버전: \(appVersion)")
    out.append("데몬 등록: \(daemonRegistered ? "예" : "아니오")")
    out.append("데몬 응답: \(snapshot == nil ? "없음" : "정상")")
    out.append("")
    out.append("[시스템]")
    out.append("macOS: \(systemVersion)")
    out.append("")
    out.append("[설정]  ※ 연결 코드는 담지 않습니다")
    out.append("모드: \(cfg.mode.rawValue) · 포트: \(cfg.port)")
    out.append("허용 대역: \(cfg.allowFrom.map(\.label).joined(separator: ", "))")
    out.append("한/영 동기화: \(cfg.imeSyncEnabled ? "켬" : "끔")"
               + " · 자동복구: \(cfg.autoRecover ? "켬" : "끔")"
               + " · 복구 창: \(cfg.recoveryWindowMs)ms")
    out.append("원격 도구: \(cfg.onlyAppLabel)")
    out.append("")
    out.append("[연결된 기기]")
    out.append("\(alias[cfg.deviceName] ?? "이 기기") — \(snapshot?.myLang ?? "?") (나)")
    if peers.isEmpty {
        out.append("(없음)")
    } else {
        for p in peers {
            let name = alias[p.name] ?? p.name
            let state = p.isOnline
                ? "\(p.lang) · \(String(format: "%.1f초 전", Double(p.agoMs) / 1000))"
                : "오프라인"
            out.append("\(name) — \(state) · \(redactor.line(p.ip))")
        }
    }

    if options.includeLog {
        let recent = recentLogLines(rawLogLines, now: now, hours: options.hours,
                                    maxLines: options.maxLines, formatter: formatter)
        out.append("")
        out.append("[최근 로그 \(Int(options.hours))시간 · \(recent.count)줄]"
                   + "  ※ 기기 이름·IP·앱 이름을 가렸습니다")
        out.append(contentsOf: recent.map(redactor.line))
    } else {
        out.append("")
        out.append("[로그] 첨부하지 않음 (사용자가 껐습니다)")
    }
    return out.joined(separator: "\n") + "\n"
}

/// 실제 파일·시스템을 읽어 진단 텍스트를 만든다.
func collectDiagnosticReport(cfg: Config, options: DiagnosticOptions = .init()) -> String {
    let raw = (try? String(contentsOfFile: logFilePath, encoding: .utf8)) ?? ""
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    return buildDiagnosticReport(
        cfg: cfg,
        snapshot: queryDaemon(cfg, timeout: 0.7),
        now: Date(),
        rawLogLines: lines,
        options: options,
        appVersion: appVersionString,
        systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        daemonRegistered: daemonIsRegistered(),
        formatter: makeLogTimestampFormatter())
}

/// 진단 텍스트를 임시 파일로 떨군다. 메일 첨부와 「저장」이 같은 파일을 쓴다.
/// - Returns: 만든 파일 경로. 실패하면 nil.
func writeDiagnosticFile(_ text: String, now: Date = Date()) -> URL? {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmm"
    f.locale = Locale(identifier: "en_US_POSIX")
    let name = "macbridge-진단-\(f.string(from: now)).txt"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    do {
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    } catch {
        return nil
    }
}
