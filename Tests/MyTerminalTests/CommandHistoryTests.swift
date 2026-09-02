import Foundation
import Testing

@testable import MyTerminal

@Suite("입력 상자 히스토리")
struct CommandHistoryTests {
    @Test("보낸 명령이 쌓이고, 빈 것과 연달아 같은 것은 쌓이지 않는다")
    func recordsMeaningfulCommands() {
        // #given
        var history = CommandHistory()

        // #when
        history.record("git status")
        history.record("")
        history.record("   \n ")
        history.record("git status")
        history.record("make test")

        // #then
        #expect(history.entries == ["git status", "make test"])
    }

    @Test("↑는 최근 것부터, ↓는 되짚어 온다")
    func stepsThroughEntries() {
        // #given
        var history = CommandHistory()
        for command in ["one", "two", "three"] { history.record(command) }

        // #when
        let first = history.step(-1, current: "")
        let second = history.step(-1, current: "")
        let back = history.step(1, current: "")

        // #then
        #expect(first == "three")
        #expect(second == "two")
        #expect(back == "three")
    }

    @Test("되부르기를 시작할 때 쓰던 글은 끝까지 내려오면 돌아온다")
    func restoresStashedDraft() {
        // #given
        var history = CommandHistory()
        history.record("git push")

        // #when
        let recalled = history.step(-1, current: "쓰다 만 명령")
        let returned = history.step(1, current: "git push")

        // #then
        #expect(recalled == "git push")
        #expect(returned == "쓰다 만 명령")
        #expect(!history.isRecalling)
    }

    @Test("가장 오래된 것에서 더 올라가려 해도 그 자리에 머문다")
    func stopsAtOldest() {
        // #given
        var history = CommandHistory()
        history.record("first")
        history.record("second")

        // #when
        _ = history.step(-1, current: "")
        _ = history.step(-1, current: "")
        let stuck = history.step(-1, current: "")

        // #then
        #expect(stuck == "first")
    }

    @Test("비어 있으면 되부를 것이 없다")
    func emptyHistoryRecallsNothing() {
        // #given
        var history = CommandHistory()

        // #when
        let recalled = history.step(-1, current: "쓰던 글")

        // #then
        #expect(recalled == nil)
    }

    @Test("상한을 넘으면 오래된 것이 빠진다")
    func trimsToLimit() {
        // #given
        var history = CommandHistory()

        // #when
        for index in 0 ..< (CommandHistory.limit + 10) {
            history.record("command \(index)")
        }

        // #then
        #expect(history.entries.count == CommandHistory.limit)
        #expect(history.entries.first == "command 10")
        #expect(history.entries.last == "command \(CommandHistory.limit + 9)")
    }

    @Test("히스토리는 저장했다 읽어도 같다")
    func codableRoundTrip() throws {
        // #given
        var history = CommandHistory()
        history.record("ls -al")

        // #when
        let data = try JSONEncoder().encode(history)
        let decoded = try JSONDecoder().decode(CommandHistory.self, from: data)

        // #then
        #expect(decoded.entries == history.entries)
    }
}
