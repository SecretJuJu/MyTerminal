import AppKit

/// 프로젝트·저장소를 추가할 때 쓰는 작은 시트의 공통 뼈대.
///
/// 제목, 설명, 폼, 오류 줄, 버튼 한 줄이 전부다. 오류는 시트를 닫지 않고
/// 그 자리에 보여 준다 — 경로를 잘못 쳤을 때 처음부터 다시 열게 만들 이유가 없다.
@MainActor
class FormSheet: NSWindowController {
    private static let contentWidth: CGFloat = 460
    private static let formWidth: CGFloat = 420

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let cancelButton = NSButton(title: "취소", target: nil, action: nil)
    private let confirmButton = NSButton(title: "", target: nil, action: nil)

    /// 시트가 닫힌 뒤 부른다. 시트를 붙잡고 있던 쪽이 놓아 줄 자리다.
    var onDismiss: (() -> Void)?

    init(title: String, subtitle: String, confirmTitle: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: FormSheet.contentWidth, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        titleLabel.stringValue = title
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        subtitleLabel.stringValue = subtitle
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        Self.makeWrapping(subtitleLabel)

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.isHidden = true
        Self.makeWrapping(errorLabel)

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped(_:))

        confirmButton.title = confirmTitle
        confirmButton.bezelStyle = .rounded
        confirmButton.keyEquivalent = "\r"
        confirmButton.target = self
        confirmButton.action = #selector(confirmTapped(_:))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [progress, spacer, cancelButton, confirmButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [
            titleLabel,
            subtitleLabel,
            makeForm(),
            errorLabel,
            buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalToConstant: Self.formWidth),
        ])
        window.contentView = content
        window.setContentSize(content.fittingSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 하위 클래스가 채우는 부분

    /// 시트마다 다른 입력 칸. `init` 안에서 한 번 불린다.
    func makeForm() -> NSView {
        NSView()
    }

    /// 확인 버튼을 눌렀을 때. 작업이 끝나면 `dismiss()`나 `show(error:)`를 부른다.
    func confirm() {}

    // MARK: - 표시

    func present(over parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onDismiss?()
            }
        }
    }

    func dismiss() {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }

    func setBusy(_ busy: Bool) {
        confirmButton.isEnabled = !busy
        cancelButton.isEnabled = !busy
        if busy {
            progress.startAnimation(nil)
        } else {
            progress.stopAnimation(nil)
        }
    }

    func show(error: String?) {
        errorLabel.stringValue = error ?? ""
        errorLabel.isHidden = error == nil
        guard let content = window?.contentView else { return }
        content.layoutSubtreeIfNeeded()
        window?.setContentSize(content.fittingSize)
    }

    // MARK: - 만들기 도우미

    static func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        return field
    }

    static func pathField(placeholder: String) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingHead
        return field
    }

    /// 디렉터리 선택 패널을 시트 위에 겹쳐 연다. 경로를 직접 치는 사람과
    /// 탐색기로 고르는 사람이 같은 칸을 채운다.
    static func chooseDirectory(
        startingAt: URL?,
        over window: NSWindow,
        completion: @escaping (URL) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = startingAt
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                completion(url)
            }
        }
    }

    /// 사용자가 붙여 넣은 경로를 그대로 쓸 수 있게 다듬는다. 터미널이나
    /// Finder에서 끌어온 경로에는 따옴표가 붙어 오는 일이 흔하다.
    static func normalizedPath(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for quote in ["\"", "'"] where text.count >= 2
            && text.hasPrefix(quote) && text.hasSuffix(quote)
        {
            text = String(text.dropFirst().dropLast())
        }
        return (text as NSString).expandingTildeInPath
    }

    private static func makeWrapping(_ field: NSTextField) {
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.preferredMaxLayoutWidth = formWidth
    }

    @objc private func cancelTapped(_: Any?) {
        dismiss()
    }

    @objc private func confirmTapped(_: Any?) {
        show(error: nil)
        confirm()
    }
}
