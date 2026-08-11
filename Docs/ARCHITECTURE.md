# Architecture

## Design boundary

Super DD is a native macOS process. It does not link against aria2 or load third-party code into the Swift process. The app launches a separately executable `aria2-next` sidecar and communicates through authenticated JSON-RPC on a loopback-only port.

## Modules

- `App/`: SwiftUI scene declarations, AppKit lifecycle bridge, commands, menu bar extra.
- `Views/`: macOS 26 sidebar/detail/inspector UI, task creation, settings, dashboard and history.
- `Models/`: Sendable value models for aria2 tasks, files, peers, settings and JSON values.
- `Stores/`: main-actor application state, task polling, selection and durable settings.
- `Services/`: aria2 RPC and process lifecycle, SQLite history, notifications, power assertions, tracker/resource refresh and the extension API.
- `Support/`: formatting, URL normalization and loopback port resolution.

## State ownership

- `SettingsStore` owns durable application settings in `settings.json`.
- `DownloadStore` is the app-wide main-actor model shared by windows and the menu bar extra.
- Networking, SQLite and process work is isolated in actors.
- SwiftUI owns only window-local presentation state such as inspector tabs and sheet disclosure state.

## Security

- aria2 RPC binds to loopback and uses a per-launch random secret.
- The browser extension API binds to IPv4 loopback and uses a separately persisted Bearer secret.
- CORS responses are limited to Chrome/Firefox extension origins and local `null` origins.
- Port collisions are resolved before launch; BT, DHT and ED2K ports move by the same offset as RPC.
- Remote engine resources are cached locally. The bundled sidecar itself is pinned by version and SHA-256.

## Packaging

SwiftPM builds the native binary. `script/build_and_run.sh` stages a real `.app`, writes bundle metadata for deep links and torrent association, embeds the verified sidecar and GPL text, then performs ad-hoc signing for local testing.
