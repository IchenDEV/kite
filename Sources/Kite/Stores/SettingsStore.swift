import AppKit
import Foundation
import Observation
import ServiceManagement
import SwiftUI

@MainActor
@Observable
final class SettingsStore {
    var values: AppSettings
    var proxyPassword = ""
    var lastError: String?

    private let defaults: UserDefaults
    private let storageKey = "Kite.AppSettings.v1"
    private let legacyStorageKey = "SuperDD.AppSettings.v1"
    private let settingsURL: URL

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
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(values)
            try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: settingsURL, options: .atomic)
            defaults.set(data, forKey: storageKey)
            try KeychainService.saveProxyPassword(proxyPassword)
            try updateLoginItem()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func restoreDefaults() {
        values = AppSettings()
        proxyPassword = ""
        save()
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
