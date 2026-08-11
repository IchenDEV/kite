# Feature parity audit

Audit baseline:

- Motrix Next: `dc12e7d93f86a00c52b57871498ea11eb5ee946c`
- Motrix: `c9716c332f75b7592c66efc494dd51e61105f552`
- aria2-next: `b209e18619cfd6fde7b15ab946dbec112a24f20c`

Legend: `Done` is implemented and exercised in this repository; `Partial` has a working core but not every reference option; `Open` is not implemented and must not be claimed as parity.

| Surface | Status | Super DD implementation / remaining gap |
| --- | --- | --- |
| HTTP/HTTPS/FTP downloads | Done | aria2-next JSON-RPC, headers, cookie, referer, UA, checksum, proxy |
| Magnet and `.torrent` | Done | native file importer, metadata pause, selective files |
| ED2K and Thunder | Done | native aria2-next ED2K plus Thunder envelope decoding |
| Active/waiting/stopped control | Done | poll, pause/resume/remove, batch selection, session file |
| BT discovery and sharing | Done | DHT v4/v6, PEX, LPD, encryption, peers, ports, seed ratio/time |
| Tracker management | Done | multiple remote sources merged and applied to aria2 |
| BT peer blocklist | Done | cached weekly and passed to aria2-next |
| ED2K bootstrap | Done | cached `server.met` and `nodes.dat` |
| Speed limits and schedules | Done | global, per-task defaults, weekday/time schedule |
| Proxy scopes | Partial | engine/system/manual proxy work; separate update/tracker proxy scopes are open |
| History and recovery | Done | aria2 session plus native SQLite terminal history |
| macOS notifications | Done | completion/failure Notification Center delivery |
| Power integration | Partial | idle-sleep assertion works; shutdown-after-completion is open |
| Dock and menu bar | Partial | badge, live speed and actions work; custom Dock progress ring is open |
| Protocol/file handlers | Done | Magnet, ED2K, Thunder, SuperDD, torrent association |
| Browser extension API | Done | compatible core endpoints, auth, CORS, headers/cookie/filename forwarding |
| Browser extension packages | Open | Chrome/Edge/Firefox store packages are not included |
| Favorite/recent folders | Done | native destination menu, star action and bounded recent list |
| File-type categorization | Done | editable extension rules route new URL downloads before submission |
| GeoIP peer flags | Open | peer table works without GeoIP database |
| UPnP / NAT-PMP | Open | no native mapper yet |
| Diagnostics ZIP / DB rebuild | Partial | redacted pure-Swift ZIP export and integrity check work; automatic DB rebuild is open |
| Auto update | Open | no signed update channel yet |
| Theme and localization | Partial | system/light/dark and Simplified Chinese work; color presets and the remaining languages are open |
| Lightweight WebView destruction | Not applicable | there is no WebView; SwiftUI remains native and low overhead |
| Customizable dashboard | Partial | live native chart and task summary work; tile rearrangement is open |
| In-app notification center | Open | system notifications work; durable inbox is open |
| Motrix MDXP CLI pairing | Open | authenticated local REST API exists; MDXP device pairing is open |
| Plugin sandbox and marketplace | Open | no QuickJS/JavaScriptCore plugin runtime yet |
| URL resolver/media mux plugins | Open | direct URL tasks work; resolver ecosystem is open |
| Headless/Docker server | Open | the native app is complete enough to run independently, but Motrix's remote headless deployment surface is not implemented yet |

“全部功能对等”尚未完成。This matrix is the release gate: an `Open` or `Partial` row cannot be described as finished until its implementation and verification land.
