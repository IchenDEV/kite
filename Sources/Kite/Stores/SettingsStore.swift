import AppKit
import Foundation
import Observation
import ServiceManagement
import SwiftUI

@MainActor
@Observable
final class SettingsStore {
    var values: AppSettings {
        didSet { scheduleSave() }
    }
    var proxyPassword = "" {
        didSet { scheduleSave() }
    }
    var lastError: String?
    private(set) var hasPendingSave = false
    private(set) var lastSavedAt: Date?

    private let defaults: UserDefaults
    private let storageKey = "Kite.AppSettings.v1"
    private let legacyStorageKey = "SuperDD.AppSettings.v1"
    private let settingsURL: URL
    private var automaticSaveEnabled = false
    private var saveTask: Task<Void, Never>?
    private var appliedEngineConfiguration: EngineSettingsSnapshot?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settingsURL = Self.resolveSettingsURL()
        if let data = try? Data(contentsOf: settingsURL),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            values = decoded
        } else if let data = defaults.data(forKey: storageKey) ?? defaults.data(forKey: legacyStorageKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            values = decoded
        } else {
            values = AppSettings()
        }
        if values.userAgent == "SuperDD/0.1 aria2-next" || values.userAgent == "SuperDD/0.2 aria2-next" {
            values.userAgent = "Kite/0.2 aria2-next"
        }
        var features = values.features
        if features.updates.feedURL == "https://api.github.com/repos/IchenDEV/super-dd/releases/latest" {
            features.updates.feedURL = "https://api.github.com/repos/IchenDEV/kite/releases/latest"
            values.features = features
        }

        do {
            let storedPassword = try KeychainService.proxyPassword()
            if !values.proxyPassword.isEmpty {
                proxyPassword = values.proxyPassword
                try KeychainService.saveProxyPassword(values.proxyPassword)
                values.proxyPassword = ""
            } else {
                proxyPassword = storedPassword
            }
        } catch {
            lastError = error.localizedDescription
        }
        if let data = try? JSONEncoder().encode(values) {
            try? FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: settingsURL, options: .atomic)
            defaults.set(data, forKey: storageKey)
        }
        appliedEngineConfiguration = EngineSettingsSnapshot(settings: values, proxyPassword: proxyPassword)
        automaticSaveEnabled = true
    }

    func save() {
        saveTask?.cancel()
        saveTask = nil
        do {
            let data = try JSONEncoder().encode(values)
            try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: settingsURL, options: .atomic)
            defaults.set(data, forKey: storageKey)
            try KeychainService.saveProxyPassword(proxyPassword)
            try updateLoginItem()
            lastError = nil
            hasPendingSave = false
            lastSavedAt = .now
        } catch {
            lastError = error.localizedDescription
        }
    }

    func scheduleSave(after delay: Duration = .milliseconds(450)) {
        guard automaticSaveEnabled else { return }
        hasPendingSave = true
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func restoreDefaults() {
        values = AppSettings()
        proxyPassword = ""
        save()
    }

    var requiresEngineRestart: Bool {
        guard let appliedEngineConfiguration else { return false }
        return EngineSettingsSnapshot(settings: values, proxyPassword: proxyPassword) != appliedEngineConfiguration
    }

    func markEngineConfigurationApplied(_ runtimeSettings: AppSettings) {
        appliedEngineConfiguration = EngineSettingsSnapshot(
            settings: runtimeSettings,
            proxyPassword: runtimeSettings.proxyPassword
        )
    }

    var colorScheme: ColorScheme? {
        switch values.appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// Ephemeral engine configuration. Secrets are injected from Keychain and
    /// never written back into settings.json or UserDefaults.
    var runtimeValues: AppSettings {
        var result = values
        result.proxyPassword = proxyPassword
        return result
    }

    private func updateLoginItem() throws {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let service = SMAppService.mainApp
        if values.startAtLogin, service.status != .enabled {
            try service.register()
        } else if !values.startAtLogin, service.status == .enabled {
            try service.unregister()
        }
    }

    private static func resolveSettingsURL() -> URL {
        let base = (try? AppIdentity.applicationSupportDirectory()) ?? FileManager.default.temporaryDirectory
        return base.appending(path: "settings.json")
    }
}

struct EngineSettingsSnapshot: Equatable {
    let fields: [String]

    init(settings: AppSettings, proxyPassword: String) {
        let features = settings.features
        fields = [
            settings.downloadDirectory,
            String(settings.maxConcurrentDownloads),
            String(settings.split),
            String(settings.maxConnectionsPerServer),
            settings.globalDownloadLimit,
            settings.globalUploadLimit,
            settings.perTaskDownloadLimit,
            settings.perTaskUploadLimit,
            String(settings.continueDownloads),
            settings.fileAllocation,
            features.reliability.conflictPolicy.rawValue,
            String(features.reliability.maxTries),
            String(features.reliability.retryWaitSeconds),
            String(features.reliability.checkIntegrity),
            settings.userAgent,
            String(settings.rpcPort),
            String(settings.btListenPort),
            String(settings.dhtListenPort),
            String(settings.ed2kListenPort),
            String(settings.ed2kUDPListenPort),
            String(settings.btMaxPeers),
            String(settings.enableDHT),
            String(settings.enableDHT6),
            String(settings.enablePeerExchange),
            String(settings.enableLocalPeerDiscovery),
            String(settings.forceEncryption),
            String(settings.seedRatio),
            String(settings.seedTimeMinutes),
            String(settings.pauseMetadata),
            settings.trackerURLs.joined(separator: "\u{1E}"),
            String(settings.enablePeerBlocklist),
            settings.peerBlocklistURL,
            settings.ed2kServerListURL,
            settings.ed2kNodeListURL,
            settings.proxyMode.rawValue,
            settings.proxyURL,
            settings.proxyUsername,
            proxyPassword,
            features.networkPolicy.bindInterface,
            String(features.networkPolicy.enableUPnP),
            String(features.networkPolicy.enableNATPMP),
            String(settings.extensionServerEnabled),
            String(settings.extensionServerPort),
            String(features.remote.enabled),
            String(features.remote.allowLAN),
            String(features.remote.port),
            String(features.capture.monitorClipboard),
        ]
    }
}
