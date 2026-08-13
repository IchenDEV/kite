import Testing
@testable import Kite

@Suite("Settings application state")
struct SettingsStoreTests {
    @Test("Interface-only preferences do not require an engine restart")
    func interfaceOnlySettings() {
        let original = AppSettings()
        var changed = original
        changed.appearance = .dark
        changed.notificationsEnabled.toggle()

        #expect(
            EngineSettingsSnapshot(settings: original, proxyPassword: "")
                == EngineSettingsSnapshot(settings: changed, proxyPassword: "")
        )
    }

    @Test("Engine and listener preferences require an engine restart")
    func engineSettings() {
        let original = AppSettings()
        var changed = original
        changed.split += 1
        changed.features.remote.enabled = true

        #expect(
            EngineSettingsSnapshot(settings: original, proxyPassword: "")
                != EngineSettingsSnapshot(settings: changed, proxyPassword: "")
        )
    }

    @Test("Keychain proxy password participates in applied state")
    func proxyPassword() {
        let settings = AppSettings()

        #expect(
            EngineSettingsSnapshot(settings: settings, proxyPassword: "old")
                != EngineSettingsSnapshot(settings: settings, proxyPassword: "new")
        )
    }
}
