import Foundation
import Testing

@testable import MyTerminal

@Suite("셸 히스토리 읽기")
struct ShellHistoryTests {
    @Test("zsh 확장 포맷에서 명령만 뽑는다")
    func parsesZshExtendedFormat() {
        // #given
        let file = """
        : 1788397245:0;cd ~/workspace/myterminal/
        : 1788397247:0;make test
        """

        // #when
        let commands = ShellHistory.parse(Data(file.utf8), kind: .zsh)

        // #then
        #expect(commands == ["cd ~/workspace/myterminal/", "make test"])
    }

    @Test("역슬래시로 이어진 여러 줄 명령은 한 덩어리로 읽는다")
    func joinsContinuedLines() {
        // #given
        let file = """
        : 1:0;for file in *.swift; do \\
        echo $file \\
        done
        : 2:0;ls
        """

        // #when
        let commands = ShellHistory.parse(Data(file.utf8), kind: .zsh)

        // #then
        #expect(commands == ["for file in *.swift; do \necho $file \ndone", "ls"])
    }

    @Test("zsh 메타 인코딩을 풀어 한글을 되살린다")
    func decodesMetaEncodedBytes() {
        // #given — zsh는 아스키가 아닌 바이트를 0x83 + (바이트 xor 32)로 적는다.
        var raw = Data(": 1:0;echo ".utf8)
        for byte in Array("한".utf8) {
            if byte >= 0x80 {
                raw.append(0x83)
                raw.append(byte ^ 32)
            } else {
                raw.append(byte)
            }
        }

        // #when
        let commands = ShellHistory.parse(raw, kind: .zsh)

        // #then
        #expect(commands == ["echo 한"])
    }

    @Test("확장 포맷을 안 쓰는 파일도 그대로 읽는다")
    func readsPlainHistory() {
        // #given
        let file = "ls -al\ngit status\n\n"

        // #when
        let commands = ShellHistory.parse(Data(file.utf8), kind: .plain)

        // #then
        #expect(commands == ["ls -al", "git status"])
    }

    @Test("잇달아 같은 명령은 한 번만 남긴다")
    func collapsesConsecutiveDuplicates() {
        // #given
        let file = ": 1:0;ls\n: 2:0;ls\n: 3:0;pwd\n: 4:0;ls"

        // #when
        let commands = ShellHistory.parse(Data(file.utf8), kind: .zsh)

        // #then
        #expect(commands == ["ls", "pwd", "ls"])
    }

    @Test("fish 형식은 cmd 줄만 고른다")
    func parsesFishHistory() {
        // #given
        let file = """
        - cmd: brew update
          when: 1788397245
        - cmd: swift build
          when: 1788397250
        """

        // #when
        let commands = ShellHistory.parse(Data(file.utf8), kind: .fish)

        // #then
        #expect(commands == ["brew update", "swift build"])
    }
}
