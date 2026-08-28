import Foundation

/// 여러 저장소의 worktree를 한 디렉터리에 모아 둔 작업 단위.
///
/// 터미널은 저장소가 아니라 이 디렉터리에서 열린다. 그래야 claude처럼
/// 실행한 자리에 히스토리를 남기는 도구가 저장소별로 흩어지지 않고
/// 프로젝트 하나에 쌓인다.
struct Project: Codable, Hashable, Identifiable {
    let id: UUID
    var name: String
    /// 절대 경로. worktree들의 부모이자 터미널의 작업 디렉터리다.
    var directory: String
    var repositories: [ProjectRepository]

    init(
        id: UUID = UUID(),
        name: String,
        directory: String,
        repositories: [ProjectRepository] = []
    ) {
        self.id = id
        self.name = name
        self.directory = directory
        self.repositories = repositories
    }

    /// worktree가 체크아웃할 브랜치.
    ///
    /// 프로젝트마다 이름이 달라야 한다. git은 이미 다른 worktree가 물고 있는
    /// 브랜치를 다시 체크아웃하지 못하므로, 같은 저장소를 두 프로젝트에
    /// 넣으려면 브랜치가 갈려 있어야 한다.
    var branchName: String {
        "myterminal/\(Self.slug(name))"
    }

    /// 파일 이름과 git ref 양쪽에서 안전한 형태로 줄인다. 한글은 그대로
    /// 둔다 — git ref도 파일 이름도 UTF-8을 받는다.
    static func slug(_ raw: String) -> String {
        let mapped = raw.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "project" : collapsed.lowercased()
    }
}

/// 프로젝트 안에 딴 worktree 하나.
struct ProjectRepository: Codable, Hashable, Identifiable {
    let id: UUID
    /// worktree를 딴 원본 저장소의 최상위 경로. worktree 제거도 여기서 실행한다.
    var sourcePath: String
    /// 프로젝트 디렉터리 안의 worktree 경로.
    var worktreePath: String
    var branch: String
    /// 같은 저장소가 두 번 들어오는 것을 막기 위한 식별자로 쓰는
    /// `git rev-parse --git-common-dir` 값. 한 저장소의 worktree끼리는
    /// 이 값이 같으므로, 사용자가 원본 대신 worktree 경로를 골라도 걸린다.
    var commonDirectory: String

    init(
        id: UUID = UUID(),
        sourcePath: String,
        worktreePath: String,
        branch: String,
        commonDirectory: String
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.worktreePath = worktreePath
        self.branch = branch
        self.commonDirectory = commonDirectory
    }

    var name: String {
        (worktreePath as NSString).lastPathComponent
    }
}
