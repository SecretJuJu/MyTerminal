import AppKit
import GhosttyTerminal

/// 한글 등 비라틴 언어 렌더링 최적화.
///
/// - 기본 모노폰트: 설치된 폰트 중 선호 순서로 자동 선택 (없으면 Menlo)
/// - 한글 전용 폰트 매핑 (`font-codepoint-map`): 한글 코딩 폰트가 깔려 있을
///   때만 건다. 자모·호환 자모·완성형·전각 기호까지 폭과 서체가 일관되게
///   나오지만, 아무 폰트나 매핑하면 오히려 망가진다 — `fitsCellGrid` 참고
/// - `font-thicken`: macOS에서 CJK 획이 얇게 렌더링되는 것을 보정해 가독성 확보
enum FontPreferences {
    private static let monoCandidates = [
        "JetBrains Mono",
        "JetBrainsMono Nerd Font",
        "MonoplexKR Nerd",
        "Maple Mono NF",
        "Sarasa Term K",
        "FiraCode Nerd Font",
        "D2Coding",
        "Menlo",
    ]

    /// 매핑을 걸어도 되는 한글 코딩 폰트. 전부 한글 한 글자가 라틴 두 글자
    /// 폭으로 설계돼 있다. Apple SD Gothic Neo 같은 가변폭 UI 폰트는 여기
    /// 넣지 않는다 — 없으면 매핑을 걸지 않고 CoreText 폴백에 맡기는 편이
    /// 낫고, 그 폴백이 어차피 SD Gothic Neo다.
    ///
    /// 이름은 배포판마다 다르게 등록된다(D2Coding은 설치 경로에 따라
    /// `D2Coding`/`D2CodingLigature`, Sarasa는 폭 방식마다 Mono/Term/Fixed로
    /// 갈린다). 그래서 같은 폰트라도 알려진 이름을 모두 적어 둔다.
    private static let hangulCandidates = [
        "D2Coding",
        "D2CodingLigature",
        "D2Coding ligature",
        "MonoplexKR",
        "MonoplexKR Nerd",
        "Sarasa Mono K",
        "Sarasa Term K",
        "Sarasa Fixed K",
        "Sarasa Gothic K",
        "Noto Sans Mono CJK KR",
        "NanumGothicCoding",
        "Nanum Gothic Coding",
    ]

    /// 하나도 없을 때 로그에 남길 안내. 자동 설치는 하지 않는다 — 사용자의
    /// 시스템에 폰트를 얹는 일까지 앱이 대신할 자리는 아니다.
    private static let installHint = "brew install --cask font-d2coding"

    /// 한글 + 전각 문자 전용으로 매핑할 유니코드 범위.
    /// Ghostty 범위의 양쪽 끝은 모두 `U+` 접두사가 필요하다.
    private static let hangulCodepointRanges = [
        "U+1100-U+11FF", // Hangul Jamo (초성/중성/종성 조합)
        "U+3130-U+318F", // Compatibility Jamo (ㄱㄴㄷ…)
        "U+A960-U+A97F", // Hangul Extended-A
        "U+AC00-U+D7AF", // 한글 음절 (가…힣)
        "U+D7B0-U+D7FF", // Hangul Extended-B
        "U+FF00-U+FFEF", // 전각 형식 (CJK 문장부호·전각 영숫자)
    ]

    /// 터미널이 쓰는 기본 모노폰트. 입력 상자도 같은 것을 써야 글자 폭이
    /// 터미널과 어긋나지 않는다.
    static func monoFamily() -> String {
        let families = Set(NSFontManager.shared.availableFontFamilies)
        return monoCandidates.first { families.contains($0) } ?? "Menlo"
    }

    static func apply(to builder: inout TerminalConfiguration.Builder) {
        let families = Set(NSFontManager.shared.availableFontFamilies)

        let mono = monoFamily()
        builder.withFontFamily(mono)

        let hangul = hangulCandidates.first {
            families.contains($0) && fitsCellGrid($0, alongside: mono)
        }
        if let hangul {
            for range in hangulCodepointRanges {
                builder.withCustom("font-codepoint-map", "\(range)=\(hangul)")
            }
        }

        builder.withFontThicken(true)

        Log.info("font: \(mono), hangul map: \(hangul ?? "system fallback")")
        if hangul == nil {
            // 폴백(Apple SD Gothic Neo)은 한글 한 글자가 라틴 두 칸보다 좁아
            // 한글이 섞인 줄에서 열이 어긋난다. 코딩용 한글 폰트를 깔면 사라진다.
            Log.info("hangul: 한글 코딩 폰트가 없어 열이 어긋날 수 있습니다 — \(installHint)")
        }
    }

    /// 한글 한 글자가 기본 폰트의 정확히 두 칸을 차지하는지 본다.
    ///
    /// 어긋나면 Ghostty가 글리프를 칸에 맞춰 늘리고, 그러면 바로 옆에 붙은
    /// 라틴 문자보다 한글만 눈에 띄게 커진다. Menlo(한 칸 7.83pt)에 Apple SD
    /// Gothic Neo(‘가’ 11.25pt)를 매핑하면 15.65/11.25 = 1.39배로 부푸는 식이다.
    /// 매핑을 걸지 않으면 CoreText가 자기 방식대로 폴백하므로 그런 일이 없다.
    private static func fitsCellGrid(_ hangul: String, alongside mono: String) -> Bool {
        // 폭의 비만 보므로 어떤 크기로 재든 결과는 같다.
        let size: CGFloat = 16
        guard
            let monoFont = NSFont(name: mono, size: size),
            let hangulFont = NSFont(name: hangul, size: size)
        else { return false }

        return fitsCellGrid(
            hangulWidth: ("가" as NSString).size(withAttributes: [.font: hangulFont]).width,
            cellWidth: ("M" as NSString).size(withAttributes: [.font: monoFont]).width
        )
    }

    /// 판정만 떼어 둔 자리. 설치된 폰트에 기대지 않고 검증할 수 있다.
    static func fitsCellGrid(hangulWidth: CGFloat, cellWidth: CGFloat) -> Bool {
        guard cellWidth > 0, hangulWidth > 0 else { return false }
        return abs(hangulWidth - cellWidth * 2) <= cellWidth * 0.05
    }
}
