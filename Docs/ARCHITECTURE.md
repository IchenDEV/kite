# Architecture

## Process boundary

Super DD is a native macOS app. It does not link aria2 into the Swift process: a pinned `aria2-next` executable runs as a sidecar and accepts authenticated JSON-RPC only on loopback. Media-manifest transfers and automation use isolated Swift actors. Resolver plugins run in a separate JavaScriptCore helper process so a stalled script can be terminated without taking down the app.

```text
SuperDD.app
├── Contents/MacOS/SuperDD
├── Contents/Resources/Engine/aria2-next
├── Contents/Resources/Helpers/superdd-plugin-host
├── Contents/Resources/CLI/superddctl
└── Contents/Resources/BrowserExtensions/*.zip
```

## State ownership

- `SettingsStore`: durable JSON settings, login item state and Keychain migration.
- `DownloadStore`: main-actor UI state, task coordination and service lifecycle.
- `Aria2Engine` / `Aria2RPCClient`: engine process and authenticated RPC.
- `TaskMetadataStore`: sources, retry policy, labels, media status and post-processing state.
- `HistoryStore`: WAL-mode SQLite terminal history and schema migration.
- Service actors: RSS, media, plugins, updates, port mapping, GeoIP and post-processing.

## Listener classes

| Listener | Default bind | Authentication | Purpose |
| --- | --- | --- | --- |
| aria2 RPC | `127.0.0.1` | random per-launch RPC secret | internal engine control |
| browser API | `127.0.0.1` | persisted extension Bearer secret | browser capture |
| remote Web/API/MDXP | disabled; loopback when enabled | separate remote Bearer secret | remote and CLI control |

LAN binding is a distinct opt-in for the remote listener. The app does not claim to provide Internet-grade TLS termination; users must place Internet exposure behind a trusted TLS reverse proxy.

## Secret and code boundaries

- Passwords, cookies profiles and proxy passwords are stored with Security.framework in the login Keychain.
- Serialized retry metadata removes password and header fields.
- Diagnostic export redacts secrets and credentials.
- Plugin registry downloads require SHA-256, archive paths are checked, and manifest ID must match the catalog.
- Plugin scripts receive only an input URL and frozen platform metadata; no Swift object, filesystem, Shell, network or Keychain bridge is exported.
- Archive extraction lists and rejects absolute or parent-traversing paths before invoking macOS tools.

## Packaging

SwiftPM builds the app, CLI and plugin helper. `script/build_and_run.sh` assembles the `.app`, browser extensions, verified sidecar, licenses and entitlements. Local builds are ad-hoc signed. `script/release.sh` requires a Developer ID identity and notary keychain profile, then creates and notarizes ZIP/DMG assets and emits `SHA256SUMS.txt`.
