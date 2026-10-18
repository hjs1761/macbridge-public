import Foundation

// MARK: - 로그

/// 로그 파일 위치. **한곳에서만 정의한다** — 예전엔 다섯 군데에 문자열이 흩어져 있었고,
/// 진단 번들처럼 새로 읽는 곳이 생길 때마다 어긋날 여지가 됐다.
let logFilePath = NSString(string: "~/Library/Logs/macbridge.log").expandingTildeInPath

/// ⚠ 로케일을 POSIX 로 못 박는다. 이 시각은 사람이 읽기도 하지만 **진단 번들이 다시 파싱**한다 —
/// 사용자 로케일에 따라 숫자 표기가 달라지면 "최근 N시간"을 못 뽑는다.
let logDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"   // 지연 분석을 위해 밀리초까지
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

/// epoch 밀리초 — 송·수신 구간 지연 측정용
func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

/// **출력이 곧 결과물**인 CLI 명령(`diagnostics`)에서 켠다.
/// 로그가 섞이면 진단 파일 첫 줄에 "설정 로드: …" 가 끼어 내용이 오염된다.
nonisolated(unsafe) var logSuppressed = false

func log(_ msg: String) {
    guard !logSuppressed else { return }
    print("[\(logDateFormatter.string(from: Date()))] \(msg)")
    fflush(stdout)
}

// MARK: - 회전

/// 로그가 무한히 자라지 않게 앞부분을 버린다.
///
/// 실측(2026-08-09): 4일에 506KB · 5,131줄. 그대로 두면 한 달에 4MB 가까이 되고, 오래 쓰면
/// 진단 번들을 만들 때 통째로 읽는 비용도 커진다. LaunchAgent 가 파일을 **append 로** 열어
/// 두므로, 내용을 줄여 다시 써도 이후 기록은 새 끝에 붙는다.
///
/// **데몬이 뜰 때 한 번만** 부른다 — 돌아가는 중에 건드리면 그 순간 쓰이던 줄과 엉킬 수 있다.
@discardableResult
func rotateLogIfNeeded(path: String = logFilePath,
                       maxBytes: Int = 2_000_000,
                       keepLines: Int = 4_000) -> Bool {
    let fm = FileManager.default
    guard let attrs = try? fm.attributesOfItem(atPath: path),
          let size = attrs[.size] as? Int, size > maxBytes,
          let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }

    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard lines.count > keepLines else { return false }
    let kept = lines.suffix(keepLines)
    let header = "[\(logDateFormatter.string(from: Date()))] "
        + "--- 로그가 길어져 앞부분 \(lines.count - keepLines)줄을 버렸습니다 ---"
    let out = ([header] + kept).joined(separator: "\n") + "\n"
    guard (try? out.write(toFile: path, atomically: false, encoding: .utf8)) != nil else {
        return false
    }
    return true
}
