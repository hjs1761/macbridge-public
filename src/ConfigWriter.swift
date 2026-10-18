import Foundation

/// `config.json` 의 **일부만** 갱신한다.
///
/// ⚠ 파일 전체를 새로 만들지 않는다 — 사용자가 손으로 넣은 키를 지우면 안 된다.
/// ⚠ 데몬(`ctl sync`)과 설정 창이 둘 다 쓰므로 **양쪽 모두 읽기-수정-쓰기**여야
///   서로의 변경을 덮어쓰지 않는다.
/// `.sortedKeys` 를 쓰는 이유: 딕셔너리는 순서가 없어 그냥 쓰면 매번 키 순서가 달라져 diff 가 시끄럽다.
///
/// - Returns: 성공이면 `nil`, 실패면 사유 문자열
func updateConfigFile(at path: String = argValue("--config") ?? defaultConfigPath,
                      _ mutate: (inout [String: Any]) -> Void) -> String? {
    guard let data = FileManager.default.contents(atPath: path),
          var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        return "config-read-failed"
    }
    mutate(&root)
    guard let out = try? JSONSerialization.data(
        withJSONObject: root,
        options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]) else {
        return "config-encode-failed"
    }
    do {
        try out.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return nil
    } catch {
        return "config-write-failed"
    }
}

/// `ime_sync` 하위 키 하나를 갱신하는 지름길. 설정 창과 `ctl sync` 가 함께 쓴다.
func updateImeSyncKey(_ key: String, _ value: Any) -> String? {
    updateConfigFile { root in
        var ime = root["ime_sync"] as? [String: Any] ?? [:]
        ime[key] = value
        root["ime_sync"] = ime
    }
}

/// `peers` 에 호스트 하나를 더해 파일에 남긴다(이미 있으면 아무것도 하지 않는다).
func persistPeerAdd(_ host: String) -> String? {
    updateConfigFile { root in
        var peers = root["peers"] as? [String] ?? []
        // "IP" 든 "IP:PORT" 든 호스트가 같으면 중복으로 본다
        let hosts = peers.map { $0.split(separator: ":").first.map(String.init) ?? $0 }
        guard !hosts.contains(host) else { return }
        peers.append(host)
        root["peers"] = peers
    }
}
