import Foundation
import Testing

@testable import MyTerminal

@Suite("세션 화면 기록")
@MainActor
struct SessionSnapshotStoreTests {
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("myterminal-snapshots-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("남긴 화면을 다시 읽을 수 있고, 없으면 경로도 없다")
    func writeThenPath() throws {
        // #given
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionSnapshotStore(root: root)
        let id = UUID()

        // #when
        let before = store.path(for: id)
        store.write("$ ls\nSources  README.md", for: id)
        let after = store.path(for: id)

        // #then
        #expect(before == nil)
        let path = try #require(after)
        let saved = try String(contentsOfFile: path, encoding: .utf8)
        #expect(saved.contains("Sources  README.md"))
        // 새 셸의 출력과 눈으로 가를 수 있게 구분선이 앞에 붙는다.
        #expect(saved.contains("이전 세션"))
    }

    @Test("빈 화면은 남기지 않고, 남아 있던 기록도 치운다")
    func emptySnapshotDiscards() {
        // #given
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionSnapshotStore(root: root)
        let id = UUID()
        store.write("무언가", for: id)

        // #when
        store.write("   \n  \n", for: id)

        // #then
        #expect(store.path(for: id) == nil)
    }

    @Test("줄 수 상한을 넘으면 뒤쪽만 남는다")
    func tailKeepsLastLines() {
        // #given
        let text = (1 ... 100).map { "line \($0)" }.joined(separator: "\n")

        // #when
        let tail = SessionSnapshotStore.tail(of: text, maxLines: 3, maxBytes: 1_000_000)

        // #then
        #expect(tail == "line 98\nline 99\nline 100")
    }

    @Test("한 줄이 아주 길면 바이트 상한이 먼저 걸린다")
    func tailKeepsByteBudget() {
        // #given
        let text = ["앞줄", String(repeating: "x", count: 500), "끝줄"].joined(separator: "\n")

        // #when
        let tail = SessionSnapshotStore.tail(of: text, maxLines: 100, maxBytes: 60)

        // #then
        #expect(tail == "끝줄")
    }

    @Test("배치에 없는 pane의 기록은 앱을 켤 때 치운다")
    func discardsOrphans() {
        // #given
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionSnapshotStore(root: root)
        let live = UUID()
        let gone = UUID()
        store.write("살아 있는 탭", for: live)
        store.write("닫은 탭", for: gone)

        // #when
        store.discardOrphans(keeping: [live])

        // #then
        #expect(store.path(for: live) != nil)
        #expect(store.path(for: gone) == nil)
    }

    @Test("모르는 셸이면 되찍기를 포기한다 — 셸을 망가뜨리는 것보다 낫다")
    func onlyKnownShellsWrap() {
        // #given
        let supported = ["/bin/zsh", "/opt/homebrew/bin/fish", "/bin/bash"]
        let unsupported = ["/usr/local/bin/nu", "/bin/false", "", nil]

        // #when
        let resolved = supported.map { LoginShell.resolve(path: $0)?.integration }
        let rejected = unsupported.map { LoginShell.resolve(path: $0) }

        // #then
        #expect(resolved == ["zsh", "fish", "bash"])
        #expect(rejected.allSatisfy { $0 == nil })
    }
}
