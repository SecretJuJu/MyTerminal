import Foundation

/// 재시작 후 되살릴 창·탭·분할 배치.
///
/// 셸은 담기지 않는다. 여기 있는 것은 "무엇이 어디에 있었는지"뿐이고, 화면에
/// 남아 있던 글자는 `SessionSnapshotStore`가 따로 맡는다.
struct WorkspaceState: Codable, Hashable, Sendable {
    var windows: [Window] = []

    struct Window: Codable, Hashable, Sendable {
        var frame: Frame
        var activeSelection: SidebarSelection
        var groups: [Group]
        var sessions: [Session]
    }

    /// 사이드바 선택 하나와 거기 딸린 탭들. 사전 대신 배열로 두는 이유는
    /// 열거형 키를 가진 사전이 JSON에서 배열로 풀려 사람이 읽기 어렵기 때문이다.
    struct Group: Codable, Hashable, Sendable {
        var selection: SidebarSelection
        var tabs: TabGroup
    }

    /// 셸을 다시 띄울 때 필요한 것만. 아이디를 그대로 살려야 화면 스냅샷이
    /// 같은 pane으로 돌아간다.
    struct Session: Codable, Hashable, Sendable {
        var id: UUID
        var workingDirectory: String?
        var title: String
    }

    struct Frame: Codable, Hashable, Sendable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }
}

/// 배치를 디스크에 남기는 자리.
///
/// `ProjectStore`와 같은 모양을 따른다 — 경로를 주입할 수 있고, 쓸 때는
/// 통째로 바꿔 쓴다. 다른 점은 저장이 잦다는 것뿐이라 짧게 묶어서 쓴다.
@MainActor
final class WorkspaceStore {
    private let url: URL
    private var pending: Task<Void, Never>?

    init(url: URL = WorkspaceStore.defaultURL) {
        self.url = url
    }

    nonisolated static var defaultURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.local.myterminal", isDirectory: true)
            .appendingPathComponent("workspace.json")
    }

    func load() -> WorkspaceState? {
        guard
            let data = try? Data(contentsOf: url),
            let state = try? JSONDecoder().decode(WorkspaceState.self, from: data)
        else { return nil }
        return state
    }

    /// 탭을 하나 열 때마다 디스크를 때리지 않도록 잠깐 모았다 쓴다. 창을
    /// 끌어 옮기는 동안에는 프레임 변경이 초당 수십 번 온다.
    func save(_ state: WorkspaceState) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.write(state)
        }
    }

    /// 종료처럼 더 기다릴 수 없을 때. 예약해 둔 쓰기는 버린다.
    func flush(_ state: WorkspaceState) {
        pending?.cancel()
        pending = nil
        write(state)
    }

    private func write(_ state: WorkspaceState) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: url, options: .atomic)
        } catch {
            Log.info("workspace save failed — \(error.localizedDescription)")
        }
    }
}
