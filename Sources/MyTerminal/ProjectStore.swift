import Foundation

struct ProjectStoreError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

/// 프로젝트 목록 저장소.
///
/// 프로젝트의 원본은 자기 디렉터리 안의 `.myterminal.json`이고, Application
/// Support에는 디렉터리 경로 목록만 둔다. 프로젝트 디렉터리가 스스로를
/// 설명하니 통째로 옮기거나 백업해도 내용이 따라가고, 앱이 들고 있는 사본과
/// 어긋날 여지도 없다.
@MainActor
final class ProjectStore {
    private nonisolated static let markerName = ".myterminal.json"

    private(set) var projects: [Project] = []

    /// 읽지 못한 항목도 목록에 남겨 둔다. 외장 볼륨이 잠깐 빠졌다고 색인에서
    /// 지워 버리면 다시 꽂았을 때 돌아올 방법이 없다.
    private var directories: [String] = []

    private let indexURL: URL

    /// `indexURL`은 테스트가 진짜 Application Support를 건드리지 않게 하려고
    /// 열어 둔 자리다. 앱은 기본값을 그대로 쓴다.
    init(indexURL: URL = ProjectStore.defaultIndexURL) {
        self.indexURL = indexURL
        load()
    }

    /// 프로젝트 디렉터리를 새로 만들 기본 위치.
    nonisolated static var defaultRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("MyTerminal", isDirectory: true)
    }

    func project(id: UUID) -> Project? {
        projects.first { $0.id == id }
    }

    // MARK: - 변경

    func create(name: String, parent: URL) throws -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProjectStoreError(message: "프로젝트 이름을 입력하세요.")
        }

        let directory = Self.availableURL(named: Self.fileSystemName(for: trimmed), in: parent)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let project = Project(name: trimmed, directory: directory.path)
        try write(project)
        projects.append(project)
        directories.append(project.directory)
        try saveIndex()
        Log.info("project created — \(project.name) at \(project.directory)")
        return project
    }

    func update(_ project: Project) throws {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else {
            throw ProjectStoreError(message: "프로젝트를 찾을 수 없습니다.")
        }
        try write(project)
        projects[index] = project
    }

    /// 목록에서만 뺀다. 디스크는 건드리지 않는다. worktree 정리는 부르는
    /// 쪽이 `Git`으로 먼저 하고, 그 결과에 따라 이걸 부를지 정한다.
    func remove(id: UUID) throws {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        let project = projects.remove(at: index)
        directories.removeAll { $0 == project.directory }
        try saveIndex()
        Log.info("project removed from list — \(project.name)")
    }

    /// worktree를 다 걷어낸 뒤 우리가 만든 표시 파일 말고는 아무것도 남지
    /// 않았으면 디렉터리째 치운다. 셸 히스토리처럼 사용자가 남긴 것이
    /// 하나라도 있으면 손대지 않는다 — 그건 우리가 만든 것이 아니다.
    nonisolated static func discardDirectoryIfOnlyMarkerRemains(at directory: String) {
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        guard leftovers.allSatisfy({ $0 == markerName || $0 == ".DS_Store" }) else {
            Log.info("project directory kept — \(leftovers.count) file(s) left at \(directory)")
            return
        }
        try? FileManager.default.removeItem(atPath: directory)
    }

    /// 프로젝트 디렉터리 안에서 아직 쓰이지 않은 worktree 경로를 고른다.
    /// 이름이 같은 저장소를 둘 넣어도 서로 덮어쓰지 않는다.
    static func availableWorktreePath(named name: String, in directory: String) -> String {
        availableURL(
            named: fileSystemName(for: name),
            in: URL(fileURLWithPath: directory, isDirectory: true)
        ).path
    }

    // MARK: - 디스크

    private func load() {
        guard
            let data = try? Data(contentsOf: indexURL),
            let index = try? JSONDecoder().decode(Index.self, from: data)
        else { return }

        directories = index.directories
        projects = directories.compactMap { directory in
            guard
                let data = try? Data(contentsOf: Self.markerURL(for: directory)),
                var project = try? JSONDecoder().decode(Project.self, from: data)
            else {
                Log.info("project skipped — no readable marker at \(directory)")
                return nil
            }
            // 색인이 가리키는 자리가 실제 위치다. 디렉터리를 옮긴 뒤라면
            // 표시 파일 안의 경로 쪽이 낡았다.
            project.directory = directory
            return project
        }
        Log.info("projects loaded — \(projects.count)/\(directories.count)")
    }

    private func write(_ project: Project) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(project)
            .write(to: Self.markerURL(for: project.directory), options: .atomic)
    }

    private func saveIndex() throws {
        try FileManager.default.createDirectory(
            at: indexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Index(directories: directories)).write(to: indexURL, options: .atomic)
    }

    private struct Index: Codable {
        var directories: [String]
    }

    nonisolated static var defaultIndexURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.local.myterminal", isDirectory: true)
            .appendingPathComponent("projects.json")
    }

    private static func markerURL(for directory: String) -> URL {
        URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent(markerName)
    }

    // MARK: - 이름

    /// 디렉터리 이름으로 쓸 수 있게 다듬는다. 경로 구분자와 콜론만 막으면
    /// 되고, 공백이나 한글은 그대로 두는 편이 사용자가 Finder에서 찾기 쉽다.
    private static func fileSystemName(for raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .drop { $0 == "." }
        return cleaned.isEmpty ? Project.slug(raw) : String(cleaned)
    }

    private static func availableURL(named name: String, in parent: URL) -> URL {
        var candidate = parent.appendingPathComponent(name, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(name)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }
}
