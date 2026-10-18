import Foundation
import AppKit

/// 설정 창의 「원격 도구」 목록에 미리 넣어 두는 도구들.
///
/// ⚠ **Chrome 원격 데스크톱은 일부러 뺐다.** 웹앱이라 번들 ID 가 `com.google.Chrome` 이고,
/// 체크하면 **평소 브라우징 중에도 동기화가 걸린다.** 자동감지로 잡히면 그때 경고한다.
struct RemoteTool: Equatable {
    let name: String
    let bundleId: String
    /// **실제로 두 대를 붙여 확인했는가.** 목록에 이름만 올려 두면 사용자는 "된다"고 읽는다 —
    /// 원리상 동작할 것과 실측한 것은 다르므로 화면에서 구분해 준다.
    let verified: Bool
}

let knownRemoteTools: [RemoteTool] = [
    // 2026-08-08 맥북↔집미니 실측. 전송 방식이 서로 다른 셋이라 표본으로 충분하다.
    RemoteTool(name: "Jump Desktop",              bundleId: "com.p5sys.jump.mac.viewer", verified: true),
    RemoteTool(name: "화면 공유 (macOS 기본)",      bundleId: "com.apple.ScreenSharing",   verified: true),
    RemoteTool(name: "Parsec",                    bundleId: "tv.parsec.www",             verified: true),
    // 아래는 원리상 동작하지만 **아직 확인하지 않았다.**
    RemoteTool(name: "Microsoft Remote Desktop",  bundleId: "com.microsoft.rdc.macos",   verified: false),
    RemoteTool(name: "AnyDesk",                   bundleId: "com.philandro.anydesk",     verified: false),
    RemoteTool(name: "TeamViewer",                bundleId: "com.teamviewer.TeamViewer", verified: false),
    RemoteTool(name: "RustDesk",                  bundleId: "com.carriez.rustdesk",      verified: false),
    RemoteTool(name: "VNC Viewer",                bundleId: "com.realvnc.vncviewer",     verified: false),
]

/// 목록에 그릴 한 줄.
struct RemoteToolRow: Equatable {
    let name: String
    let bundleId: String
    let checked: Bool
    let installed: Bool
    /// 알려진 목록에 없는데 config 에 들어 있던 것 — **조용히 버리지 않고** 그대로 보여준다.
    let custom: Bool
    /// 실측으로 확인된 도구인가. 직접 추가한 것은 알 수 없으므로 false.
    let verified: Bool
}

/// 알려진 목록과 현재 설정을 합쳐 화면에 그릴 줄들을 만든다.
/// - Parameters:
///   - selected: `ime_sync.only_app` 의 현재 값
///   - installed: 번들 ID 가 이 기기에 설치돼 있는지 판정(테스트에서 주입할 수 있게 클로저)
func remoteToolRows(selected: [String],
                    installed: (String) -> Bool,
                    known: [RemoteTool] = knownRemoteTools) -> [RemoteToolRow] {
    let chosen = Set(selected)
    var rows = known.map {
        RemoteToolRow(name: $0.name, bundleId: $0.bundleId,
                      checked: chosen.contains($0.bundleId),
                      installed: installed($0.bundleId), custom: false,
                      verified: $0.verified)
    }
    let knownIds = Set(known.map(\.bundleId))
    var seen = Set<String>()
    for id in selected where !knownIds.contains(id) && seen.insert(id).inserted {
        rows.append(RemoteToolRow(name: id, bundleId: id, checked: true,
                                  installed: installed(id), custom: true,
                                  verified: false))
    }
    return rows
}

/// 이 기기에 그 앱이 설치돼 있는가.
func isAppInstalled(_ bundleId: String) -> Bool {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil
}
