# Signing key (release builds)

The APK is now signed from a GitHub repo **secret**, not from a keystore
committed to this repository. An earlier version of this project committed
`ci/debug.keystore` directly to the repo — that was a real security weakness
(anyone with read access to the repo/its history could resign fake updates)
and has been removed. Do not add a keystore file back into this repo.

## One-time setup

1. Generate a keystore (any machine with a JDK):
   ```
   keytool -genkey -v -keystore release.keystore -storepass android \
     -alias androiddebugkey -keypass android -keyalg RSA -keysize 2048 \
     -validity 36500 -dname "CN=Melyqon Movies,O=Melyqon,C=IN"
   ```
   The alias/password must stay exactly `androiddebugkey` / `android` —
   Flutter's generated Android project signs the `release` build type with
   its own `debug` signing config, which hardcodes those values. This means
   the *password itself* is not a real secret (it's a well-known Flutter
   default); what this setup actually protects is the private key file
   itself, which never touches the repo or its history.
2. Base64-encode it:
   ```
   base64 -w0 release.keystore > release.keystore.b64
   ```
3. In the GitHub repo: **Settings → Secrets and variables → Actions → New
   repository secret**, name it `ANDROID_KEYSTORE_BASE64`, paste the contents
   of `release.keystore.b64`.
4. Keep `release.keystore` itself somewhere safe outside the repo (password
   manager, local backup). If you ever lose it, future builds can no longer
   update the app already installed on a phone without uninstalling first.

## If you want real (non-default) signing credentials

The setup above reuses Flutter's debug signing config, so the password is
always "android". A fully custom release `signingConfig` (with its own
secret password, stored as additional repo secrets) would be a more correct
long-term setup, but requires editing the generated
`app/android/app/build.gradle.kts` after `flutter create` runs in CI. That
file's exact contents depend on the installed Flutter version and were not
verified against a real `flutter create` output in this environment, so it
was not changed here to avoid shipping an unverified, possibly-broken Gradle
edit. Flag this if you want it implemented and tested properly.
