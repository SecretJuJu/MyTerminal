import Foundation

/// 탭 하나 안의 pane 배치. `Payload`는 세션 식별자다.
///
/// AppKit을 모른다. 트리를 `NSSplitView`로 바꾸는 일은 `SplitLayoutView`가
/// 하고, 여기서는 분할·제거·이웃 찾기만 값으로 계산한다 — 그래야 화면 없이
/// 테스트할 수 있고, 그대로 `workspace.json`에 저장된다.
indirect enum SplitTree<Payload: Hashable & Codable & Sendable>: Hashable, Codable, Sendable {
    case leaf(Payload)
    case branch(axis: Axis, children: [SplitTree])

    /// `horizontal`은 pane이 왼쪽에서 오른쪽으로, `vertical`은 위에서 아래로
    /// 놓인다는 뜻이다. `NSSplitView.isVertical`과 이름이 반대라 혼동하기
    /// 쉬우니 뷰 쪽에서 한 번만 뒤집는다.
    enum Axis: String, Hashable, Codable, Sendable {
        case horizontal
        case vertical
    }

    enum Direction: Hashable, Sendable {
        case left, right, up, down

        var axis: Axis {
            switch self {
            case .left, .right: .horizontal
            case .up, .down: .vertical
            }
        }

        /// 축을 따라 뒤쪽(오른쪽·아래)으로 가는 방향인지.
        var isForward: Bool {
            switch self {
            case .right, .down: true
            case .left, .up: false
            }
        }
    }

    // MARK: - 조회

    var leaves: [Payload] {
        switch self {
        case let .leaf(payload):
            [payload]
        case let .branch(_, children):
            children.flatMap(\.leaves)
        }
    }

    func contains(_ payload: Payload) -> Bool {
        leaves.contains(payload)
    }

    // MARK: - 변경

    /// `target` 옆에 `payload`를 새 pane으로 끼운다.
    ///
    /// 이미 같은 축으로 나뉜 자리라면 형제로 끼워 넣어 트리가 깊어지지 않게
    /// 한다. 좌우로 세 번 나눈 결과가 3중 중첩이 아니라 자식 셋인 편이
    /// `NSSplitView`도 얇고 분할선 드래그도 자연스럽다.
    func inserting(
        _ payload: Payload,
        nextTo target: Payload,
        axis: Axis,
        after: Bool = true
    ) -> Self {
        switch self {
        case let .leaf(existing):
            guard existing == target else { return self }
            let pair: [Self] = after ? [.leaf(existing), .leaf(payload)] : [.leaf(payload), .leaf(existing)]
            return .branch(axis: axis, children: pair)

        case let .branch(existingAxis, children):
            if
                existingAxis == axis,
                let index = children.firstIndex(where: { $0 == .leaf(target) })
            {
                var updated = children
                updated.insert(.leaf(payload), at: after ? index + 1 : index)
                return Self.assemble(axis: existingAxis, children: updated)
            }
            return Self.assemble(
                axis: existingAxis,
                children: children.map {
                    $0.inserting(payload, nextTo: target, axis: axis, after: after)
                }
            )
        }
    }

    /// pane 하나를 뺀다. 마지막 pane이었으면 `nil` — 부르는 쪽이 탭째 닫는다.
    func removing(_ payload: Payload) -> Self? {
        switch self {
        case let .leaf(existing):
            return existing == payload ? nil : self
        case let .branch(axis, children):
            let survivors = children.compactMap { $0.removing(payload) }
            guard !survivors.isEmpty else { return nil }
            return Self.assemble(axis: axis, children: survivors)
        }
    }

    // MARK: - 이웃

    /// 주어진 pane에서 방향키로 옮겨 갈 pane. 그 방향에 아무것도 없으면 nil.
    ///
    /// 자기 부모부터 위로 올라가며 방향과 축이 같고 그쪽에 형제가 있는 첫
    /// 조상을 찾고, 그 형제 안으로는 들어온 쪽에서 가장 가까운 pane까지
    /// 내려간다.
    func neighbor(of payload: Payload, direction: Direction) -> Payload? {
        guard var route = path(to: payload) else { return nil }

        while !route.isEmpty {
            let index = route.removeLast()
            guard
                case let .branch(axis, children) = subtree(at: route),
                axis == direction.axis
            else { continue }

            let sibling = direction.isForward ? index + 1 : index - 1
            guard children.indices.contains(sibling) else { continue }
            return children[sibling].edgeLeaf(along: axis, fromStart: direction.isForward)
        }
        return nil
    }

    /// 트리가 사라진 pane 대신 포커스를 받을 pane. 순서상 다음, 없으면 이전.
    func leafAdjacent(to payload: Payload) -> Payload? {
        let all = leaves
        guard let index = all.firstIndex(of: payload) else { return all.first }
        if index + 1 < all.count { return all[index + 1] }
        return index > 0 ? all[index - 1] : nil
    }

    // MARK: - 내부

    /// 자식이 하나면 접어 올리고, 같은 축의 branch 자식은 펼쳐 흡수한다.
    private static func assemble(axis: Axis, children: [Self]) -> Self {
        let flattened = children.flatMap { child -> [Self] in
            if case let .branch(childAxis, grandChildren) = child, childAxis == axis {
                return grandChildren
            }
            return [child]
        }
        if flattened.count == 1 { return flattened[0] }
        return .branch(axis: axis, children: flattened)
    }

    private func path(to payload: Payload) -> [Int]? {
        switch self {
        case let .leaf(existing):
            return existing == payload ? [] : nil
        case let .branch(_, children):
            for (index, child) in children.enumerated() {
                if let deeper = child.path(to: payload) {
                    return [index] + deeper
                }
            }
            return nil
        }
    }

    private func subtree(at route: [Int]) -> Self {
        var node = self
        for index in route {
            guard case let .branch(_, children) = node, children.indices.contains(index) else {
                return node
            }
            node = children[index]
        }
        return node
    }

    private func edgeLeaf(along axis: Axis, fromStart: Bool) -> Payload {
        switch self {
        case let .leaf(payload):
            return payload
        case let .branch(existingAxis, children):
            let next = existingAxis == axis
                ? (fromStart ? children.first : children.last)
                : children.first
            // assemble이 자식 없는 branch를 만들지 않으므로 first/last는 항상 있다.
            guard let next else { return leaves[0] }
            return next.edgeLeaf(along: axis, fromStart: fromStart)
        }
    }
}
