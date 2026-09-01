import Foundation
import Testing

@testable import MyTerminal

@Suite("분할 트리")
struct SplitTreeTests {
    private typealias Tree = SplitTree<String>

    @Test("pane을 나누면 나눈 방향의 분할이 생기고 순서가 유지된다")
    func splitsLeafIntoOrderedPair() {
        // #given
        let tree = Tree.leaf("a")

        // #when
        let split = tree.inserting("b", nextTo: "a", axis: .horizontal)

        // #then
        #expect(split == .branch(axis: .horizontal, children: [.leaf("a"), .leaf("b")]))
        #expect(split.leaves == ["a", "b"])
    }

    @Test("같은 방향으로 또 나누면 중첩되지 않고 형제로 붙는다")
    func sameAxisSplitStaysFlat() {
        // #given
        let tree = Tree.leaf("a").inserting("b", nextTo: "a", axis: .horizontal)

        // #when
        let split = tree.inserting("c", nextTo: "b", axis: .horizontal)

        // #then
        #expect(split == .branch(
            axis: .horizontal,
            children: [.leaf("a"), .leaf("b"), .leaf("c")]
        ))
    }

    @Test("다른 방향으로 나누면 그 자리만 중첩된다")
    func crossAxisSplitNests() {
        // #given
        let tree = Tree.leaf("a").inserting("b", nextTo: "a", axis: .horizontal)

        // #when
        let split = tree.inserting("c", nextTo: "b", axis: .vertical)

        // #then
        #expect(split == .branch(axis: .horizontal, children: [
            .leaf("a"),
            .branch(axis: .vertical, children: [.leaf("b"), .leaf("c")]),
        ]))
        #expect(split.leaves == ["a", "b", "c"])
    }

    @Test("없는 pane 옆에 끼우려 하면 트리가 그대로다")
    func insertingNextToMissingPaneIsNoop() {
        // #given
        let tree = Tree.leaf("a").inserting("b", nextTo: "a", axis: .horizontal)

        // #when
        let split = tree.inserting("z", nextTo: "nope", axis: .vertical)

        // #then
        #expect(split == tree)
    }

    @Test("pane을 빼면 혼자 남은 분할은 접힌다")
    func removingCollapsesLoneBranch() {
        // #given
        let tree = Tree.leaf("a")
            .inserting("b", nextTo: "a", axis: .horizontal)
            .inserting("c", nextTo: "b", axis: .vertical)

        // #when
        let shrunk = tree.removing("c")

        // #then
        #expect(shrunk == .branch(axis: .horizontal, children: [.leaf("a"), .leaf("b")]))
    }

    @Test("마지막 pane을 빼면 트리가 사라진다")
    func removingLastLeafYieldsNil() {
        // #given
        let tree = Tree.leaf("only")

        // #when
        let shrunk = tree.removing("only")

        // #then
        #expect(shrunk == nil)
    }

    @Test("좌우로 나뉜 pane 사이를 방향키로 옮겨 다닌다")
    func neighborFollowsHorizontalSplit() {
        // #given
        let tree = Tree.leaf("a")
            .inserting("b", nextTo: "a", axis: .horizontal)
            .inserting("c", nextTo: "b", axis: .horizontal)

        // #when
        let rightOfA = tree.neighbor(of: "a", direction: .right)
        let leftOfC = tree.neighbor(of: "c", direction: .left)
        let aboveB = tree.neighbor(of: "b", direction: .up)

        // #then
        #expect(rightOfA == "b")
        #expect(leftOfC == "b")
        #expect(aboveB == nil)
    }

    @Test("중첩된 분할에서는 들어오는 쪽에서 가장 가까운 pane을 만난다")
    func neighborDescendsIntoNestedSplit() {
        // #given
        // a | (b 위, c 아래)
        let tree = Tree.leaf("a")
            .inserting("b", nextTo: "a", axis: .horizontal)
            .inserting("c", nextTo: "b", axis: .vertical)

        // #when
        let rightOfA = tree.neighbor(of: "a", direction: .right)
        let leftOfC = tree.neighbor(of: "c", direction: .left)
        let belowB = tree.neighbor(of: "b", direction: .down)

        // #then
        #expect(rightOfA == "b")
        #expect(leftOfC == "a")
        #expect(belowB == "c")
    }

    @Test("사라진 pane의 포커스는 순서상 다음 pane이 받는다")
    func adjacentLeafPrefersTheNextOne() {
        // #given
        let tree = Tree.leaf("a")
            .inserting("b", nextTo: "a", axis: .horizontal)
            .inserting("c", nextTo: "b", axis: .horizontal)

        // #when
        let afterB = tree.leafAdjacent(to: "b")
        let afterC = tree.leafAdjacent(to: "c")

        // #then
        #expect(afterB == "c")
        #expect(afterC == "b")
    }

    @Test("트리는 저장했다 읽어도 같은 배치다")
    func codableRoundTrip() throws {
        // #given
        let tree = Tree.leaf("a")
            .inserting("b", nextTo: "a", axis: .horizontal)
            .inserting("c", nextTo: "b", axis: .vertical)

        // #when
        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(Tree.self, from: data)

        // #then
        #expect(decoded == tree)
    }
}
