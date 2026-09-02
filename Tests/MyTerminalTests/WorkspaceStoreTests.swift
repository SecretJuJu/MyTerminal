import Foundation
import Testing

@testable import MyTerminal

@Suite("작업 배치 저장소")
@MainActor
struct WorkspaceStoreTests {
    private func makeState(tabTitle: String) -> WorkspaceState {
        let session = UUID()
        var group = TabGroup()
        group.append(TerminalTab(session: session, title: tabTitle))

        return WorkspaceState(windows: [
            WorkspaceState.Window(
                frame: WorkspaceState.Frame(x: 10, y: 20, width: 900, height: 600),
                activeSelection: .home,
                groups: [WorkspaceState.Group(selection: .home, tabs: group)],
                sessions: [
                    WorkspaceState.Session(
                        id: session,
                        workingDirectory: "/tmp",
                        title: tabTitle
                    ),
                ]
            ),
        ])
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("myterminal-test-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("workspace.json")
    }

    @Test("저장한 배치를 그대로 읽는다")
    func flushRoundTrip() {
        // #given
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = WorkspaceStore(url: url)
        let state = makeState(tabTitle: "작업")

        // #when
        store.flush(state)
        let loaded = WorkspaceStore(url: url).load()

        // #then
        #expect(loaded == state)
    }

    @Test("저장한 적이 없거나 파일이 깨졌으면 아무것도 돌려주지 않는다")
    func loadFailsSoftly() throws {
        // #given
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // #when
        let missing = WorkspaceStore(url: url).load()

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{ not json".utf8).write(to: url)
        let broken = WorkspaceStore(url: url).load()

        // #then
        #expect(missing == nil)
        #expect(broken == nil)
    }

    @Test("잇달아 저장하면 마지막 것만 쓴다")
    func saveCoalesces() async {
        // #given
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = WorkspaceStore(url: url)

        // #when
        store.save(makeState(tabTitle: "첫 번째"))
        store.save(makeState(tabTitle: "두 번째"))
        store.save(makeState(tabTitle: "마지막"))
        try? await Task.sleep(for: .milliseconds(900))

        // #then
        let loaded = WorkspaceStore(url: url).load()
        #expect(loaded?.windows.first?.groups.first?.tabs.tabs.first?.title == "마지막")
    }

    @Test("바로 써야 할 때는 예약해 둔 저장을 버린다")
    func flushCancelsPendingSave() async {
        // #given
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = WorkspaceStore(url: url)

        // #when
        store.save(makeState(tabTitle: "예약"))
        store.flush(makeState(tabTitle: "종료 직전"))
        try? await Task.sleep(for: .milliseconds(900))

        // #then
        let loaded = WorkspaceStore(url: url).load()
        #expect(loaded?.windows.first?.groups.first?.tabs.tabs.first?.title == "종료 직전")
    }
}
