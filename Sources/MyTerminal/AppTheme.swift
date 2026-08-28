import AppKit
import GhosttyTerminal
import GhosttyTheme

/// 선택 가능한 테마 목록.
/// - 시그니처 팔레트(Nocturne/Daybreak)는 이 파일에서 직접 정의
/// - 나머지는 패키지에 번들된 iTerm2 컬렉션(GhosttyThemeCatalog)에서 이름으로 로드
enum AppTheme: String, CaseIterable {
    /// Ghostty 기본값 — 시스템 외관에 따라 Alabaster(라이트)/Afterglow(다크) 자동 전환
    case ghosttyDefault = "ghostty-default"
    /// 이 앱의 시그니처 테마 — Daybreak(라이트)/Nocturne(다크) 자동 전환
    case signature
    case catppuccinMocha = "Catppuccin Mocha"
    case tokyoNightStorm = "TokyoNight Storm"
    case dracula = "Dracula"
    case gruvboxDark = "Gruvbox Dark"
    case nord = "Nord"
    case oneHalfDark = "One Half Dark"

    var displayName: String {
        switch self {
        case .ghosttyDefault: "기본 (시스템 자동)"
        case .signature: "Signature — Nocturne / Daybreak"
        case .catppuccinMocha: "Catppuccin Mocha"
        case .tokyoNightStorm: "TokyoNight Storm"
        case .dracula: "Dracula"
        case .gruvboxDark: "Gruvbox Dark"
        case .nord: "Nord"
        case .oneHalfDark: "One Half Dark"
        }
    }

    /// 라이트/다크를 스스로 정하지 않고 시스템을 따라가는 테마인지.
    /// 이런 테마가 걸린 창은 외관을 고정하지 않는다 — 고정해 버리면
    /// 터미널까지 한쪽으로 묶여 자동 전환이 죽는다.
    var followsSystemAppearance: Bool {
        switch self {
        case .ghosttyDefault, .signature: true
        default: false
        }
    }

    func terminalTheme() -> TerminalTheme {
        switch self {
        case .ghosttyDefault:
            .default
        case .signature:
            TerminalTheme(light: .daybreak, dark: .nocturne)
        case .catppuccinMocha, .tokyoNightStorm, .dracula, .gruvboxDark, .nord, .oneHalfDark:
            GhosttyThemeCatalog.theme(named: rawValue)?.toTerminalTheme() ?? .default
        }
    }

    /// 사이드바를 터미널과 같은 색으로 칠하기 위해 꺼내는 값.
    ///
    /// `TerminalConfiguration`은 넣은 색을 다시 읽어 주지 않는다. 그래서
    /// 시그니처와 Ghostty 기본값은 아래 상수에서 직접 가져오고, 카탈로그
    /// 테마만 정의를 그대로 읽는다.
    func chrome(systemIsDark: Bool) -> ChromeColors {
        switch self {
        case .ghosttyDefault:
            ChromeColors(systemIsDark ? GhosttyDefaultHex.afterglow : GhosttyDefaultHex.alabaster)
        case .signature:
            ChromeColors(systemIsDark ? SignatureHex.nocturne : SignatureHex.daybreak)
        case .catppuccinMocha, .tokyoNightStorm, .dracula, .gruvboxDark, .nord, .oneHalfDark:
            GhosttyThemeCatalog.theme(named: rawValue).map(ChromeColors.init)
                ?? ChromeColors(GhosttyDefaultHex.afterglow)
        }
    }
}

/// 터미널 밖 화면(사이드바, 창 외관)이 쓰는 색.
struct ChromeColors {
    let background: NSColor
    let foreground: NSColor
    let selection: NSColor
    let isDark: Bool

    init(background: NSColor, foreground: NSColor, selection: NSColor, isDark: Bool) {
        self.background = background
        self.foreground = foreground
        self.selection = selection
        self.isDark = isDark
    }

    fileprivate init(_ hex: ThemeHex) {
        self.init(
            background: NSColor(hex: hex.background) ?? .windowBackgroundColor,
            foreground: NSColor(hex: hex.foreground) ?? .labelColor,
            selection: NSColor(hex: hex.selection) ?? .selectedContentBackgroundColor,
            isDark: hex.isDark
        )
    }

    fileprivate init(_ definition: GhosttyThemeDefinition) {
        self.init(
            background: NSColor(hex: definition.background) ?? .windowBackgroundColor,
            foreground: NSColor(hex: definition.foreground) ?? .labelColor,
            // 선택 색이 없는 테마는 전경색을 옅게 깔아 쓴다. 배경과 대비가
            // 나면서도 글자를 가리지 않는 값이 그것뿐이다.
            selection: definition.selectionBackground.flatMap { NSColor(hex: $0) }
                ?? (NSColor(hex: definition.foreground) ?? .labelColor)
                .withAlphaComponent(0.18),
            isDark: definition.isDark
        )
    }
}

// MARK: - 색 정의

/// 배경·전경·선택 세 색. 시그니처 팔레트와 사이드바가 같은 값을 보도록
/// 한 곳에 둔다 — 두 군데 적어 두면 언젠가 갈라진다.
private struct ThemeHex {
    let background: String
    let foreground: String
    let selection: String
    let isDark: Bool
}

private enum SignatureHex {
    static let nocturne = ThemeHex(
        background: "10151F",
        foreground: "D5DCE8",
        selection: "2A3550",
        isDark: true
    )
    static let daybreak = ThemeHex(
        background: "FAF8F5",
        foreground: "2A2A33",
        selection: "D8D4CC",
        isDark: false
    )
}

/// libghostty의 Alabaster/Afterglow 값. 패키지가 색을 되돌려 주지 않아
/// 사이드바용으로만 따로 적어 둔다. 의존성을 올릴 때 기본 테마 색이 바뀌면
/// 여기도 같이 봐야 한다.
private enum GhosttyDefaultHex {
    static let alabaster = ThemeHex(
        background: "F7F7F7",
        foreground: "000000",
        selection: "C9D0D9",
        isDark: false
    )
    static let afterglow = ThemeHex(
        background: "212121",
        foreground: "D0D0D0",
        selection: "303030",
        isDark: true
    )
}

private extension NSColor {
    /// `RRGGBB` 또는 `#RRGGBB`.
    convenience init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension TerminalConfiguration {
    /// Nocturne — 시그니처 다크 팔레트. 차분한 블루-차콜 베이스에
    /// 채도를 절제한 ANSI 컬러로 긴 세션에서 눈의 피로를 줄인다.
    static let nocturne = TerminalConfiguration { builder in
        builder.withBackground(SignatureHex.nocturne.background)
        builder.withForeground(SignatureHex.nocturne.foreground)
        builder.withCursorColor("89B4FA")
        builder.withSelectionBackground(SignatureHex.nocturne.selection)
        // Normal colors (0-7)
        builder.withPalette(0, color: "#1B2130")
        builder.withPalette(1, color: "#F7768E")
        builder.withPalette(2, color: "#9ECE6A")
        builder.withPalette(3, color: "#E0AF68")
        builder.withPalette(4, color: "#7AA2F7")
        builder.withPalette(5, color: "#BB9AF7")
        builder.withPalette(6, color: "#7DCFFF")
        builder.withPalette(7, color: "#A9B1D6")
        // Bright colors (8-15)
        builder.withPalette(8, color: "#3B4261")
        builder.withPalette(9, color: "#FF7A93")
        builder.withPalette(10, color: "#B9F2C0")
        builder.withPalette(11, color: "#FFC777")
        builder.withPalette(12, color: "#8DB0FF")
        builder.withPalette(13, color: "#D1A0F5")
        builder.withPalette(14, color: "#A6DBFF")
        builder.withPalette(15, color: "#C0CAF5")
    }

    /// Daybreak — 시그니처 라이트 팔레트. 따뜻한 오프화이트 배경에
    /// 라이트 배경에서도 대비를 유지하는 저채도 ANSI 컬러.
    static let daybreak = TerminalConfiguration { builder in
        builder.withBackground(SignatureHex.daybreak.background)
        builder.withForeground(SignatureHex.daybreak.foreground)
        builder.withCursorColor("2F5CD3")
        builder.withSelectionBackground(SignatureHex.daybreak.selection)
        // Normal colors (0-7)
        builder.withPalette(0, color: "#22242D")
        builder.withPalette(1, color: "#A13D3D")
        builder.withPalette(2, color: "#497C54")
        builder.withPalette(3, color: "#A8720F")
        builder.withPalette(4, color: "#2F5CD3")
        builder.withPalette(5, color: "#8549A8")
        builder.withPalette(6, color: "#1A7F9C")
        builder.withPalette(7, color: "#FAF8F5")
        // Bright colors (8-15)
        builder.withPalette(8, color: "#7F8490")
        builder.withPalette(9, color: "#C93B3B")
        builder.withPalette(10, color: "#3F8F4F")
        builder.withPalette(11, color: "#BF7C00")
        builder.withPalette(12, color: "#2F66D0")
        builder.withPalette(13, color: "#9B59C9")
        builder.withPalette(14, color: "#2B9AB5")
        builder.withPalette(15, color: "#FFFFFF")
    }
}
