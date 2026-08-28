import Foundation
import Testing

@testable import MyTerminal

@Suite("프로젝트 저장소")
@MainActor
struct ProjectStoreTests {
    @Test("브랜치 이름은 프로젝트마다 갈린다 — 한글 이름도 그대로 쓴다")
    func branchNameDiffersPerProject() {
        // #given
        let english = Project(name: "AX Refactor!!", directory: "/tmp/a")
        let korean = Project(name: "리팩터링 2차", directory: "/tmp/b")

        // #when
        let names = [english.branchName, korean.branchName]

        // #then
        #expect(names == ["myterminal/ax-refactor", "myterminal/리팩터링-2차"])
    }

    @Test("프로젝트를 만들면 디렉터리와 표시 파일이 생긴다")
    func createWritesDirectoryAndMarker() throws {
        // #given
        let workspace = Workspace()
        defer { workspace.cleanUp() }

        // #when
        let project = try workspace.store().create(name: "ax-refactor", parent: workspace.root)

        // #then
        #expect(project.directory == workspace.root.appendingPathComponent("ax-refactor").path)
        #expect(FileManager.default.fileExists(atPath: project.directory + "/.myterminal.json"))
    }

    @Test("이름이 같아도 이미 있는 디렉터리를 덮어쓰지 않는다")
    func createNeverReusesAnExistingDirectory() throws {
        // #given
        let workspace = Workspace()
        defer { workspace.cleanUp() }
        let store = workspace.store()
        let first = try store.create(name: "ax-refactor", parent: workspace.root)

        // #when
        let second = try store.create(name: "ax-refactor", parent: workspace.root)

        // #then
        #expect(first.directory != second.directory)
        #expect(second.directory.hasSuffix("ax-refactor-2"))
    }

    @Test("다시 띄운 앱은 저장해 둔 저장소 목록을 그대로 읽는다")
    func reloadsWhatWasWritten() throws {
        // #given
        let workspace = Workspace()
        defer { workspace.cleanUp() }
        var project = try workspace.store().create(name: "ax-refactor", parent: workspace.root)
        project.repositories.append(ProjectRepository(
            sourcePath: "/tmp/web",
            worktreePath: project.directory + "/web",
            branch: project.branchName,
            commonDirectory: "/tmp/web/.git"
        ))
        try workspace.store().update(project)

        // #when
        let reloaded = workspace.store()

        // #then
        #expect(reloaded.projects.count == 1)
        #expect(reloaded.projects.first?.repositories.first?.name == "web")
    }

    @Test("목록에서 빼는 것만으로는 디스크를 건드리지 않는다")
    func removeKeepsFilesOnDisk() throws {
        // #given
        let workspace = Workspace()
        defer { workspace.cleanUp() }
        let store = workspace.store()
        let project = try store.create(name: "ax-refactor", parent: workspace.root)

        // #when
        try store.remove(id: project.id)

        // #then
        #expect(store.projects.isEmpty)
        #expect(workspace.store().projects.isEmpty)
        #expect(FileManager.default.fileExists(atPath: project.directory))
    }

    @Test("빈 프로젝트 디렉터리는 치우고, 사용자가 남긴 것이 있으면 그대로 둔다")
    func discardsOnlyAnOtherwiseEmptyDirectory() throws {
        // #given
        let workspace = Workspace()
        defer { workspace.cleanUp() }
        let store = workspace.store()
        let empty = try store.create(name: "empty", parent: workspace.root)
        let used = try store.create(name: "used", parent: workspace.root)
        try "log".write(
            toFile: used.directory + "/history.txt",
            atomically: true,
            encoding: .utf8
        )

        // #when
        ProjectStore.discardDirectoryIfOnlyMarkerRemains(at: empty.directory)
        ProjectStore.discardDirectoryIfOnlyMarkerRemains(at: used.directory)

        // #then
        #expect(!FileManager.default.fileExists(atPath: empty.directory))
        #expect(FileManager.default.fileExists(atPath: used.directory))
    }
}

/// 진짜 Application Support 대신 임시 디렉터리를 쓰는 저장소 한 벌.
/// `store()`는 매번 새 인스턴스를 주므로 앱을 다시 띄운 것과 같다.
@MainActor
struct Workspace {
    let root: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("myterminal-test-\(UUID().uuidString)", isDirectory: true)
    }

    func store() -> ProjectStore {
        ProjectStore(indexURL: root.appendingPathComponent("projects.json"))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}
