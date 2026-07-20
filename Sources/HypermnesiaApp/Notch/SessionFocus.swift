import AppKit
import HypermnesiaKit

/// "One click back to that exact session": resolve the event's host app from the pid chain the
/// hook recorded and bring the session forward — the exact iTerm2/Terminal tab via its tty when
/// possible, an IDE window via its URL scheme, else plain app activation.
@MainActor
enum SessionFocus {
    /// Returns `true` only when a host app was actually activated / opened. A session hosted under
    /// tmux, screen or SSH has no GUI app in its pid chain and no `.app` on disk to relaunch, so
    /// there is nothing session-specific to jump to — that returns `false`, letting the caller keep
    /// the card up instead of dismissing it into a silent no-op.
    @discardableResult
    static func focus(_ event: SessionEvent) -> Bool {
        // Nearest ancestor that is a real GUI app = the terminal/IDE hosting the session.
        let host = event.hostPids.lazy
            .compactMap { NSRunningApplication(processIdentifier: $0) }
            .first { $0.activationPolicy != .prohibited }

        if let host {
            if let tty = sanitizedTTY(event.tty), let bundleId = host.bundleIdentifier,
               let script = terminalTabScript(bundleId: bundleId, tty: tty),
               runAppleScript(script) {
                return true   // the script selects the tab and activates the app
            }
            if let bundleId = host.bundleIdentifier, let scheme = Self.ideSchemes[bundleId],
               let cwd = event.cwd,
               let encoded = cwd.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
               let url = URL(string: "\(scheme)://file\(encoded)") {
                NSWorkspace.shared.open(url)   // routes to the window with that folder open
                return true
            }
            if let bundleURL = host.bundleURL {
                NSWorkspace.shared.openApplication(at: bundleURL, configuration: NSWorkspace.OpenConfiguration())
            } else {
                host.activate()
            }
            return true
        }

        // Host processes are gone (terminal quit since the event) — relaunch/activate its .app.
        if let bundleURL = event.hostPaths.lazy.compactMap(bundleURL(fromExecutablePath:)).first {
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: NSWorkspace.OpenConfiguration())
            return true
        }

        // No GUI host resolvable (tmux/screen/ssh): don't leave the click a silent no-op — surface
        // the app so there's visible feedback — and report failure so the card isn't dismissed.
        WindowSupport.bringToFront()
        return false
    }

    /// IDEs whose `<scheme>://file<path>` deep link focuses the window that has the folder open.
    private static let ideSchemes: [String: String] = [
        "com.todesktop.230313mzl4w4u92": "cursor",       // Cursor
        "com.microsoft.VSCode": "vscode",
        "com.microsoft.VSCodeInsiders": "vscode-insiders",
    ]

    /// tty device names are `ttys` + digits; anything else is dropped rather than spliced into a
    /// script.
    private static func sanitizedTTY(_ tty: String?) -> String? {
        guard let tty, !tty.isEmpty, tty.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return tty
    }

    /// AppleScript that selects the window/tab whose tty matches, returning true when found.
    /// First use prompts for Automation permission; a decline just falls back to app activation.
    private static func terminalTabScript(bundleId: String, tty: String) -> String? {
        switch bundleId {
        case "com.googlecode.iterm2":
            return """
            tell application "iTerm2"
                repeat with aWindow in windows
                    repeat with aTab in tabs of aWindow
                        repeat with aSession in sessions of aTab
                            if tty of aSession is "/dev/\(tty)" then
                                select aWindow
                                select aTab
                                select aSession
                                activate
                                return true
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return false
            """
        case "com.apple.Terminal":
            return """
            tell application "Terminal"
                repeat with aWindow in windows
                    repeat with aTab in tabs of aWindow
                        if tty of aTab is "/dev/\(tty)" then
                            set selected of aTab to true
                            set index of aWindow to 1
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end tell
            return false
            """
        default:
            return nil
        }
    }

    private static func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return false }
        return result.booleanValue
    }

    /// `/Applications/iTerm.app/Contents/MacOS/iTerm2` → `/Applications/iTerm.app`.
    private static func bundleURL(fromExecutablePath path: String) -> URL? {
        guard let range = path.range(of: ".app/", options: .backwards) else { return nil }
        let bundlePath = String(path[..<range.lowerBound]) + ".app"
        guard FileManager.default.fileExists(atPath: bundlePath) else { return nil }
        return URL(fileURLWithPath: bundlePath)
    }
}
