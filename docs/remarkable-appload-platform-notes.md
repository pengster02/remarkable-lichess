# reMarkable / XOVI / AppLoad platform notes

Reusable findings from building `remarkable-lichess`, kept general on purpose so they carry over to
other AppLoad apps on reMarkable devices, not just this one. Two source classes: (A) things directly
verified by building/running code in a Linux sandbox during this project, and (B) things found via
web research and the actual `rm-appload` source (a local checkout was available at
`~/.cargo/git/checkouts/rm-appload-*/`, pulled in as this project's `appload-client` dependency —
worth re-cloning `github.com/asivery/rm-appload` directly for the full repo, including its `examples/`
and `xovi/` directories, rather than relying on the shallow single-commit checkout Cargo pulls).

Last verified: 2026-07-18. XOVI/AppLoad/reMarkable OS are all actively moving targets — re-check
version compatibility before trusting any specific version number below.

## 1. Can this actually install on reMarkable Paper Pro / Paper Pro Move?

Yes, in principle — confirmed from the framework's own source, not just secondhand docs:

- `rm-appload`'s README states directly: "AppLoad is a xovi extension for the RMPP which lets you
  write custom applications for the RMPP" (RMPP = reMarkable Paper Pro). External-app manifests
  support `aspectRatio: 'move'` specifically for **rMPPM** (Paper Pro Move) vs `'original'` (rM1/rM2/rMPP),
  so the Paper Pro Move is a first-class supported target, not an afterthought.
- Paper Pro Move's real screen spec (7.3", 1696×954, 16:9 color E Ink Gallery 3) matches exactly what
  this project's design doc assumed — confirmed via reMarkable's own support article.
- Standard install path: XOVI (universal Linux extension/patching framework) + the `qt-resource-rebuilder`
  extension (a dependency of AppLoad) + AppLoad itself, dropped into
  `/home/root/xovi/exthome/appload/<app>/`. Tooling exists for this: manual (`install-xovi-for-rm` +
  `extensions-aarch64.zip` over scp/ssh), or a one-command installer (`remagic`,
  github.com/maximerivest/remagic) that finds the tablet over USB/Wi-Fi automatically.
  `xovi-tripletap` adds a persistent triple-power-button-press toggle for XOVI so it survives reboots.

**The real risk isn't "does AppLoad support this device" — it's firmware-version drift.** XOVI's
per-feature patches (`.qmd` files) are pinned to specific reMarkable OS versions and published in
version-matched folders; reMarkable ships OTA updates frequently (confirmed releases through at least
June 2026 in this research), and XOVI/AppLoad support typically lags behind the newest official
firmware. This project's own design doc already flagged needing to downgrade from 3.28 to the
3.26.x–3.27.x range — treat that as a snapshot-in-time fact to re-verify against whatever OS version
is actually on the tablet being deployed to, not a permanent constant. Check the specific `.qmd`
extension files' listed supported-OS-versions immediately before any real device install.

Sources: [rm-appload GitHub](https://github.com/asivery/rm-appload), [Xovi — reMarkable Guide](https://remarkable.guide/guide/software/xovi.html), [remagic](https://github.com/maximerivest/remagic), [xovi-tripletap](https://github.com/rmitchellscott/xovi-tripletap), [About reMarkable Paper Pro Move](https://support.remarkable.com/s/article/About-reMarkable-Paper-Pro-Move), [xovi-qmd-extensions](https://github.com/rmitchellscott/xovi-qmd-extensions).

## 2. E-ink refresh / performance

The app now uses AppLoad's refresh mechanism through a local adapter. Keep the
native API distinction below: `EPFrameBuffer` still does not apply to an
AppLoad-hosted QML frontend.

### Two different APIs, don't confuse them

1. **`EPFrameBuffer` (native Qt-on-reMarkable SDK level)** — used by *standalone* Qt apps that run as
   their own process via `QT_QUICK_BACKEND=epaper ./app -platform epaper` (per reMarkable's own
   `developer.remarkable.com/documentation/qt_epaper` doc). Exposes `WaveformMode` (`Initialize`,
   `Mono`/DU, `Grayscale`/GL16, `HighQualityGrayscale`/GC16, `Highlight`), `UpdateMode`
   (`PartialUpdate`, `FullUpdate`), a `sendUpdate(QRect, WaveformMode, UpdateMode, sync)` call, and
   `setForceFull(bool)`. **This is not directly reachable from an AppLoad QML app** — AppLoad apps
   are QML modules loaded into XOVI's already-running, already-epaper-configured Qt engine (hosted
   inside `xochitl`'s own process), not separate processes that set their own platform plugin.

2. **`DisplayMethodArea` (`import net.asivery.ApploadUtils`) — this is the one AppLoad apps actually use.**
   An invisible `Item` you wrap around a region, with a `displayMethod` property:

   ```qml
   enum Method { UFast, Fast, Animate, Content, UI }
   property int displayMethod: Content   // default
   ```

   Confirmed in the framework's own `resources/ApploadUtils/DisplayMethodArea.qml` and demoed in
   `examples/appload/frontend-only/ui/example.qml`, wrapping a `Text` element with
   `displayMethod: DisplayMethodArea.Fast`. In the checked-out QML source itself this component's
   handler is just `console.log(...)` — but XOVI's binary patch file (`xovi/template/appload.qmd`)
   contains explicit `REDEFINE`/`REPLACE` directives targeting this exact QML type, meaning the real
   effect is spliced in at the native layer on actual hardware (via XOVI's patching DSL) even though
   it looks like a no-op stub in the plain QML source — don't be fooled by the source looking inert,
   and don't expect the on-PC emulator to show real refresh timing since it only hits the stub.

### What this means concretely for a chess board (or any frequently-redrawing AppLoad UI)

`EinkRefreshArea.qml` dynamically loads AppLoad's resource-owned
`DisplayMethodArea.qml`, keeping shared controls testable without the AppLoad
host. Current policy:

- board selection, legal targets, premoves, and the short changed-square clearing
  pulse use `Fast`; the clearing pulse must oppose the canvas polarity (light
  on dark mode, dark on paper mode) or it reinforces piece residue;
- the settled colored board returns to `Content`;
- clock chips and changing live status text use `Fast`;
- shared buttons use `Fast` while pressed and `UI` at rest.

Avoid interactive `Flickable` and `ListView` movement for long pages. A drag
produces a stream of large damaged regions even with overshoot disabled. Use
`EinkPagedFlickable`: non-interactive content, Prev/Next page controls, one
`contentY` jump per tap, and `EinkRefreshArea.Content` over the viewport so
each page turn gets a slow clean refresh instead of repeated fast ones.
`reveal()` is a no-op when the target row is already fully visible.

Live clocks: only the active chip uses `Fast`; refresh cadence is 10s above one
minute, 5s at or below one minute, and 1s in the last 15 seconds. Minimal
legal-move highlights default on to keep selection damage to one square.

Do not use `UFast` for the board by default. Its speed is not worth risking
reduced color/detail on the Paper Pro Move. The PC emulator proves loading and
layout but cannot reproduce physical waveform timing or ghosting.

Sources: [Writing Qt Quick Applications — developer.remarkable.com](https://developer.remarkable.com/documentation/qt_epaper), [libqsgepaper reference — canselcik/libremarkable](https://github.com/canselcik/libremarkable/blob/master/reference-material/libqsgepaper.md), [epframebuffer.h — Eeems-Org/remarkable-template-qt-app](https://github.com/Eeems-Org/remarkable-template-qt-app/blob/main/src/vendor/epaper/epframebuffer.h), [rm-appload GitHub](https://github.com/asivery/rm-appload) (`resources/ApploadUtils/DisplayMethodArea.qml`, `examples/appload/frontend-only/ui/example.qml`, `xovi/template/appload.qmd`), [Ghosting — reMarkable support](https://support.remarkable.com/s/article/Ghosting), [chessmarkable](https://github.com/LinusCDE/chessmarkable) (a non-Qt reference point — it manages partial e-ink updates manually via direct framebuffer/ioctl calls since it's Rust+SDL, not QML, so its approach doesn't transfer directly, but its release notes confirm per-field partial-update tuning was worth doing for a reMarkable chess board specifically).

## 3. Build/test findings from this session (general, not just this app)

- A stock Linux box (this included — no reMarkable-specific tooling needed) can `cargo build`/`cargo test`
  **including** any `appload-client`-dependent code, since `appload-client` is Linux-only, not
  device-only. Don't assume "needs the real device" for anything that's just "needs Linux" — a
  GitHub Actions `ubuntu-latest` runner covers most of this stack.
- `reqwest`'s default TLS backend (native-tls/openssl-sys) is a real cross-compile and system-dependency
  risk; switching to `default-features = false, features = ["rustls-tls", ...]` removes any system
  OpenSSL dependency at build time and at runtime on-device. Worth doing by default for any Rust
  AppLoad backend that talks HTTPS.
- AppLoad's wire protocol is `AF_UNIX SOCK_SEQPACKET`, framed as **two discrete datagrams per
  message** (an 8-byte `{msg_type: u32, length: u32}` header, then the payload) — and the receive
  loop unconditionally issues a second `recv()` even for zero-length payloads. Any IPC test harness
  must send that second (possibly empty) frame or the stream desyncs after the first zero-length
  message.
- A token that passes `GET /api/account` (identity check) can still lack the specific scope a Board
  API app needs (`board:play`, confirmed by hitting `"Missing scope: board:play"` against a real,
  live token during this session) — Lichess's account-verification response doesn't expose granted
  scopes, so this class of bug (verified-but-underscoped token) needs its own explicit handling in any
  Lichess Board API client, not just here.

See `docs/superpowers/specs/2026-07-17-remarkable-lichess-client-design.md` and
`docs/superpowers/plans/2026-07-17-remarkable-lichess-client-plan.md` for this specific app's design
and task-by-task build log.
