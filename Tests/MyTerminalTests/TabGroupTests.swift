import Foundation
import Testing

@testable import MyTerminal

@Suite("탭 묶음")
struct TabGroupTests {
    private func tab(_ title: String) -> TerminalTab {
        TerminalTab(session: UUID(), title: title)
    }

    @Test("탭을 붙이면 그 탭이 활성이 된다")
    func appendActivatesNewTab() {
        // #given
        var group = TabGroup()
        let first = tab("첫 탭")
        let second = tab("둘째 탭")

        // #when
        group.append(first)
        group.append(second)

        // #then
        #expect(group.tabs.count == 2)
        #expect(group.activeTabID == second.id)
    }

    @Test("활성 탭을 닫으면 그 자리 탭이, 없으면 앞 탭이 활성이 된다")
    func closingActiveTabMovesActivation() {
        // #given
        var group = TabGroup()
        let first = tab("1")
        let second = tab("2")
        let third = tab("3")
        for item in [first, second, third] { group.append(item) }
        group.activate(index: 1)

        // #when
        let removedMiddle = group.closeTab(id: second.id)

        // #then
        #expect(removedMiddle == second.sessions)
        #expect(group.activeTabID == third.id)

        // #when — 마지막 탭을 닫으면 앞 탭으로 물러난다
        _ = group.closeTab(id: third.id)

        // #then
        #expect(group.activeTabID == first.id)
    }

    @Test("pane을 나누면 새 pane이 포커스를 받는다")
    func splitFocusesTheNewPane() {
        // #given
        var group = TabGroup()
        let only = tab("작업")
        group.append(only)
        let newSession = UUID()

        // #when
        group.split(tab: only.id, newSession: newSession, axis: .horizontal)

        // #then
        #expect(group.activeTab?.sessions.count == 2)
        #expect(group.activeTab?.focus == newSession)
    }

    @Test("pane 하나만 닫으면 탭은 남고 포커스가 옆으로 옮겨간다")
    func closingOnePaneKeepsTheTab() {
        // #given
        var group = TabGroup()
        let only = tab("작업")
        group.append(only)
        let added = UUID()
        group.split(tab: only.id, newSession: added, axis: .vertical)

        // #when
        let result = group.closePane(added)

        // #then
        #expect(result.removedTab == nil)
        #expect(result.removedSessions == [added])
        #expect(group.tabs.count == 1)
        #expect(group.activeTab?.focus == only.sessions[0])
    }

    @Test("탭의 마지막 pane을 닫으면 탭까지 닫힌다")
    func closingLastPaneClosesTheTab() {
        // #given
        var group = TabGroup()
        let only = tab("작업")
        group.append(only)
        let session = only.sessions[0]

        // #when
        let result = group.closePane(session)

        // #then
        #expect(result.removedTab == only.id)
        #expect(result.removedSessions == [session])
        #expect(group.isEmpty)
        #expect(group.activeTabID == nil)
    }

    @Test("탭 전환은 끝에서 처음으로 돈다")
    func activationWrapsAround() {
        // #given
        var group = TabGroup()
        let first = tab("1")
        let second = tab("2")
        group.append(first)
        group.append(second)

        // #when
        group.activateNext()

        // #then
        #expect(group.activeTabID == first.id)

        // #when
        group.activatePrevious()

        // #then
        #expect(group.activeTabID == second.id)
    }

    @Test("pane에 포커스를 주면 그 pane이 든 탭도 활성이 된다")
    func focusingPaneActivatesItsTab() {
        // #given
        var group = TabGroup()
        let first = tab("1")
        let second = tab("2")
        group.append(first)
        group.append(second)

        // #when
        group.focus(first.sessions[0])

        // #then
        #expect(group.activeTabID == first.id)
        #expect(group.activeTab?.focus == first.sessions[0])
    }

    @Test("탭 묶음은 저장했다 읽어도 같다")
    func codableRoundTrip() throws {
        // #given
        var group = TabGroup()
        let only = tab("작업")
        group.append(only)
        group.split(tab: only.id, newSession: UUID(), axis: .horizontal)

        // #when
        let data = try JSONEncoder().encode(group)
        let decoded = try JSONDecoder().decode(TabGroup.self, from: data)

        // #then
        #expect(decoded == group)
    }
}
