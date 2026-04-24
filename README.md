# andssh

An Android SSH terminal built with Flutter. SSH keys and passwords are kept in
the Android Keystore and unlocked with your fingerprint (or device PIN
fallback) every time a connection is opened.

## Features

- Full terminal emulation via [`xterm.dart`](https://pub.dev/packages/xterm)
  with a `xterm-256color` PTY — tmux, vim, htop, mouse reporting, 256 colours,
  alt-screen, window title, resize, etc.
- SSH via [`dartssh2`](https://pub.dev/packages/dartssh2) with password or
  private-key (OpenSSH / PEM, with optional passphrase) authentication.
- **Biometric-protected credentials.** All secrets live in
  `flutter_secure_storage` (Android Keystore / EncryptedSharedPreferences); the
  app prompts via `local_auth` before reading them.
- **Jump host chaining** (SSH `ProxyJump`). Any saved connection can reference
  another as its jump host, and chains are followed recursively through
  `SSHClient.forwardLocal` channels.
- **SFTP file transfer** from the terminal's menu. Send a local file to a
  remote directory or fetch a remote file to the device, over the same
  authenticated SSH session (no second login). Streaming, with progress and
  cancel; remembers the last local and remote directory per host.
- **Extra-keys bar** above the soft keyboard for keys Android's IME doesn't
  expose: Esc, Tab, arrows, Home/End, PgUp/PgDn, Ins, Del, F1–F12, and
  punctuation (`| / \ ~ - _`). Sticky Ctrl/Alt/Shift toggles apply to the next
  extra-key tap *and* the next soft-keyboard keystroke, so Ctrl-tap → `a`
  produces Ctrl+A (tmux's default prefix).

## Install

Grab the latest APK from the
[releases page](https://github.com/zond/andssh/releases/latest) and
side-load it on your Android device. You may need to enable "Install unknown
apps" for your file manager or browser.

Released APKs are built and signed by the `.github/workflows/release.yml`
GitHub Action on every `v*` tag push, using an upload keystore stored as
repository secrets.

## Build from source

Requirements: Flutter stable (≥ 3.11), JDK 17+, Android SDK with platform 36
and build-tools 36.

```bash
git clone https://github.com/zond/andssh.git
cd andssh
flutter pub get
flutter build apk --release
```

The output lands in `build/app/outputs/flutter-apk/app-release.apk`.

Without signing material, builds fall back to the Flutter debug keystore —
fine for running on your own device, but the APK isn't distributable and
doesn't share identity with the published release. To sign with your own
stable upload key (so debug and release builds replace each other in-place
and share data) copy `android/key.properties.example` to `android/key.properties`
and drop your keystore at `android/app/upload-keystore.jks`. Both paths are
`.gitignore`d.

To cut a release:

```bash
git tag v0.X.Y
git push origin v0.X.Y
```

The workflow builds the APK and attaches it to a new GitHub Release.

## Notes

`xterm.dart` is vendored under `packages/xterm/` so we can patch bugs and
extend behaviour we hit in andssh. Every local change is recorded in
`packages/xterm/PATCHES.md`.

The Android `MainActivity` extends `FlutterFragmentActivity` (required by
`local_auth` for the biometric prompt). `minSdk` is 24 because
`flutter_secure_storage` 10.x and `local_auth_android` 2.x both require it.

## License

See [LICENSE](LICENSE).
