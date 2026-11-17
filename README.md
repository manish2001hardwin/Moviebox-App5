# Melyqon Movies (personal Android app)

Single APK: Flutter UI + Rust core (MovieBox-TUI providers/proxy, unchanged logic) + libmpv player.
No Termux, no VLC needed. For **personal use on your own phone only**.

```
core/       MovieBox-TUI v0.1.29 source (MIT/Apache-2.0) + 1 small patch in src/proxy.rs
            (run_proxy: lets the DASH proxy run inside the app instead of a child process)
rust-ffi/   C-ABI bridge (mb_init / mb_call / mb_free), JSON in/out, has a host test
app/        Flutter app (lib/ + pubspec.yaml). Android folder is generated in CI.
.github/    workflow that builds the arm64 APK in the cloud
```

## Build (cloud, no setup on your PC)
1. Create a **private** GitHub repo, push this whole folder to branch `main`.
2. Repo -> Actions -> "Build Android APK" runs automatically (or Run workflow).
3. ~15-25 min first time. Download from the run's Artifacts (`moviebox-arm64-apk`) or from Releases -> `latest`.
4. Install on phone (allow "install unknown apps").

If a step fails, open the failed step, copy the last ~40 lines of log and send it to Claude.

## What's in v1
Home feed, search (provider chips), details (seasons/episodes, dubs), source/quality/subtitle pickers,
in-app libmpv player (headers, DASH via in-process proxy, resume), continue watching, favorites.

## Not in v1
Downloads, Live TV/IPTV, Stremio addons, 4K poster protocol things (none needed on mobile).
