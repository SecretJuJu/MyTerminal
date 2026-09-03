import Foundation

/// ↑↓로 되부를 명령 목록.
///
/// 두 갈래를 함께 본다. 셸이 쌓아 둔 히스토리(`seeded`)와 이 상자로 보낸
/// 명령(`entries`)이다. 저장되는 것은 뒤엣것뿐이다 — 셸 히스토리는 켤 때마다
/// 파일에서 다시 읽으므로 우리 파일에 복제할 이유가 없다.
///
/// 상자에 글이 있는 채로 ↑를 누르면 그 글로 시작하는 명령만 훑는다. 빈 상태로
/// 누르면 전부 훑는다. zsh에서 `history-beginning-search`를 걸어 쓰는 것과 같은
/// 규칙이고, 긴 히스토리에서 원하는 줄을 찾는 방법이 그것뿐이다.
struct CommandHistory: Hashable, Codable, Sendable {
    /// 이 상자로 보낸 명령. 오래된 것이 앞, 최근이 뒤. 저장된다.
    private(set) var entries: [String] = []
    /// 셸 히스토리에서 읽어 온 것. 저장하지 않는다.
    private var seeded: [String] = []
    /// 지금 훑고 있는 자리. nil이면 되부르는 중이 아니다.
    private var cursor: Int?
    /// 되부르기를 시작할 때 쓰던 글. 끝까지 내려오면 이걸 돌려준다.
    private var stashed: String?
    /// 되부르기를 시작할 때의 접두사. 훑는 동안 고정한다.
    private var searchPrefix = ""

    static let limit = 200

    enum CodingKeys: String, CodingKey {
        case entries
    }

    init(entries: [String] = []) {
        self.entries = entries
    }

    /// 셸 히스토리를 밑에 깐다. 앱이 보낸 명령이 항상 그 뒤(최근)에 온다.
    mutating func seed(_ commands: [String]) {
        seeded = commands
        endRecall()
    }

    /// 되부를 수 있는 전체 목록.
    var recallable: [String] {
        seeded + entries
    }

    mutating func record(_ command: String) {
        endRecall()

        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // 같은 명령을 잇달아 보내면 목록에 두 번 남기지 않는다.
        if entries.last == command { return }

        entries.append(command)
        if entries.count > Self.limit {
            entries.removeFirst(entries.count - Self.limit)
        }
    }

    /// `direction`이 -1이면 더 옛것, +1이면 더 최근 것. 더 갈 곳이 없으면 nil을
    /// 돌려주고 상자는 그대로 둔다.
    mutating func step(_ direction: Int, current: String) -> String? {
        if cursor == nil {
            guard direction < 0 else { return nil }
            searchPrefix = current
            let candidates = matches
            guard !candidates.isEmpty else {
                searchPrefix = ""
                return nil
            }
            stashed = current
            cursor = candidates.count - 1
            return candidates[candidates.count - 1]
        }

        let candidates = matches
        guard let index = cursor, !candidates.isEmpty else { return nil }
        // -1은 목록에서 앞(옛것), +1은 뒤(최근)로 움직인다.
        let next = index + direction

        if next < 0 {
            cursor = 0
            return candidates[0]
        }
        if next >= candidates.count {
            // 최근 것보다 더 내려오면 되부르기를 끝내고 쓰던 글로 돌아간다.
            let restored = stashed ?? ""
            endRecall()
            return restored
        }
        cursor = next
        return candidates[next]
    }

    /// 사용자가 직접 글을 고치면 되부르기 상태를 놓는다.
    mutating func endRecall() {
        cursor = nil
        stashed = nil
        searchPrefix = ""
    }

    var isRecalling: Bool { cursor != nil }

    /// 지금 접두사로 훑을 목록.
    private var matches: [String] {
        guard !searchPrefix.isEmpty else { return recallable }
        return recallable.filter { $0.hasPrefix(searchPrefix) && $0 != searchPrefix }
    }
}
