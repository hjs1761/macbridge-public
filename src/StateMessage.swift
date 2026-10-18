import Foundation

/// 상대가 알려 온 자기 상태. **적용하지 않고 기록만 한다.**
struct StateMessage: Equatable {
    let deviceId: String
    let name: String
    let lang: String
    let sentMs: Int64
}

/// `<token> state <id> <name...> <lang> <ts>` 를 파싱한다.
///
/// 이름에 공백이 들어갈 수 있으므로 **뒤에서부터** ts·lang 을 떼어내고,
/// 앞에서 token·state·id 를 떼어낸 나머지를 이름으로 본다.
/// - Parameter parts: 공백으로 자른 필드 전체(0번은 토큰, 1번은 "state")
func parseStateMessage(_ parts: [String]) -> StateMessage? {
    // token, state, id, name(1개 이상), lang, ts = 최소 6개
    guard parts.count >= 6, parts[1] == "state" else { return nil }
    guard let ts = Int64(parts[parts.count - 1]) else { return nil }
    let lang = parts[parts.count - 2]
    guard ["ko", "en"].contains(lang) else { return nil }
    let id = parts[2]
    guard !id.isEmpty else { return nil }
    let name = parts[3..<(parts.count - 2)].joined(separator: " ")
    guard !name.isEmpty else { return nil }
    return StateMessage(deviceId: id, name: name, lang: lang, sentMs: ts)
}
