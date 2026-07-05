import AppKit
import SwiftUI

/// Manual "Check for Updates…" against GitHub Releases. No appcast, no signing
/// keys — fetch `releases/latest`, compare its tag to our bundle version, and
/// open the DMG if newer. Graduate to Sparkle if silent auto-install is ever
/// wanted; this is a clean upgrade path, not a dead end.
@MainActor
enum UpdateChecker {
    private static let repo = "murphyjt/wavebird"
    private static let skippedVersionKey = "WaveBird.skippedUpdateVersion"

    /// Silent check now, then daily — a menu-bar app can run for weeks between
    /// launches. Debug builds carry version 0.0.0-dev, which every release
    /// outranks, so they skip the background check entirely.
    static func startBackgroundChecks() {
        #if !DEBUG
        check(userInitiated: false)
        Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { _ in
            Task { @MainActor in check(userInitiated: false) }
        }
        #endif
    }

    /// `userInitiated` controls whether we surface "up to date" / errors, and
    /// whether a previously skipped version is honored. A background check stays
    /// silent unless there's a newer release the user hasn't skipped; a manual
    /// check always shows what's available (Sparkle's behavior).
    static func check(userInitiated: Bool) {
        Task {
            do {
                let latest = try await fetchLatest()
                guard isNewer(latest.version, than: currentVersion) else {
                    if userInitiated { presentUpToDate() }
                    return
                }
                if !userInitiated, latest.version == skippedVersion {
                    return
                }
                presentUpdate(latest)
            } catch {
                if userInitiated { presentError(error) }
            }
        }
    }

    private static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private static var skippedVersion: String? {
        UserDefaults.standard.string(forKey: skippedVersionKey)
    }

    // MARK: - Fetch

    private struct Release {
        let version: String      // tag without leading "v", e.g. "1.1"
        let pageURL: URL         // GitHub release page
        let dmgURL: URL?         // direct .dmg asset, if present
        let notes: String        // changelog (release body), may be empty
    }

    private struct FetchError: LocalizedError {
        let errorDescription: String?
    }

    private static func fetchLatest() async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // Rate-limit (403) and error bodies lack tag_name/html_url —
            // without this guard they'd read as "up to date" or worse.
            throw FetchError(errorDescription: "GitHub returned HTTP \(status).")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        guard let tag = json["tag_name"] as? String, !tag.isEmpty,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
            throw FetchError(errorDescription: "Unexpected response from GitHub.")
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag

        // The release body ends with a <details> provenance block and a Full
        // Changelog link; ChangelogView can't render HTML or code fences, and
        // "Open in Browser" covers them.
        let body = (json["body"] as? String) ?? ""
        let notes = body.components(separatedBy: "<details>")[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let assets = (json["assets"] as? [[String: Any]]) ?? []
        let dmg = assets.lazy
            .compactMap { $0["browser_download_url"] as? String }
            .first { $0.hasSuffix(".dmg") }
            .flatMap(URL.init(string:))

        return Release(version: version, pageURL: page, dmgURL: dmg, notes: notes)
    }

    // Numeric, component-wise: "1.10" > "1.9", "1.0" == "1.0".
    private static func isNewer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }

    // MARK: - UI

    // Held so the hosting window survives until a button dismisses it.
    private static var updateWindow: NSWindow?

    private static func presentUpdate(_ release: Release) {
        // A manual check can race the launch/daily check; latest wins.
        dismissUpdateWindow()

        let view = UpdateAvailableView(
            version: release.version,
            currentVersion: currentVersion,
            notes: release.notes,
            onDownload: {
                NSWorkspace.shared.open(release.dmgURL ?? release.pageURL)
                dismissUpdateWindow()
            },
            onReleaseNotes: { NSWorkspace.shared.open(release.pageURL) },
            onSkip: {
                UserDefaults.standard.set(release.version, forKey: skippedVersionKey)
                dismissUpdateWindow()
            },
            onLater: dismissUpdateWindow  // Re-offered on the next check.
        )

        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Software Update"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        updateWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private static func dismissUpdateWindow() {
        updateWindow?.close()
        updateWindow = nil
    }

    private static func presentUpToDate() {
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "WaveBird \(currentVersion) is the latest version."
        NSApp.activate(ignoringOtherApps: true)  // Menu-bar checks in accessory mode.
        alert.runModal()
    }

    private static func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't check for updates"
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
