import Foundation
import ServiceManagement

/// 로그인 시 자동 시작. `.app` 으로 설치했을 때만 의미가 있다
/// (터미널 설치본은 LaunchAgent 가 그 일을 한다).
enum LoginItem {
    static var isSupported: Bool { runningInsideAppBundle }

    static var isEnabled: Bool {
        guard isSupported else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// - Returns: 성공이면 nil, 실패면 사유
    static func set(_ on: Bool) -> String? {
        guard isSupported else { return "앱으로 설치했을 때만 쓸 수 있습니다" }
        do {
            if on { try SMAppService.mainApp.register() }
            else  { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
