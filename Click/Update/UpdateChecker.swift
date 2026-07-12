// Self-update is for the direct-download channel only. The App Store build
// must not contain update-check or website-download code paths (App Review
// guidelines 2.3.10 / 3.1.x) — Apple delivers updates there.
#if !MAS_BUILD

import AppKit
import Foundation
import Observation
import os

/// Schema of the download site's `version.json` manifest
/// (see `download-site/version.json` in the repo).
struct UpdateManifest: Decodable, Sendable {
    let version: String
    let downloadURL: String
    let notes: String?
}

/// Checks the download site's `version.json` for a newer release.
///
/// Runs automatically shortly after launch (at most once per day) and on
/// demand from the menu bar. Every failure mode — offline, timeout, bad
/// status, malformed JSON, unparseable versions — is logged and reflected in
/// `status`; nothing here can crash the app or block the main thread on I/O.
@MainActor
@Observable
final class UpdateChecker {
    /// Outcome of the most recent check, observed by the menu bar UI.
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(version: String)
        case failed
    }

    // Served from the public GitHub repo; release assets host the DMG the
    // manifest's downloadURL points at.
    static let manifestURLString =
        "https://raw.githubusercontent.com/bhino50/Click-App-Mac-OS/main/download-site/version.json"

    private static let log = Logger(subsystem: "brandon.Click", category: "updates")
    private static let launchCheckDelay: Duration = .seconds(10)
    private static let minimumCheckInterval: TimeInterval = 24 * 60 * 60
    private static let requestTimeout: TimeInterval = 15

    private(set) var status: Status = .idle

    private let defaults: UserDefaults
    private let session: URLSession
    private var launchCheckTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.requestTimeout
        self.session = URLSession(configuration: configuration)
    }

    /// Schedules the automatic launch-time check: waits a short delay so it
    /// never competes with bootstrap, then checks at most once per day.
    /// Automatic checks only surface a prompt when an update exists.
    func scheduleLaunchCheck() {
        guard launchCheckTask == nil else { return }
        launchCheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.launchCheckDelay)
            guard let self, !Task.isCancelled else { return }
            guard self.isDailyCheckDue else {
                Self.log.debug("Skipping automatic update check; already checked within a day")
                return
            }
            await self.check()
        }
    }

    /// Manual "Check for Updates" action. Always checks, ignoring the
    /// daily throttle, and always reports the outcome through `status`.
    func checkNow() async {
        await check()
    }

    private var isDailyCheckDue: Bool {
        guard let lastCheck = defaults.object(forKey: Keys.lastCheckAt) as? Date else {
            return true
        }
        return Date().timeIntervalSince(lastCheck) >= Self.minimumCheckInterval
    }

    private func check() async {
        guard status != .checking else { return }
        status = .checking
        guard let url = URL(string: Self.manifestURLString) else {
            Self.log.error("Update manifest URL is invalid: \(Self.manifestURLString, privacy: .public)")
            status = .failed
            return
        }
        do {
            let manifest = try await Self.fetchManifest(from: url, using: session)
            defaults.set(Date(), forKey: Keys.lastCheckAt)
            handle(manifest: manifest)
        } catch {
            Self.log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            status = .failed
        }
    }

    /// Fetches and decodes the manifest. `nonisolated` so neither the
    /// network wait nor JSON decoding ever runs on the main actor.
    private nonisolated static func fetchManifest(
        from url: URL,
        using session: URLSession
    ) async throws -> UpdateManifest {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(UpdateManifest.self, from: data)
    }

    private func handle(manifest: UpdateManifest) {
        guard let remote = SemanticVersion(manifest.version) else {
            Self.log.error("Manifest version is unparseable: \(manifest.version, privacy: .public)")
            status = .failed
            return
        }
        let installedString = Self.installedVersionString
        guard let installed = SemanticVersion(installedString) else {
            Self.log.error("Bundle version is unparseable: \(installedString, privacy: .public)")
            status = .failed
            return
        }
        guard remote > installed else {
            Self.log.notice("Up to date: installed \(installedString, privacy: .public), manifest \(manifest.version, privacy: .public)")
            status = .upToDate
            return
        }
        Self.log.notice("Update available: \(manifest.version, privacy: .public) (installed \(installedString, privacy: .public))")
        status = .updateAvailable(version: manifest.version)
        presentUpdateAlert(manifest: manifest, installedVersion: installedString)
    }

    private func presentUpdateAlert(manifest: UpdateManifest, installedVersion: String) {
        let alert = NSAlert()
        alert.messageText = "A new version of Click is available"
        var details = "Click \(manifest.version) is available. You have \(installedVersion)."
        if let notes = manifest.notes, !notes.isEmpty {
            details += "\n\n\(notes)"
        }
        alert.informativeText = details
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let downloadURL = Self.validatedDownloadURL(manifest.downloadURL) else {
            Self.log.error("Manifest downloadURL is invalid: \(manifest.downloadURL, privacy: .public)")
            return
        }
        NSWorkspace.shared.open(downloadURL)
    }

    /// Update downloads must remain encrypted in transit. The manifest is
    /// remote content, so never let it downgrade users to plaintext HTTP.
    nonisolated static func validatedDownloadURL(_ rawValue: String) -> URL? {
        guard let url = URL(string: rawValue),
              url.scheme?.lowercased() == "https",
              url.host != nil else {
            return nil
        }
        return url
    }

    private static var installedVersionString: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    private enum Keys {
        static let lastCheckAt = "click.update.lastCheckAt"
    }
}

#endif
