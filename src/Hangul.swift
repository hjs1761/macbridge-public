import Foundation

/// 조합되지 않은 낱자(호환 자모)의 개수.
///
/// 정상 조합된 한글은 U+AC00…U+D7A3 이고, `ㄷ`·`ㅏ` 같은 낱자는
/// 호환 자모 영역 U+3131…U+318E 에 있다. 낱자가 섞여 있으면 자소분리다.
func detachedJamoCount(_ s: String) -> Int {
    s.unicodeScalars.reduce(0) { acc, u in
        (0x3131...0x318E).contains(Int(u.value)) ? acc + 1 : acc
    }
}

/// 자소분리 여부
func isJamoDetached(_ s: String) -> Bool { detachedJamoCount(s) > 0 }
