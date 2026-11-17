#!/usr/bin/env bash
# Runs inside the Android emulator: installs the APK, launches it, reports what happened.
APK="${APK:-app-release.apk}"
PKG=com.melyqon.moviebox
out=""
log() { out="$out$1"$'\n'; echo "$1"; }

log "DEVICE: Android $(adb shell getprop ro.build.version.release | tr -d '\r') (API $(adb shell getprop ro.build.version.sdk | tr -d '\r')), ABIs: $(adb shell getprop ro.product.cpu.abilist | tr -d '\r')"
r=$(adb install -r "$APK" 2>&1 | tr -d '\r' | tail -5)
log "INSTALL RESULT: $r"

if echo "$r" | grep -q "Success"; then
  adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  sleep 15
  pid=$(adb shell pidof "$PKG" | tr -d '\r')
  log "APP RUNNING AFTER 15s: ${pid:-NO (it crashed or closed)}"
  crash=$(adb logcat -d -t 600 2>&1 | grep -E "FATAL EXCEPTION|UnsatisfiedLinkError|dlopen failed|AndroidRuntime|Startup error|Process: $PKG" | tail -12)
  [ -n "$crash" ] && log "LOG: $crash"
fi

msg=$(printf '%s' "$out" | sed 's/%/%25/g' | awk '{printf "%s%%0A", $0}')
echo "::notice title=Install test API ${API:-?}::$msg"
