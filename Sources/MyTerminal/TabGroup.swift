import Foundation

/// 탭 하나. pane 배치와 그 안에서 포커스를 가진 pane을 들고 있다.
///
/// `title`은 포커스한 pane이 마지막으로 알려 준 제목이다. 저장해 두는 이유는
/// 복원 직후 — 셸을 아직 띄우지 않은 탭도 탭바에 이름이 있어야 하기 때문이다.
struct TerminalTab: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var layout: SplitTree<UUID>
    var focus: UUID
    var title: String

    init(id: UUID = UUID(), session: UUID, title: String) {
        self.id = id
        layout = .leaf(session)
        focus = session
        self.title = title
    }

    var sessions: [UUID] { layout.leaves }
}

/// 사이드바 선택 하나에 딸린 탭 목록.
///
/// 탭은 프로젝트에 속한다. 사이드바에서 프로젝트를 바꾸면 이 묶음이 통째로
/// 교체되고, 각 프로젝트는 자기 탭과 셸을 그대로 들고 기다린다.
struct TabGroup: Hashable, Codable, Sendable {
    var tabs: [TerminalTab] = []
    var activeTabID: UUID?

    var isEmpty: Bool { tabs.isEmpty }

    var activeTab: TerminalTab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    /// 이 묶음이 들고 있는 모든 세션. 프로젝트가 사라질 때 정리 대상이다.
    var sessions: [UUID] { tabs.flatMap(\.sessions) }

    func tab(containing session: UUID) -> TerminalTab? {
        tabs.first { $0.sessions.contains(session) }
    }

    // MARK: - 탭

    mutating func append(_ tab: TerminalTab) {
        tabs.append(tab)
        activeTabID = tab.id
    }

    /// 탭을 닫고 그 탭이 들고 있던 세션들을 돌려준다. 부르는 쪽이 셸을 치운다.
    mutating func closeTab(id: UUID) -> [UUID] {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return [] }
        let closed = tabs.remove(at: index)
        if activeTabID == id {
            // 닫은 자리에 있던 탭, 없으면 그 앞 탭으로 옮긴다.
            activeTabID = tabs.indices.contains(index)
                ? tabs[index].id
                : tabs.last?.id
        }
        return closed.sessions
    }

    /// pane 하나만 닫는다. 그 탭의 마지막 pane이었으면 탭까지 닫힌다.
    mutating func closePane(_ session: UUID) -> ClosePaneResult {
        guard let index = tabs.firstIndex(where: { $0.sessions.contains(session) }) else {
            return ClosePaneResult(removedTab: nil, removedSessions: [])
        }

        guard let shrunk = tabs[index].layout.removing(session) else {
            let tab = tabs[index]
            return ClosePaneResult(
                removedTab: tab.id,
                removedSessions: closeTab(id: tab.id)
            )
        }

        if tabs[index].focus == session {
            tabs[index].focus = tabs[index].layout.leafAdjacent(to: session) ?? shrunk.leaves[0]
        }
        tabs[index].layout = shrunk
        return ClosePaneResult(removedTab: nil, removedSessions: [session])
    }

    struct ClosePaneResult: Hashable, Sendable {
        /// 함께 닫힌 탭. pane만 닫혔으면 nil.
        let removedTab: UUID?
        let removedSessions: [UUID]
    }

    // MARK: - 분할

    /// 포커스한 pane 옆에 새 pane을 끼우고 포커스를 옮긴다.
    mutating func split(
        tab id: UUID,
        newSession: UUID,
        axis: SplitTree<UUID>.Axis
    ) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let target = tabs[index].focus
        tabs[index].layout = tabs[index].layout.inserting(
            newSession,
            nextTo: target,
            axis: axis
        )
        tabs[index].focus = newSession
    }

    mutating func focus(_ session: UUID) {
        guard let index = tabs.firstIndex(where: { $0.sessions.contains(session) }) else { return }
        tabs[index].focus = session
        activeTabID = tabs[index].id
    }

    // MARK: - 전환

    mutating func activate(index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeTabID = tabs[index].id
    }

    /// 끝에서 한 칸 더 가면 처음으로 돈다 — 탭 전환은 순환하는 편이 손에 익다.
    mutating func activateNext() { step(by: 1) }
    mutating func activatePrevious() { step(by: -1) }

    private mutating func step(by offset: Int) {
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex { $0.id == activeTabID } ?? 0
        let next = (current + offset + tabs.count) % tabs.count
        activeTabID = tabs[next].id
    }

    mutating func rename(tab id: UUID, title: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].title = title
    }
}
