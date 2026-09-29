import Foundation
import ServiceManagement

/// Starts the app at login. The packaged `.app` uses `SMAppService`; a bare
/// SwiftPM executable (`swift run`) cannot, so there the switch writes a
/// LaunchAgent. The file is enough for the next login; loading it now would
/// open a second menu-bar icon.
enum LoginLaunch {
    static let label = "com.cesar.claude-status-bar"

    static func agentURL(home: URL) -> URL {
        home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func isInstalled(home: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: agentURL(home: home).path)
    }

    static func plist(executable: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(xml(executable))</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>LimitLoadToSessionType</key>
            <string>Aqua</string>
        </dict>
        </plist>
        """
    }

    static func install(executable: String, home: URL, fileManager: FileManager = .default) throws {
        let url = agentURL(home: home)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(plist(executable: executable).utf8).write(to: url, options: .atomic)
    }

    static func remove(home: URL, fileManager: FileManager = .default) throws {
        let url = agentURL(home: home)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    /// Drops a loaded agent that is some other process. Booting out our own pid
    /// would quit the app the moment the switch goes off.
    static func unloadIfLoaded(ownPID: Int32 = getpid(), run: (String, [String]) -> String = Shell.run) {
        let target = "gui/\(getuid())/\(label)"
        let printed = run("/bin/launchctl", ["print", target])
        guard printed.contains("state =") else { return }
        if launchdPID(printed) == ownPID { return }
        _ = run("/bin/launchctl", ["bootout", target])
    }

    /// Inside `ClaudeStatusBar.app` the system login item works, so the
    /// LaunchAgent is only for `swift run`.
    static var isBundled: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var appServiceStatus: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static func setAppService(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func launchdPID(_ text: String) -> Int32? {
        guard let regex = try? NSRegularExpression(pattern: #"pid = (\d+)"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text),
              let pid = Int32(text[range])
        else { return nil }
        return pid
    }

    private static func xml(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
