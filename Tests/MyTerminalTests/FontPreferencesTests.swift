import Foundation
import Testing

@testable import MyTerminal

@Suite("폰트 선택")
@MainActor
struct FontPreferencesTests {
    @Test("한글 한 글자가 라틴 두 칸과 맞아떨어질 때만 매핑한다")
    func acceptsOnlyDoubleWidthHangul() {
        // #given
        let cell: CGFloat = 8

        // #when
        let exact = FontPreferences.fitsCellGrid(hangulWidth: 16, cellWidth: cell)
        // D2Coding처럼 딱 두 칸에서 아주 조금 벗어난 경우는 받아준다.
        let nearlyExact = FontPreferences.fitsCellGrid(hangulWidth: 16.3, cellWidth: cell)

        // #then
        #expect(exact)
        #expect(nearlyExact)
    }

    @Test("폭이 어긋나는 폰트는 거른다 — 매핑하면 한글만 부풀어 오른다")
    func rejectsMismatchedWidths() {
        // #given
        let cell: CGFloat = 7.83

        // #when
        // Apple SD Gothic Neo: ‘가’가 11.25pt, 두 칸은 15.65pt — 1.39배로 벌어진다.
        let uiFont = FontPreferences.fitsCellGrid(hangulWidth: 11.25, cellWidth: cell)
        let tooWide = FontPreferences.fitsCellGrid(hangulWidth: 20, cellWidth: cell)

        // #then
        #expect(!uiFont)
        #expect(!tooWide)
    }

    @Test("잴 수 없는 폭은 매핑하지 않는다")
    func rejectsUnmeasurableWidths() {
        // #given
        let cases: [(CGFloat, CGFloat)] = [(16, 0), (0, 8), (-16, 8)]

        // #when
        let results = cases.map { FontPreferences.fitsCellGrid(hangulWidth: $0.0, cellWidth: $0.1) }

        // #then
        #expect(results.allSatisfy { !$0 })
    }
}
