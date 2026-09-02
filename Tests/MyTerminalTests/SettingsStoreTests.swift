import Foundation
import Testing

@testable import MyTerminal

@Suite("앱 설정 저장소")
@MainActor
struct SettingsStoreTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("myterminal-settings-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    @Test("저장한 테마와 폰트 크기를 그대로 읽는다")
    func roundTrip() {
        // #given
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let settings = AppSettings(theme: AppTheme.dracula.rawValue, fontSize: 16)

        // #when
        SettingsStore(url: url).save(settings)
        let loaded = SettingsStore(url: url).load()

        // #then
        #expect(loaded == settings)
        #expect(loaded?.resolvedTheme() == .dracula)
    }

    @Test("저장한 적이 없거나 파일이 깨졌으면 아무것도 돌려주지 않는다")
    func loadFailsSoftly() throws {
        // #given
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // #when
        let missing = SettingsStore(url: url).load()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("설정이 아님".utf8).write(to: url)
        let broken = SettingsStore(url: url).load()

        // #then
        #expect(missing == nil)
        #expect(broken == nil)
    }

    @Test("모르는 테마 이름은 기본 테마로 떨어진다")
    func unknownThemeFallsBack() {
        // #given
        let settings = AppSettings(theme: "없는 테마", fontSize: 13)

        // #when
        let theme = settings.resolvedTheme()

        // #then
        #expect(theme == .ghosttyDefault)
    }

    @Test("말이 안 되는 폰트 크기는 범위 안으로 되돌린다")
    func fontSizeIsClamped() {
        // #given
        let tooBig = AppSettings(theme: AppTheme.nord.rawValue, fontSize: 400)
        let tooSmall = AppSettings(theme: AppTheme.nord.rawValue, fontSize: 1)
        let broken = AppSettings(theme: AppTheme.nord.rawValue, fontSize: .nan)

        // #when
        let sizes = [tooBig, tooSmall, broken].map {
            $0.resolvedFontSize(minimum: 9, maximum: 28, fallback: 13)
        }

        // #then
        #expect(sizes == [28, 9, 13])
    }
}
