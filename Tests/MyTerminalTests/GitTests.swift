import Foundation
import Testing

@testable import MyTerminal

@Suite("worktree")
struct GitTests {
    @Test("없는 브랜치는 새로 만들어 체크아웃한다")
    func addsWorktreeOnNewBranch() async throws {
        // #given
        let fixture = try await Fixture.repository()
        defer { fixture.cleanUp() }

        // #when
        try await Git.addWorktree(
            repository: fixture.source,
            destination: fixture.destination,
            branch: "myterminal/demo"
        )

        // #then
        let checkedOut = try await Git.run(["-C", fixture.destination, "branch", "--show-current"])
        #expect(checkedOut == "myterminal/demo")
        #expect(FileManager.default.fileExists(atPath: fixture.destination + "/a.txt"))
    }

    @Test("이미 있는 브랜치는 새로 만들지 않고 그대로 체크아웃한다")
    func reusesExistingBranch() async throws {
        // #given
        let fixture = try await Fixture.repository()
        defer { fixture.cleanUp() }
        try await Git.run(["-C", fixture.source, "branch", "myterminal/demo"])

        // #when
        try await Git.addWorktree(
            repository: fixture.source,
            destination: fixture.destination,
            branch: "myterminal/demo"
        )

        // #then
        let checkedOut = try await Git.run(["-C", fixture.destination, "branch", "--show-current"])
        #expect(checkedOut == "myterminal/demo")
    }

    @Test("worktree는 원본과 같은 common dir을 가리킨다 — 중복 추가를 걸러내는 근거")
    func sharesCommonDirectoryWithSource() async throws {
        // #given
        let fixture = try await Fixture.repository()
        defer { fixture.cleanUp() }
        try await Git.addWorktree(
            repository: fixture.source,
            destination: fixture.destination,
            branch: "myterminal/demo"
        )

        // #when
        let fromSource = try await Git.commonDirectory(at: fixture.source)
        let fromWorktree = try await Git.commonDirectory(at: fixture.destination)

        // #then
        #expect(fromSource == fromWorktree)
    }

    @Test("커밋하지 않은 변경이 남은 worktree는 제거하지 않는다")
    func refusesToRemoveDirtyWorktree() async throws {
        // #given
        let fixture = try await Fixture.repository()
        defer { fixture.cleanUp() }
        try await Git.addWorktree(
            repository: fixture.source,
            destination: fixture.destination,
            branch: "myterminal/demo"
        )
        try "dirty".write(toFile: fixture.destination + "/a.txt", atomically: true, encoding: .utf8)

        // #when / #then
        await #expect(throws: GitError.self) {
            try await Git.removeWorktree(
                repository: fixture.source,
                destination: fixture.destination
            )
        }
    }

    @Test("브랜치를 이미 다른 worktree가 쓰고 있으면 어디인지 알려 준다")
    func reportsWhereTheBranchIsAlreadyUsed() async throws {
        // #given
        let fixture = try await Fixture.repository()
        defer { fixture.cleanUp() }
        try await Git.addWorktree(
            repository: fixture.source,
            destination: fixture.destination,
            branch: "myterminal/demo"
        )

        // #when
        let failure = await #expect(throws: GitError.self) {
            try await Git.addWorktree(
                repository: fixture.source,
                destination: fixture.root.appendingPathComponent("other/web").path,
                branch: "myterminal/demo"
            )
        }

        // #then
        let occupied = URL(fileURLWithPath: fixture.destination).resolvingSymlinksInPath().path
        #expect(failure?.message.contains(occupied) == true)
    }

    @Test("git 저장소가 아닌 경로는 거절한다")
    func rejectsNonRepository() async throws {
        // #given
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("myterminal-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // #when / #then
        await #expect(throws: GitError.self) {
            _ = try await Git.repositoryRoot(at: directory.path)
        }
    }
}

/// 커밋 하나가 든 저장소와, worktree를 놓을 빈 자리.
struct Fixture {
    let root: URL
    let source: String
    let destination: String

    static func repository() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("myterminal-test-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("web", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "hi".write(
            to: source.appendingPathComponent("a.txt"),
            atomically: true,
            encoding: .utf8
        )

        try await Git.run(["-C", source.path, "init", "-q", "-b", "main"])
        try await Git.run(["-C", source.path, "add", "."])
        try await Git.run([
            "-C", source.path,
            "-c", "user.email=test@example.com",
            "-c", "user.name=test",
            "commit", "-q", "-m", "init",
        ])

        return Fixture(
            root: root,
            source: source.path,
            destination: root.appendingPathComponent("project/web", isDirectory: true).path
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}
