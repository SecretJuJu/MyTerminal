import AppKit

// Top-level executable entry. AppKit needs a live NSApplication on the main
// thread; `MainActor.assumeIsolated` bridges the top-level context (same
// pattern as the libghostty-spm example app).
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    app.run()
    fatalError()
}
