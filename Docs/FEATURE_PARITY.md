# Feature parity and release gates

Audit baseline:

- Motrix Next: `dc12e7d93f86a00c52b57871498ea11eb5ee946c`
- Motrix: `c9716c332f75b7592c66efc494dd51e61105f552`
- aria2-next: `b209e18619cfd6fde7b15ab946dbec112a24f20c`
- MDXP method contract: protocol `1.0`

`Implemented` means working code exists in this repository and is included in the build. `Scoped` documents an intentional boundary instead of implying broader compatibility. `External gate` requires credentials or third-party store review that cannot live in source control.

| Surface | Status | Kite implementation / boundary |
| --- | --- | --- |
| HTTP/HTTPS/FTP | Implemented | aria2-next, segmentation, resume, headers, checksum, auth and proxy |
| Magnet, torrent, ED2K, Thunder | Implemented | native importer/deep links, metadata, selected files and ED2K bootstrap |
| Metalink | Implemented | `.metalink`/`.meta4` importer and retry metadata |
| Queue and task control | Implemented | batch pause/resume/remove/retry, four-way reorder and three priorities |
| Crash/restart recovery | Implemented | aria2 session plus persisted media checkpoint and task metadata |
| Retry and conflict policy | Implemented | exponential retry, max attempts, keep-both/replace/skip and integrity check |
| Schedules and completion actions | Implemented | speed and task windows, weekdays, quit/sleep/shutdown countdown |
| History | Implemented | SQLite migration, source/options/error/label persistence and download-again |
| Credentials and cookies | Implemented | host-scoped profiles in macOS Keychain; secrets redacted from settings/diagnostics |
| Proxy and VPN binding | Implemented | HTTP/SOCKS URL, proxy auth, per-task override and network-interface binding |
| Browser capture API | Implemented | loopback, Bearer auth, limited CORS, headers/cookies/filename forwarding |
| Chromium and Firefox packages | Implemented | reproducible ZIPs with manifests, icon and archive validation |
| Safari extension | Implemented | Apple converter project builds successfully without signing |
| Extension-store publication | External gate | Chrome/Firefox/Safari store accounts and review are not repository credentials |
| BT discovery/sharing | Implemented | DHT v4/v6, PEX, LPD, encryption, peers, trackers, seeding ratio/time |
| Tracker/blocklist resources | Implemented | remote tracker merge, peer blocklist, `server.met` and `nodes.dat` cache |
| Torrent creation | Implemented | pure Swift bencode and SHA-1 pieces for files/directories |
| RSS/Atom and watch folder | Implemented | polling, regex rules, persistent dedupe, labels/destination/paused behavior |
| Search providers and labels | Implemented | configurable `{query}` providers, searchable task labels |
| UPnP / NAT-PMP | Implemented | opt-in TCP/UDP mappings with cleanup and visible state |
| GeoIP peer labels | Implemented | local/remote CIDR or explicit-range CSV with binary lookup |
| HLS media | Scoped | master/media playlists, variant height, byte ranges, init segment and resume; DRM/AES streams rejected |
| DASH media | Scoped | static `SegmentList` representations; dynamic `SegmentTemplate` and separate A/V mux are not claimed |
| Archive extraction | Scoped | macOS `ditto`/`bsdtar`: ZIP/CBZ/TAR/TGZ/TBZ2/TXZ/7z/RAR; password UI and multipart repair are not claimed |
| Post-download hooks | Implemented | extract/delete/reveal/open, command environment, error reporting and timeout |
| Remote Web UI/API | Implemented | separate disabled-by-default listener, Bearer auth, rate limit and LAN opt-in |
| MDXP 1.0 control plane | Implemented | initialize, ping, submit/cancel, task CRUD, stats, engine and URL methods |
| Device pairing/relay | Scoped | shared-secret LAN control only; no cloud relay or account service |
| Headless control | Implemented | `--headless` app mode and standalone `kitectl` MDXP client |
| Plugin sandbox | Implemented | separate JavaScriptCore helper, no host bridges, timeout and error isolation |
| Plugin registry | Implemented | JSON catalog, SHA-256 required install, path validation and manifest ID check |
| Motrix plugin binary compatibility | Scoped | Kite resolver API is intentionally smaller; foreign plugin bundles are not claimed compatible |
| Native update client | Implemented | GitHub release check, architecture selection and mandatory SHA-256 verification |
| Signing/notarization workflow | Implemented | Developer ID, hardened runtime, notarization, staple, `spctl`, DMG and checksums |
| Signed public release | External gate | requires the maintainer’s Developer ID/notary secrets and a version tag |
| macOS 26 appearance | Implemented | native split view/toolbars/inspector/glass and semantic SF Symbol colors in light/dark modes |
| Localization | Scoped | English and Simplified Chinese; other Motrix locales are not yet translated |

This table is also the honesty boundary for release notes: `Scoped` and `External gate` rows must retain their qualifier.
