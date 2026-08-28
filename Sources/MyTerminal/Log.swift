import Foundation

/// Stdout logger used for lifecycle milestones. Keeps smoke tests honest:
/// everything printed here is observable from the launching process.
///
/// stderr (unbuffered) rather than `print` (block-buffered when redirected):
/// a SIGTERM'd process must not lose what it already reported.
enum Log {
    static func info(_ message: @autoclosure () -> String) {
        let line = "[myterminal] \(message())\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
    }
}
