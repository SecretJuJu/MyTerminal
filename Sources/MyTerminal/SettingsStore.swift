import Foundation

/// 다음 실행까지 들고 갈 앱 설정.
///
/// 테마 이름은 `AppTheme`의 원시값 그대로 적는다. 카탈로그 테마는 그 값이
/// 곧 iTerm2 컬렉션의 이름이라, 파일을 열어 보면 무엇이 걸려 있는지 읽힌다.
struct AppSettings: Codable, Hashable, Sendable {
    var theme: String
    var fontSize: Float
    /// 입력 상자를 쓸지. 이 설정이 없던 시절의 파일도 읽히도록 옵션이다.
    var composerEnabled: Bool?

    /// 모르는 이름이면 기본 테마로 떨어뜨린다. 테마 case 이름을 바꾸거나
    /// 사용자가 파일을 손댔을 때 앱이 뜨지 못하면 안 된다.
    func resolvedTheme() -> AppTheme {
        AppTheme(rawValue: theme) ?? .ghosttyDefault
    }

    func resolvedFontSize(minimum: Float, maximum: Float, fallback: Float) -> Float {
        guard fontSize.isFinite, fontSize > 0 else { return fallback }
        return min(max(fontSize, minimum), maximum)
    }
}

@MainActor
final class SettingsStore {
    private let url: URL

    init(url: URL = SettingsStore.defaultURL) {
        self.url = url
    }

    nonisolated static var defaultURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.local.myterminal", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    func load() -> AppSettings? {
        guard
            let data = try? Data(contentsOf: url),
            let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return nil }
        return settings
    }

    func save(_ settings: AppSettings) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: url, options: .atomic)
        } catch {
            Log.info("settings save failed — \(error.localizedDescription)")
        }
    }
}
