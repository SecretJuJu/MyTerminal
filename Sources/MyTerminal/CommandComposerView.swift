import AppKit

/// pane 아래에 붙는 명령 입력 상자.
///
/// 셸의 줄 편집(zle) 대신 여기서 명령을 쓴다. 여러 줄을 쓰고 드래그로 고르고
/// ⌘Z로 되돌리는 일이 되는 이유는 그냥 `NSTextView`이기 때문이다. 다 쓰고
/// ⏎를 누르면 붙여넣기로 셸에 보내고 Return을 한 번 더 보내 실행한다.
///
/// 셸이 직접 받아야 하는 키는 여기서 처리하지 않고 그대로 넘긴다 — ⌃C로
/// 멈추고 ⌃R로 히스토리를 찾는 손버릇이 상자 때문에 죽으면 안 된다.
@MainActor
final class CommandComposerView: NSView {
    var onSubmit: ((String) -> Void)?
    /// Esc. 터미널로 포커스를 되돌린다.
    var onLeave: (() -> Void)?
    /// 셸이 받아야 하는 키. 창이 터미널 뷰로 넘긴다.
    var onForwardKey: ((NSEvent) -> Void)?
    /// -1은 지난 입력, +1은 다음 입력. 돌려준 글이 상자에 들어간다.
    var onHistoryStep: ((Int) -> String?)?
    var onTextChange: ((String) -> Void)?
    /// 완성 후보를 찾을 기준 디렉터리. 셸이 알려 준 pwd를 창이 넣어 준다.
    var workingDirectory: () -> String = { FileManager.default.currentDirectoryPath }

    /// 한 번에 보여 줄 최대 줄 수. 이보다 길면 상자 안에서 스크롤한다 —
    /// 상자가 pane을 다 먹으면 정작 결과를 볼 자리가 없다.
    private static let maxVisibleLines = 8
    private static let verticalPadding: CGFloat = 8

    private let prompt = NSTextField(labelWithString: "❯")
    private let textView = ComposerTextView()
    private let scrollView = NSScrollView()
    private let hint = NSTextField(labelWithString: "⏎ 실행 · ⇧⏎ 줄바꿈 · ⇥ 완성 · ↑ 히스토리 · esc 터미널")
    private let completions = CompletionListView()
    private var heightConstraint: NSLayoutConstraint?
    private var colors: ChromeColors = AppTheme.ghosttyDefault.chrome(systemIsDark: false)
    private var fontSize: Float = 13

    var text: String {
        get { textView.string }
        set {
            completions.hide()
            textView.string = newValue
            textView.setSelectedRange(NSRange(location: newValue.utf16.count, length: 0))
            refreshHeight()
            refreshHint()
        }
    }

    var isFocused: Bool {
        window?.firstResponder === textView
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        prompt.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        prompt.translatesAutoresizingMaskIntoConstraints = false
        addSubview(prompt)

        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.isVerticallyResizable = true
        textView.delegate = self
        textView.onSubmit = { [weak self] in self?.submit() }
        textView.onLeave = { [weak self] in self?.onLeave?() }
        textView.onForwardKey = { [weak self] event in self?.onForwardKey?(event) }
        textView.onHistoryStep = { [weak self] step in
            guard let self else { return }
            // 후보 목록이 떠 있으면 방향키는 목록을 고르는 데 쓴다.
            if completions.isShowing {
                completions.moveSelection(by: step < 0 ? -1 : 1)
                return
            }
            guard let recalled = onHistoryStep?(step) else { return }
            text = recalled
        }
        textView.onComplete = { [weak self] in self?.completeToken() }
        textView.onDismiss = { [weak self] in
            guard let self, completions.isShowing else { return false }
            completions.hide()
            return true
        }

        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        hint.font = .systemFont(ofSize: 10)
        hint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hint)

        let height = heightAnchor.constraint(equalToConstant: 34)
        heightConstraint = height
        NSLayoutConstraint.activate([
            height,
            prompt.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            prompt.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalPadding),

            scrollView.leadingAnchor.constraint(equalTo: prompt.trailingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalPadding),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalPadding),

            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            hint.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        applyFontSize(fontSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 모양

    func apply(colors: ChromeColors) {
        self.colors = colors
        completions.apply(colors: colors)
        // 터미널 배경에서 살짝 들어 올린 색. 같은 색이면 어디까지가 입력
        // 상자인지 알 수 없고, 다른 색을 쓰면 창 안에 딴 물건이 얹힌다.
        let lift: CGFloat = colors.isDark ? 0.06 : 0.04
        layer?.backgroundColor = colors.background
            .blended(withFraction: lift, of: colors.foreground)?.cgColor
            ?? colors.background.cgColor
        prompt.textColor = colors.foreground.withAlphaComponent(0.8)
        hint.textColor = colors.foreground.withAlphaComponent(0.35)
        textView.textColor = colors.foreground
        textView.insertionPointColor = colors.foreground
        textView.selectedTextAttributes = [
            .backgroundColor: colors.selection,
            .foregroundColor: colors.foreground,
        ]
        needsDisplay = true
    }

    func applyFontSize(_ size: Float) {
        fontSize = size
        let font = NSFont(name: FontPreferences.monoFamily(), size: CGFloat(size))
            ?? .monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
        textView.font = font
        prompt.font = font
        refreshHeight()
    }

    func focus() {
        window?.makeFirstResponder(textView)
        refreshHint()
    }

    /// 상자가 다른 pane으로 옮겨 붙거나 글이 통째로 바뀔 때 목록을 접는다.
    func hideCompletions() {
        completions.hide()
    }

    /// 창이 넘겨 준 첫 글자. 상자로 포커스를 옮기고 그 키를 여기서 받는다.
    func beginTyping(with event: NSEvent) {
        focus()
        textView.keyDown(with: event)
    }

    /// 위쪽 경계선. 상자와 터미널이 같은 계열 색이라 선이 없으면 붙어 보인다.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        colors.foreground.withAlphaComponent(0.14).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    // MARK: - 동작

    /// Tab. 목록이 떠 있으면 고른 것을 넣고, 아니면 후보를 찾는다.
    private func completeToken() {
        if completions.isShowing, let candidate = completions.selectedCandidate {
            apply(candidate: candidate)
            return
        }

        let caret = textView.selectedRange().location
        guard let result = CommandCompletion.complete(
            text: textView.string,
            caret: caret,
            workingDirectory: workingDirectory()
        ) else { return }

        // 후보가 하나면 바로 넣는다. 여럿이면 공통 앞부분까지만 채우고 목록을
        // 띄운다 — 셸에서 Tab을 눌렀을 때와 같은 순서다.
        if result.candidates.count == 1 {
            apply(candidate: result.candidates[0])
            return
        }

        let token = (textView.string as NSString).substring(with: result.range)
        if result.commonPrefix.count > token.count {
            replaceToken(at: result.range, with: result.commonPrefix)
        }
        showCompletions(result.candidates)
    }

    private func apply(candidate: String) {
        let caret = textView.selectedRange().location
        let range = NSRange(
            location: CommandCompletion.tokenStart(in: Array(textView.string.utf16), before: caret),
            length: 0
        )
        let tokenRange = NSRange(location: range.location, length: caret - range.location)
        replaceToken(at: tokenRange, with: candidate)
        completions.hide()
    }

    private func replaceToken(at range: NSRange, with replacement: String) {
        guard let storage = textView.textStorage else { return }
        storage.replaceCharacters(in: range, with: replacement)
        textView.setSelectedRange(NSRange(location: range.location + replacement.utf16.count, length: 0))
        textView.didChangeText()
    }

    private func showCompletions(_ candidates: [String]) {
        guard let host = superview else { return }
        if completions.superview !== host {
            completions.removeFromSuperview()
            completions.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(completions)
            NSLayoutConstraint.activate([
                completions.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                completions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                completions.bottomAnchor.constraint(equalTo: topAnchor, constant: -4),
            ])
        }
        completions.apply(colors: colors)
        completions.show(candidates)
    }

    private func submit() {
        completions.hide()
        let value = textView.string
        onSubmit?(value)
        textView.string = ""
        onTextChange?("")
        refreshHeight()
        refreshHint()
    }

    private func refreshHint() {
        hint.isHidden = !textView.string.isEmpty
    }

    /// 내용에 맞춰 높이를 늘린다. 한 줄이면 한 줄만큼만 차지한다.
    private func refreshHeight() {
        guard
            let layoutManager = textView.layoutManager,
            let container = textView.textContainer
        else { return }
        layoutManager.ensureLayout(for: container)

        let lineHeight = textView.font.map { $0.ascender - $0.descender + $0.leading } ?? 16
        let used = layoutManager.usedRect(for: container).height
        let capped = min(max(used, lineHeight), lineHeight * CGFloat(Self.maxVisibleLines))
        heightConstraint?.constant = ceil(capped + Self.verticalPadding * 2)
    }
}

// MARK: - NSTextViewDelegate

extension CommandComposerView: NSTextViewDelegate {
    func textDidChange(_: Notification) {
        // 글이 바뀌면 떠 있던 후보는 더 이상 그 토큰의 것이 아니다.
        if completions.isShowing { completions.hide() }
        refreshHeight()
        refreshHint()
        onTextChange?(textView.string)
    }
}

// MARK: - 키 처리

/// 상자 안에서 어떤 키를 우리가 쓰고 어떤 키를 셸에 넘길지 정하는 자리.
@MainActor
private final class ComposerTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onLeave: (() -> Void)?
    var onForwardKey: ((NSEvent) -> Void)?
    var onHistoryStep: ((Int) -> Void)?
    var onComplete: (() -> Void)?
    /// esc를 목록이 먼저 먹었는지. true면 상자에 그대로 머문다.
    var onDismiss: (() -> Bool)?

    /// 셸에 그대로 넘길 제어키. 멈추기(⌃C), 파일 끝(⌃D), 잠시 멈추기(⌃Z),
    /// 히스토리 찾기(⌃R), 화면 지우기(⌃L), 코어 덤프(⌃\)다. 나머지 제어키는
    /// 글 편집에 쓰이므로 상자가 그대로 갖는다.
    private static let forwarded: Set<String> = ["c", "d", "z", "r", "l", "\\"]

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.control), !flags.contains(.command) {
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if Self.forwarded.contains(key) {
                onForwardKey?(event)
                return
            }
            // ⌃U는 셸에서 줄을 지우는 키다. 상자에서는 상자를 비운다.
            if key == "u" {
                string = ""
                didChangeText()
                return
            }
        }

        // Return. ⇧⏎ / ⌥⏎는 줄바꿈이고 그냥 ⏎는 실행이다.
        if event.keyCode == 36 {
            if flags.contains(.shift) || flags.contains(.option) {
                insertNewlineIgnoringFieldEditor(nil)
                return
            }
            onSubmit?()
            return
        }

        // Tab은 우리가 완성한다. 셸로 넘겨 봐야 셸은 상자에 쓴 글을 모른다.
        if event.keyCode == 48 {
            if string.isEmpty {
                // 빈 상자에서는 셸에게 넘긴다 — 프롬프트에 이미 쳐 둔 것이
                // 있으면 그쪽을 완성해야 한다.
                onForwardKey?(event)
                return
            }
            onComplete?()
            return
        }

        super.keyDown(with: event)
    }

    override func cancelOperation(_: Any?) {
        // 후보 목록이 떠 있으면 esc는 목록만 닫는다.
        if onDismiss?() == true { return }
        onLeave?()
    }

    override func moveUp(_ sender: Any?) {
        guard isCaretOnFirstLine else { return super.moveUp(sender) }
        onHistoryStep?(-1)
    }

    override func moveDown(_ sender: Any?) {
        guard isCaretOnLastLine else { return super.moveDown(sender) }
        onHistoryStep?(1)
    }

    /// 여러 줄을 쓰는 중에는 방향키가 히스토리를 건드리지 않아야 한다.
    private var isCaretOnFirstLine: Bool {
        let caret = selectedRange().location
        guard let upTo = Range(NSRange(location: 0, length: caret), in: string) else { return true }
        return !string[upTo].contains("\n")
    }

    private var isCaretOnLastLine: Bool {
        let caret = selectedRange().location
        let length = string.utf16.count
        guard
            caret <= length,
            let rest = Range(NSRange(location: caret, length: length - caret), in: string)
        else { return true }
        return !string[rest].contains("\n")
    }
}
