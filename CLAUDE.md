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
AppDelegate                  holds fontSize, theme, ProjectStore — the single source of truth
  └─ [TerminalWindowController]      one window = sidebar + session container
       ├─ ProjectSidebarViewController
       └─ [SidebarSelection: TerminalSession]
            └─ TerminalView + TerminalController   = one Ghostty surface = one shell
```

State moves one way. `AppDelegate` mutates its own state, then fans it out to every window (`applyFontSize`, `applyTheme`, `reloadProjects`), which fans it down to every session. Windows and sidebars never write back — they only ask, by reaching for `NSApp.delegate as? AppDelegate`. New windows read the current values at init, so they open matching the existing ones. When adding a new global setting, follow this shape: store it on `AppDelegate`, add a fan-out method on the window controller, and pass it through `TerminalWindowController.init`.

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

## Conventions

- Comment language is split by audience: domain/product decisions (themes, font policy) are commented in Korean, low-level plumbing (AppKit wiring, actor isolation, logging) in English. Match whichever file you are in.
- Comments explain *why* a non-obvious choice was made (responder chain targeting, stderr logging, pinned dependency range). Don't add comments that restate the code.
- `Log.info` writes to stderr unbuffered so output survives a `SIGTERM`; don't switch it to `print`.
- The `libghostty-spm` dependency is pinned `from: "1.4.0"` because libghostty's C API is not stable. Do not bump it as a side effect of another change.

## Known gaps between docs and code

The README documents `make smoke` and a `MYTERMINAL_THEME` startup env var. Neither exists: the Makefile has no `smoke` target, and nothing in `Sources/` reads `MYTERMINAL_THEME`. `Support/smoke-command.sh` is present and expects `MYTERMINAL_SMOKE_MARKER`, but no harness invokes it. `Package.swift` also references `docs/roadmap.md`, which does not exist (`docs/` contains only an empty `research/`). Treat these as unimplemented, not as behavior to preserve.
