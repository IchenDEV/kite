import AppKit
import Foundation
import Observation
import ServiceManagement
import SwiftUI

@MainActor
@Observable
final class SettingsStore {
    var values: AppSettings
    var lastError: String?

    private let defaults: UserDefaults
    private let storageKey = "SuperDD.AppSettings.v1"
    private let settingsURL: URL

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settingsURL = Self.resolveSettingsURL()
        if let data = try? Data(contentsOf: settingsURL),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            values = decoded
        } else if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            values = decoded
        } else {
            values = AppSettings()
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
            try updateLoginItem()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func restoreDefaults() {
        values = AppSettings()
        save()
    }

    var colorScheme: ColorScheme? {
        switch values.appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
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
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appending(path: "SuperDD", directoryHint: .isDirectory).appending(path: "settings.json")
    }
}
