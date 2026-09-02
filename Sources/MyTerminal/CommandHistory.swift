import Foundation

/// 입력 상자가 보낸 명령 목록. ↑↓로 되부르는 데 쓴다.
///
/// 셸 히스토리와는 별개다. 셸의 것은 셸이 갖고 있고 우리가 읽을 방법이 없다.
/// 여기 쌓이는 것은 이 상자로 보낸 것뿐이라, ⌃R로 찾는 셸 히스토리와 겹치지
/// 않고 나란히 쓰인다.
struct CommandHistory: Hashable, Codable, Sendable {
    /// 오래된 것이 앞, 최근이 뒤.
    private(set) var entries: [String] = []
    /// 지금 몇 번째를 보고 있는지. nil이면 되부르는 중이 아니다.
    private var cursor: Int?
    /// 되부르기를 시작할 때 쓰던 글. 끝까지 내려오면 이걸 돌려준다 —
    /// 히스토리를 뒤지다 돌아왔더니 쓰던 게 사라져 있으면 안 된다.
    private var stashed: String?

    static let limit = 200

    init(entries: [String] = []) {
        self.entries = entries
    }

    mutating func record(_ command: String) {
        cursor = nil
        stashed = nil

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
        guard !entries.isEmpty else { return nil }

        if cursor == nil {
            guard direction < 0 else { return nil }
            stashed = current
            cursor = entries.count - 1
            return entries[entries.count - 1]
        }

        guard let index = cursor else { return nil }
        // -1은 목록에서 앞(옛것), +1은 뒤(최근)로 움직인다.
        let next = index + direction

        if next < 0 {
            cursor = 0
            return entries[0]
        }
        if next >= entries.count {
            // 최근 것보다 더 내려오면 되부르기를 끝내고 쓰던 글로 돌아간다.
            cursor = nil
            let restored = stashed ?? ""
            stashed = nil
            return restored
        }
        cursor = next
        return entries[next]
    }

    /// 사용자가 직접 글을 고치면 되부르기 상태를 놓는다.
    mutating func endRecall() {
        cursor = nil
        stashed = nil
    }

    var isRecalling: Bool { cursor != nil }
}
