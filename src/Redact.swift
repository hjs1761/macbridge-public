import Foundation

// MARK: - 로그에서 지워야 할 것들
//
// 🔴 2026-08-09 발견: 형식이 틀린 메시지를 받으면 **받은 줄을 통째로** 로그에 찍었고,
//    그 줄 맨 앞이 토큰이라 **평문으로 남았다**(`ctl 형식 오류 — 무시: abcd…`).
//    로그는 문의에 첨부되기도 하고 백업·동기화·화면공유로도 새어 나간다.
//    토큰이 유출되면 같은 망에서 남이 내 IME 를 바꾸고 페어링까지 할 수 있다.
//
// 진단에 필요한 건 "무슨 모양의 메시지가 왔나"이지 비밀 그 자체가 아니다.

/// 수신 원문을 로그에 남기기 전에 비밀을 지운다.
///
/// 첫 자리는 **언제나** 비밀이다(토큰 또는 페어링 시크릿). 그 밖에도 길고 무작위해 보이는
/// 값은 함께 지운다 — 나중에 메시지 형식이 늘어나도 안전한 쪽으로 남게.
func redactMessage(_ line: String) -> String {
    let parts = line.split(separator: " ").map(String.init)
    guard !parts.isEmpty else { return "(빈 줄)" }
    return parts.enumerated().map { i, p -> String in
        if i == 0 { return "<비밀 \(p.count)자>" }
        if p.count >= 16, p.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
            return "<가림 \(p.count)자>"
        }
        return p
    }.joined(separator: " ")
}

// MARK: - 진단 번들용 가리기
//
// 로그는 "버그 기록"이 아니라 **행동 기록**이다. 실측(2026-08-09): 4일치 5,131줄에
// `최전면이 com.microsoft.VSCode` 1,781건 · `com.google.Chrome` 531건 ·
// `com.kakao.KakaoTalkMac` 205건 — **언제 무슨 앱을 썼는지가 초 단위로 남는다.**
// 기기 이름엔 실명이, 로그엔 Tailscale IP 가 들어 있다.
//
// 그대로 보내는 건 사용자가 예상하는 "로그 첨부"와 많이 다르다. 그래서 가린다.

/// 진단 번들을 만들 때 쓰는 가리개. 규칙을 한곳에 모아 테스트로 고정한다.
struct DiagnosticRedactor {
    /// 지울 토큰(혹시 옛 로그에 남아 있을 수 있다)
    let token: String
    /// 실제 기기 이름 → 대체 이름. 기기 이름엔 실명이 흔하다("홍길동의 MacBook Pro").
    let deviceAliases: [String: String]
    /// **원격 도구 목록에 있는 것만 남긴다.** 진단에 필요한 건 "원격 도구가 최전면이었나"뿐이고,
    /// VSCode·카카오톡이 언제 떠 있었는지는 필요 없다. 진단 가치는 지키고 노출은 없앤다.
    let keepBundleIds: Set<String>
    /// 홈 디렉터리 경로. `/Users/<계정명>/…` 에 **계정명(대개 실명)** 이 그대로 들어간다 —
    /// 로그의 "설정 로드: /Users/…" 한 줄만으로 이름이 새어 나간다(2026-08-09 실측으로 발견).
    var homePath: String = NSHomeDirectory()

    /// 역DNS 모양의 앱 번들 ID (`tv.parsec.www`, `com.apple.ScreenSharing`).
    /// 첫 글자를 **문자로 못 박아** IP(숫자로 시작)와 겹치지 않게 한다.
    private static let bundleIdPattern = try? NSRegularExpression(
        pattern: "[A-Za-z][A-Za-z0-9-]*(?:\\.[A-Za-z0-9-]+){2,}")
    /// IPv4
    private static let ipPattern = try? NSRegularExpression(
        pattern: "\\b(\\d{1,3}\\.\\d{1,3}\\.\\d{1,3})\\.\\d{1,3}\\b")

    func line(_ s: String) -> String {
        var out = s
        // ① 토큰 — 있으면 통째로
        if token.count >= 8 { out = out.replacingOccurrences(of: token, with: "<토큰 지움>") }
        // ②' 홈 경로 — 기기 이름보다 **먼저** 지운다. 경로 안에 계정명이 박혀 있어서
        //     기기 이름 치환이 경로 일부만 건드리면 어중간하게 남는다.
        if homePath.count > 3 { out = out.replacingOccurrences(of: homePath, with: "~") }
        // ② 기기 이름 — 긴 이름부터 바꿔야 부분 일치로 깨지지 않는다
        for (real, alias) in deviceAliases.sorted(by: { $0.key.count > $1.key.count })
        where !real.isEmpty {
            out = out.replacingOccurrences(of: real, with: alias)
        }
        // ③ 앱 번들 ID — 아는 원격 도구만 남긴다
        out = Self.replaceAll(Self.bundleIdPattern, in: out) { m in
            keepBundleIds.contains(m) ? m : "(다른 앱)"
        }
        // ④ IP — 마지막 옥텟만 가린다. 대역은 진단에 쓰이므로(tailscale/lan 구분) 남긴다
        out = Self.replaceAll(Self.ipPattern, in: out) { m in
            guard let cut = m.lastIndex(of: ".") else { return m }
            return m[..<cut] + ".***"
        }
        return out
    }

    private static func replaceAll(_ re: NSRegularExpression?, in s: String,
                                   _ transform: (String) -> String) -> String {
        guard let re else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += transform(ns.substring(with: m.range))
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}

/// 기기 이름을 대체 이름으로 바꾸는 표를 만든다. 내 기기는 "이 기기", 나머지는 기기2·기기3…
func makeDeviceAliases(myName: String, peerNames: [String]) -> [String: String] {
    var map: [String: String] = [:]
    if !myName.isEmpty { map[myName] = "이 기기" }
    for (i, n) in peerNames.enumerated() where !n.isEmpty && map[n] == nil {
        map[n] = "기기\(i + 2)"
    }
    return map
}

// MARK: - 로그에서 최근 구간만 뽑기

/// `[2026-08-09 00:44:00.179] …` 앞머리에서 시각을 읽는다. 형식이 아니면 nil.
func logLineTimestamp(_ line: String, formatter: DateFormatter) -> Date? {
    guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
    let stamp = String(line[line.index(after: line.startIndex)..<close])
    return formatter.date(from: stamp)
}

/// 로그 파서용 포매터. 로그를 찍는 쪽과 같은 형식이어야 한다.
func makeLogTimestampFormatter() -> DateFormatter {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}

/// 최근 `hours` 시간 안의 줄만 남긴다. 단 `maxLines` 를 넘으면 **뒤에서** 잘라 상한을 지킨다.
///
/// 시간 기준으로 뽑는 이유 — 줄 수로 자르면 조용한 하루와 바쁜 하루의 범위가 완전히 달라져
/// "언제부터의 기록인가"를 말할 수 없다. 상한은 폭주했을 때의 안전장치다.
func recentLogLines(_ lines: [String], now: Date, hours: Double, maxLines: Int,
                    formatter: DateFormatter) -> [String] {
    let cutoff = now.addingTimeInterval(-hours * 3600)
    var kept: [String] = []
    // 시각이 없는 줄(여러 줄로 이어진 기록 등)은 **직전 줄의 판정을 따른다**
    var lastKept = false
    for l in lines {
        if let t = logLineTimestamp(l, formatter: formatter) {
            lastKept = t >= cutoff
        }
        if lastKept { kept.append(l) }
    }
    return kept.count > maxLines ? Array(kept.suffix(maxLines)) : kept
}
