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

APKs are built by the `.github/workflows/release.yml` GitHub Action on every
`v*` tag push.

## Build from source

Requirements: Flutter stable (≥ 3.41), JDK 17+, Android SDK with platform 36
and build-tools 36.

```bash
git clone https://github.com/zond/andssh.git
cd andssh
flutter pub get
flutter build apk --release
```

The output lands in `build/app/outputs/flutter-apk/app-release.apk`.

To cut a release:

```bash
git tag v0.2.0
git push origin v0.2.0
```

The workflow will build the APK and attach it to a new GitHub Release.

## Project layout

```
lib/
  main.dart                       -- provider setup, app entry point
  models/ssh_connection.dart      -- connection + credential data classes
  services/
    secret_store.dart             -- biometric-gated secure storage
    connection_store.dart         -- JSON-file metadata store
    ssh_connector.dart            -- jump host chain resolution (ProxyJump)
  screens/
    connections_page.dart         -- saved connection list
    connection_form_page.dart     -- add/edit a connection
    terminal_page.dart            -- xterm TerminalView + SSH session
  widgets/extra_keys_bar.dart     -- sticky-modifier extra-keys row
```

The Android `MainActivity` extends `FlutterFragmentActivity` (required by
`local_auth` for the biometric prompt). `minSdk` is 24 because
`flutter_secure_storage` 10.x and `local_auth_android` 2.x both require it.

## License

See [LICENSE](LICENSE).
