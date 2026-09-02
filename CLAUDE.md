# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
make build      # swift build
make run        # build + run the binary directly (no .app bundle)
make test       # swift test (swift-testing)
make bundle     # produce MyTerminal.app (needed to test resource-dependent behavior)
make clean      # swift package clean
```

`make run` launches the raw binary, which is fine for window/menu/theme work. Anything that depends on Ghostty's shell integration (command-finished events, pwd reporting) needs `make bundle && open MyTerminal.app`, because `bundle` is what copies `GhosttyKit_GhosttyTerminal.bundle` (shell-integration scripts + terminfo) into `Contents/Resources`.

`make test` sets `DEVELOPER_DIR` to Xcode and builds into `.build/test`. Both halves matter. Plain `swift test` fails with `no such module 'Testing'` when `xcode-select` points at the Command Line Tools, because swift-testing lives in Xcode's toolchain and the CLT ships no XCTest at all; and the two toolchains ship different Swift versions, so sharing `.build` makes each reject the other's modules (`module compiled with Swift 6.2.1 cannot be imported by the Swift 6.3.2 compiler`). Keep the scratch path separate when invoking `swift test` by hand.

Run one suite or one test with the Swift identifier, not the display name:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --scratch-path .build/test --filter GitTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --scratch-path .build/test --filter reusesExistingBranch
```

Tests cover the model and git layers (`Git`, `ProjectStore`, branch naming). The AppKit layer has no coverage — verify it by running the app.

## Architecture

SwiftPM executable, no Xcode project, no nibs/storyboards. `main.swift` is top-level code that hand-builds `NSApplication` inside `MainActor.assumeIsolated` — there is no `@main`. Every type in the app is `@MainActor`.

The terminal itself is not implemented here. `libghostty-spm` ships libghostty as a prebuilt XCFramework plus Swift views; this app supplies the window, menu, theme, and font policy around it. Ghostty owns the PTY and spawns the user's login shell (`backend: .exec`, the default).

### Ownership and state flow

```
AppDelegate           holds fontSize, theme, ProjectStore, WorkspaceStore,
                      SessionSnapshotStore, SettingsStore — the single source of truth
  └─ [TerminalWindowController]      one window = sidebar + tab bar + session container
       ├─ ProjectSidebarViewController
       ├─ TabBarView
       ├─ [SidebarSelection: TabGroup]        배치만 아는 값 타입 (탭 목록 + SplitTree)
       ├─ [UUID: TerminalSession]             pane 아이디 → 살아 있는 셸
       └─ [UUID: SplitLayoutView]             탭 아이디 → 그 탭의 화면
            └─ TerminalView + TerminalController   = one Ghostty surface = one shell
```

State moves one way. `AppDelegate` mutates its own state, then fans it out to every window (`applyFontSize`, `applyTheme`, `reloadProjects`), which fans it down to every session. Windows and sidebars never write back — they only ask, by reaching for `NSApp.delegate as? AppDelegate`. New windows read the current values at init, so they open matching the existing ones. When adding a new global setting, follow this shape: store it on `AppDelegate`, add a fan-out method on the window controller, and pass it through `TerminalWindowController.init`.

배치와 세션은 갈라 둔다. `TabGroup`/`SplitTree`는 pane 아이디만 아는 값 타입이라 AppKit 없이 검증할 수 있고 그대로 `workspace.json`에 실린다. 세션 객체는 창이 아이디로 따로 들고 있다. 창이 화면을 모델에 맞추는 자리는 `syncViews()` 한 곳이므로, 탭·분할을 건드리는 새 명령은 모델을 고친 뒤 거기로 보내면 된다.

Terminal configuration is assembled once in a builder closure inside `TerminalSession.init`. Runtime changes go through `controller.setTerminalConfiguration(...)` / `controller.setTheme(...)` rather than rebuilding the surface.

**Every session builds its own `TerminalController`.** This is not incidental: `TerminalController.onWakeup` and `shouldProcessWakeup` are single slots, not lists, and `TerminalSurfaceCoordinator` overwrites them each time it builds a surface. Two surfaces sharing one controller would leave the earlier one unable to drain ghostty's mailbox — no repaints, no title updates, and eventually a blocked write thread. Do not "optimize" this into a shared controller.

### Projects and sessions

A project is a directory (default `~/MyTerminal/<name>`) holding one git worktree per repository added to it. The terminal opens on the *project* directory, not on any repository, so tools that write history where they run — claude in particular — accumulate it per project instead of scattering it across repos.

- The project's own `.myterminal.json` is the source of truth for its contents. `~/Library/Application Support/dev.local.myterminal/projects.json` holds nothing but the list of project directory paths, so a project directory stays portable and a directory that fails to read is skipped in memory rather than pruned from the index.
- Worktrees go on a branch named after the project (`myterminal/<slug>`). They have to: git refuses to check out a branch another worktree already holds, so a per-project branch is what lets the same repository join more than one project.
- Duplicate detection compares `git rev-parse --git-common-dir`, which is identical across every worktree of a repository. Picking a worktree instead of the original still gets caught.
- `Git.addWorktree` checks `worktree list --porcelain` for the branch *before* attempting the add. git would refuse anyway, but only with "is already used by worktree at …" — checking first lets the error name the occupying path so the user knows what to move.
- Removing a project runs `git worktree remove` (never `--force`) for each repository first, and only drops it from the list if every one succeeded; the project directory goes too, but only when nothing survives except our own marker file. A blocked worktree leaves the project in the list holding just the repositories that could not be cleaned, and the follow-up alert offers a list-only removal so a dirty worktree can't trap a project in the sidebar forever.
- Sessions are created on first visit to a project and kept afterwards, so switching preserves each shell and its scrollback. Only the active one draws; the rest stay attached and occluded (`TerminalSession.setVisible`) because an occluded surface still ticks, which is what keeps titles, pwd, and child-exit events flowing.
- `SidebarSelection.home` is the no-project shell, and it is what the app opens as. Exiting it closes the window, the way the app behaved before projects existed; exiting a project's shell only drops that pane.

### Tabs, panes, and windows

- 탭은 사이드바 선택에 속한다. `groups[.project(id)]`가 그 프로젝트의 탭 목록이고, 사이드바를 바꾸면 탭바가 통째로 교체된다. 탭이 하나면 탭바를 감춘다 — 그러면 탭을 안 쓰는 사람에게는 탭이 생기기 전과 같은 화면이다.
- 탭마다 `SplitLayoutView` 하나를 만들어 컨테이너에 붙여 두고, 탭을 바꿀 때는 감추기만 한다. 뷰를 떼면 surface가 살아 있어도 디스플레이 링크가 멈추고, 다시 붙일 때 `viewDidMoveToWindow`가 기존 surface를 그대로 쓰기 때문에 스크롤백은 유지된다 — 그래도 감추는 편이 재부착 경로를 타지 않아 단순하다.
- pane마다 컨테이너 뷰를 하나 두고 세션 뷰는 그 안에 붙박이로 둔다. 분할이 바뀔 때 옮겨 다니는 것은 컨테이너뿐이라 포커스 테두리를 그릴 자리가 생기고 제약을 매번 다시 걸 일도 없다.
- **분할선 초기 배분은 `setPosition(_:ofDividerAt:)`으로 한다.** 자식 프레임을 써 놓고 `adjustSubviews()`를 부르면 NSSplitView가 이전 비율을 기준으로 다시 나눠, 새로 끼운 pane이 폭 0으로 남고 먼저 있던 pane이 전부 가져간다. 배분은 처음 크기를 받을 때 한 번만 한다 — 매번 하면 사용자가 끌어 놓은 위치가 창 크기를 바꿀 때마다 초기화된다.
- 창 사이 이동은 세션 객체를 그대로 넘긴다(`detachActiveTab` / `detachAllTabs` / `adopt`). 넘기기 전에 `session.view.removeFromSuperview()`를 부르는 것이 중요하다 — `removeFromSuperview()`가 그 뷰를 가리키는 제약까지 걷어내므로 새 창의 pane 컨테이너에서 옛 제약과 부딪치지 않는다. 탭을 다 내보낸 창은 스스로 닫는다.
- pane 포커스는 `TerminalSurfaceFocusDelegate`로 따라간다. 포커스를 얻은 쪽만 반영하고 잃은 쪽은 무시한다 — 창이 키를 잃을 때도 같은 값이 오므로, 그걸로 활성 pane을 지우면 창을 다시 눌렀을 때 어디가 활성이었는지 잊는다.
- 방향키 pane 이동은 좌표가 아니라 트리 구조로 이웃을 고른다(`SplitTree.neighbor`). 세 겹 이상 뒤섞인 배치에서는 사람이 기대한 pane과 다를 수 있고, 그때는 프레임 기반으로 바꿔야 한다.

### Command composer

pane 아래에 붙는 `CommandComposerView`가 셸의 줄 편집을 대신한다. 실행은 두 단계다 — `session.view.sendText(text)`로 붙여넣고(bracketed paste라 여러 줄이 한 덩어리로 들어간다) 곧바로 합성한 Return `keyDown`을 보낸다. 사이에 기다릴 필요는 없다: PTY로 나가는 바이트는 순서가 보장되므로 셸이 붙여넣기를 다 읽은 뒤 Return을 본다. 실측으로 `echo AAA\necho BBB`가 두 줄 다 실행됨을 확인했다.

- 상자는 창에 하나뿐이고 포커스한 pane 아래로 옮겨 붙는다(`SplitLayoutView.attachComposer`). pane마다 쓰다 만 글은 창이 `drafts`로 따로 들고 있다가 포커스가 옮겨 갈 때 넣어 준다.
- **타이핑 가로채기는 `TerminalHostWindow.sendEvent`에서 한다.** responder chain보다 앞이어야 첫 글자를 놓치지 않는다 — 터미널 뷰가 키를 먹은 뒤에는 되돌릴 자리가 없고, 한글은 첫 자모를 놓치면 조합이 깨진다.
- 가로채지 않는 경우가 셋이다: 상자를 껐을 때, Esc로 나갔을 때(`typingRedirectSuspended`), 그리고 우리가 보낸 명령이 아직 돌고 있을 때(`runningCommands`). 셋째가 vim·htop을 살린다. 이 신호는 `terminalDidFinishCommand` 하나뿐이므로 `TerminalSession`이 그 이벤트를 반드시 창까지 전달해야 한다 — 전달을 빼먹으면 첫 명령 이후 타이핑이 영구히 터미널로만 간다(실제로 한 번 그랬다).
- 상자가 셸로 그대로 넘기는 키는 ⌃C·⌃D·⌃Z·⌃R·⌃L·⌃\와 (상자가 비었을 때의) Tab이다. 나머지 제어키는 글 편집에 쓰이므로 상자가 갖는다. 프롬프트가 떴는지 알려 주는 이벤트가 패키지에 없어서, 이 목록이 "셸에 있어야 하는 키"를 대신한다.
- 상자를 켤지는 `SettingsStore`에, 히스토리와 쓰다 만 글은 `workspace.json`에 남는다. 히스토리 규칙(연속 중복 제거·상한·되부르기 커서)은 `CommandHistory`에 값 타입으로 떼어 두어 화면 없이 검증한다.

### Restart: layout and screen contents

두 가지를 따로 저장한다. **배치**는 `workspace.json`(창 크기, 사이드바 선택, 탭 목록, 분할 트리, pane별 작업 디렉터리), **화면에 있던 글자**는 `sessions/<paneID>.txt`다. 세션 아이디를 저장하는 이유가 이것이다 — 아이디가 유지돼야 화면 기록이 같은 pane으로 돌아간다.

- 저장은 0.5초 모았다 한 번 쓴다. 창을 끌어 옮기는 동안 프레임 변경이 초당 수십 번 들어온다. 종료할 때만 `flush`로 바로 쓴다.
- 복원한 탭은 셸을 바로 띄우지 않는다. 보이는 탭만 깨우고(`wakeSessions`) 나머지는 `dormantSessions`에 배치만 들고 기다린다. 탭 스무 개를 되살리며 셸 스무 개를 한꺼번에 띄우면 그만큼 느려진다.
- **화면을 뜨는 길은 클립보드뿐이다.** libghostty의 텍스트 읽기 API는 패키지 밖으로 열려 있지 않고(`TerminalSurface.readSelection`은 internal), 클립보드 쓰기 콜백도 곧장 `NSPasteboard.general`로 쓴다(`Controller/TerminalController+Callbacks.swift`의 `writeClipboard`). 그래서 `select_all` + `copy_to_clipboard`를 거치고, 앞뒤로 클립보드를 보관했다 되돌린다. 이 순서를 바꾸면 사용자가 종료 직전 복사해 둔 것을 훔쳐 간다.
- 되찍기는 `command`를 `sh -c 'cat "$MYTERMINAL_RESTORE"; exec "$MYTERMINAL_SHELL" -l'`로 바꿔 한다. 경로는 **반드시 환경변수로** 넘긴다 — Application Support 경로에 공백이 있어 명령 문자열에 박으면 단어가 갈린다. 명령을 바꾸면 ghostty의 셸 종류 자동 감지가 걸리지 않으므로 `shell-integration`을 명시로 준다. 모르는 셸이면 감싸지 않는다(`LoginShell`) — 복원을 포기하는 편이 셸을 망가뜨리는 것보다 낫다.
- **`script(1)`로 출력을 계속 기록하는 방식은 시도했고 버렸다.** PTY가 한 겹 더 생기는데 macOS 26.6.2의 script는 창 크기 변경(SIGWINCH)을 안쪽 셸로 넘기지 않는다(`-F`를 붙여도 같다). 안쪽 PTY의 master fd는 script만 갖고 있어 우리가 손댈 방법도 없다. 그래서 색과 TUI 화면은 복원 대상이 아니고, 평문만 되찍는다.
- 안에서 돌던 프로세스는 살아나지 않는다. PTY를 우리가 갖고 있지 않아 방법이 없다.

`Git` shells out to `/usr/bin/git` off the main thread — a worktree checkout unpacks a whole working tree and would visibly freeze the window otherwise. It routes stdout and stderr through temp files rather than pipes; a pipe's 64KB buffer filling would park git in `write()` while we wait on an exit that never comes.

### Menu

`AppDelegate.buildMainMenu()` constructs `NSMenu` in code from `(title, selector, keyEquivalent)` tuples; an empty title means separator. Items are created with `target = nil` on purpose so the action travels the responder chain — that is how the focused terminal view gets `copy:`, how `NSSplitViewController` gets `toggleSidebar:`, and how the app delegate itself gets `newProject:`. The Theme submenu is the deliberate exception: those items set `target = self` and carry the `AppTheme` in `representedObject`.

An uppercase `keyEquivalent` implies Shift, which is how `New Project…` reads as ⇧⌘N without extra wiring. Anything needing a different modifier is fixed up after the fact on the returned menu (`keyEquivalentModifierMask`) rather than by widening the tuple.

### Shell-integration events

The delegate conformances at the bottom of `TerminalSession.swift` (`TerminalSurfaceCommandFinishedDelegate`, `TerminalSurfacePwdDelegate`, `TerminalSurfaceLifecycleDelegate`, …) are the event feed for prompt/command boundaries, working directory, and exit codes. They currently only log. They are the intended raw material for the roadmap features in the README (command blocks, AI error explanation, session history). More delegate protocols are available in the package at `.build/checkouts/libghostty-spm/Sources/GhosttyTerminal/Surface/TerminalSurfaceViewDelegate.swift`.

### Themes

`AppTheme` is a `String`-backed enum with two kinds of cases. `signature` uses palettes defined inline as `TerminalConfiguration` extensions in `AppTheme.swift`. Every other named theme loads by name from the bundled iTerm2 collection, so its `rawValue` must match the `GhosttyThemeCatalog` name exactly — adding a catalog theme means adding the case plus a `displayName` arm, nothing else. Themes resolve to a `TerminalTheme(light:dark:)` pair so light/dark follow system appearance.

The sidebar paints itself in the same colors, which `AppTheme.chrome(systemIsDark:)` supplies. `TerminalConfiguration` never hands back a color it was given, so the signature and Ghostty-default values are declared once as `ThemeHex` constants that both the config builders and `chrome` read; only catalog themes can be queried directly. If you add a hand-written palette, put its base colors in a `ThemeHex` rather than inlining hex into the builder, or the sidebar will drift away from the terminal.

`applyChrome()` pins `window.appearance` only for themes that choose their own darkness. Themes with `followsSystemAppearance` are left alone: forcing an appearance on them propagates through the terminal view to `TerminalController.setColorScheme` and permanently locks the auto light/dark switch they exist for.

### Fonts

`FontPreferences` picks the first installed family from a candidate list, then maps Hangul codepoint ranges to a Korean mono font via `font-codepoint-map`. Ghostty requires the `U+` prefix on **both** ends of a range. Only Hangul is force-mapped — Arabic, Devanagari, Japanese, and Chinese are intentionally left to CoreText so shaping and joining are not broken by a Korean font.

The mapping is gated on `fitsCellGrid`, and that gate is load-bearing. Ghostty stretches a mapped glyph to fill its cell box, so mapping a face whose Hangul advance is not exactly twice the primary font's cell width blows the glyphs up next to the Latin text around them. Menlo (7.83pt per cell) plus Apple SD Gothic Neo (`가` at 11.25pt) came out 1.39× oversized, which is the bug this check exists to prevent. Only real Hangul *coding* fonts belong in the candidate list; when none is installed the map is skipped entirely and CoreText falls back on its own — same as every other script.

같은 폰트가 배포판마다 다른 이름으로 등록되므로(D2Coding은 `D2Coding`/`D2CodingLigature`, Sarasa는 폭 방식마다 Mono/Term/Fixed) 후보 목록에 알려진 이름을 모두 적는다. 하나도 없으면 로그로 한 줄 알리고 넘어간다 — 폴백(Apple SD Gothic Neo)은 `가`가 라틴 두 칸의 0.72배라 한글이 섞인 줄에서 열이 어긋난다. 자동 설치는 하지 않는다. 폭 판정은 `fitsCellGrid(hangulWidth:cellWidth:)`로 떼어 두어 설치된 폰트에 기대지 않고 검증한다.

## Conventions

- Comment language is split by audience: domain/product decisions (themes, font policy) are commented in Korean, low-level plumbing (AppKit wiring, actor isolation, logging) in English. Match whichever file you are in.
- Comments explain *why* a non-obvious choice was made (responder chain targeting, stderr logging, pinned dependency range). Don't add comments that restate the code.
- `Log.info` writes to stderr unbuffered so output survives a `SIGTERM`; don't switch it to `print`.
- The `libghostty-spm` dependency is declared `from: "1.4.0"` because libghostty's C API is not stable. Do not bump it as a side effect of another change. 다만 업스트림이 1.4.0 태그를 지워서 이 범위에서 실제로 잡히는 버전은 1.5.1뿐이다(그 아래는 1.3.2). 되돌리려면 매니페스트를 고쳐야 한다.
- 상태를 디스크에 남기는 타입은 넷이고 모두 같은 모양이다: 경로를 init 인자로 주입할 수 있고(테스트가 진짜 Application Support를 안 건드린다), `JSONEncoder` + `.atomic`으로 통째로 쓴다. `ProjectStore`(프로젝트 색인), `WorkspaceStore`(창·탭·분할 배치), `SessionSnapshotStore`(pane 화면 기록), `SettingsStore`(테마·폰트 크기). 새 저장소를 만들 때 이 모양을 따르면 테스트도 같은 방식으로 붙는다.

## Known gaps between docs and code

The README documents `make smoke`, which does not exist: the Makefile has no `smoke` target. `Support/smoke-command.sh` is present and expects `MYTERMINAL_SMOKE_MARKER`, but no harness invokes it. `Package.swift` also references `docs/roadmap.md`, which does not exist (`docs/` contains only an empty `research/`). Treat these as unimplemented, not as behavior to preserve.
