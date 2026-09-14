# Building keqdroid

This fork uses the staged development and release workflows in [MACOS_CI.md](MACOS_CI.md), including Android, Windows, Linux and two macOS architectures. Build the final `dev` commit, verify its artifacts and complete local acceptance before tagging it. Release publication collects those exact artifacts and does not rebuild them; no AUR publication is performed. Android signing and update-signature keys belong to `caocaocc/keqdroid`, not upstream.

macOS retains Flutter 3.44.4, Go 1.26.8, Xcode 16.4 and CocoaPods 1.16.2 with a macOS 12 deployment target. See [MACOS.md](MACOS.md) for the protected helper, direct PKG distribution and device validation limits. Existing application/data paths remain compatible.

English | [Русский](BUILD.ru.md)

## Requirements

- Flutter 3.44.4, the version CI uses
- Android: Android Studio with the Android SDK, JDK 17 or newer
- Windows: Visual Studio 2022 or newer with the Desktop development with C++ workload
- Linux: Ubuntu 22.04, on its own or in WSL
- Cores: Go and git, plus the Android NDK for the Android cores
- Windows installer: Inno Setup 7.1.1

## Android

```bash
flutter pub get
flutter run                                                  # debug
flutter build apk --release                                  # arm64-v8a
flutter build apk --release --target-platform android-arm    # armeabi-v7a
```

A release build is signed with the key from `android/key.properties` (`storeFile`, `storePassword`, `keyAlias`, `keyPassword`) and fails without it. Crashlytics is added only when `android/app/google-services.json` exists.

After changing the Kotlin version in `android/settings.gradle.kts`, run `flutter clean`, otherwise plugins fail with "Unresolved reference".

## Windows

```powershell
flutter pub get
powershell -File tool/sync_windows_plugins.ps1
flutter build windows --release
```

The build lands in `build\windows\x64\runner\Release\`. `sync_windows_plugins.ps1` rewrites the committed plugin list (`windows/flutter/app_plugins.cmake`, `app_plugin_registrant.cc`) without Firebase, which is Android only and breaks the Windows link.

If the build stops with MSB3073 on `INSTALL.vcxproj`, Defender may have removed a core from `assets/bin/windows/`. Restore it with `git restore` and build again.

## Linux

Release packages are built on Ubuntu 22.04. A build made on a newer GLib does not start on Ubuntu 22.04 or Debian 12, and `tool/package_linux.sh` refuses to package it.

On Ubuntu:

```bash
bash tool/build_linux_wsl.sh   # installs the toolchain and Flutter if missing, then builds
bash tool/package_linux.sh     # .deb, .rpm, .AppImage, .tar.gz and PKGBUILD in release/<version>/
```

Flutter comes from `$FLUTTER_HOME` (`~/flutter` by default); if it is not there, the script clones the stable branch. Both scripts work in the repository itself, so they cannot run at the same time as a Windows or Android build.

From Windows, in WSL. Run it from PowerShell: Git Bash rewrites `/mnt/c/...` paths unless `MSYS_NO_PATHCONV=1` is set.

```powershell
wsl -d Ubuntu-22.04 -e bash /mnt/c/<path>/keqdroid/tool/build_linux_native.sh
```

`build_linux_native.sh` copies the project to the WSL disk, runs both scripts there and copies the packages back to `release/<version>/`. This is how `make_release.ps1` builds Linux.

## Checks

```bash
flutter analyze   # must print "No issues found!"
flutter test
```

CI runs both on every push to master and on every pull request.

## Translations

Strings live in `lib/l10n/app_en.arb` and in `app_ru`, `app_de`, `app_zh`, `app_fa`. A new string goes into all five. `flutter pub get` generates `app_localizations*.dart` from them; those files are not edited by hand.

## Cores

The built cores are in the repository: `assets/bin/windows/`, `assets/bin/linux/` and `android/app/src/main/jniLibs/<abi>/`. They only need rebuilding to update a core or a patch.

```powershell
powershell -File tool/build_xray_cores.ps1   # xray for Android, Windows, Linux
powershell -File tool/build_mihomo.ps1       # mihomo for Android, Windows, Linux
powershell -File tool/fetch_xray_geo.ps1     # geoip.dat and geosite.dat
dart run tool/geo_lite.dart                  # the trimmed geoip for the APK
```

Both build scripts take `-Target android|windows|linux`. The mihomo version is `-Version` in its script. xray is built from the revision pinned in the `go.mod` of a [keqrnel](https://github.com/Lemonochka/keqrnel) checkout next to this repository (`-Keqrnel <path>` for another location). The scripts pin the Go toolchain themselves.

mihomo gets `tool/patches/mihomo-*.patch` and `sing-tun-*.patch`. xray gets keqrnel's `patches/xray-*.patch`, then `tool/patches/xray-*.patch`. A patch that does not apply stops the build. What each patch fixes and what to check on an update is written in its header.

Windows cores are not fully stripped (`-w`, not `-s -w`) and must not be started from `%TEMP%`: Defender blocks an unsigned exe in either case.

## Release

Push the final four-category `dev` history to run Development packages. Each platform and component uploads its successful output immediately; a failed job does not discard completed components. After the exact commit's checks and local acceptance pass, push `v<version>` pointing to that commit. The tag workflow collects only its trusted successful artifacts, validates their reports and hashes, signs the aggregate `SHA256SUMS`, then uploads a draft and publishes it as stable Latest. A publication retry uploads the existing build, without compiling again.

`UPDATE_SIGNING_KEY` contains this fork's Ed25519 main private key and is exposed only to the publication step. The app's main and reserve public keys are in `lib/services/release_signature.dart`; the reserve private key stays outside GitHub. Never commit private keys. A missing or mismatched signature blocks publication, application updates and Geo downloads. The aggregate manifest requires one exact filename per entry, and every release asset except the checksum/signature files must be covered.

Android signing uses the existing `ANDROID_KEYSTORE_BASE64`, `ANDROID_STORE_PASSWORD`, `ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD` Secrets. Android's independent application ID is `io.github.caocaocc.keqdroid`. Native JVM/Robolectric tests run on JDK 25 separately from the JDK 17 application build.

Release assets include:

```
keqdroid-<version>-android.apk
keqdroid-<version>-armeabi-v7a-android.apk
keqdroid-windows-x64-<version>.zip
keqdroid-<version>-linux-x64.tar.gz
keqdroid_<version>_amd64.deb
keqdroid-<version>-1.x86_64.rpm
keqdroid-<version>-x86_64.AppImage
keqdroid-<version>-macos-{arm64,x64}.pkg
keqdroid-<version>-macos-{arm64,x64}-uninstall.pkg
geoip.dat
geoip.dat.sha256
SHA256SUMS
SHA256SUMS.sig
```

Build reports, macOS verification reports and install instructions are also included and covered by the aggregate manifest. The Geo sidecar remains for older downloaders. Windows currently ships ZIP only; its updater retains upstream installed-copy support when an installer exists. APK differential download retains its full-download fallback; this fork does not currently add upstream's optional 7-Zip repacking stage.

The upstream local `make_release.ps1`, Windows installer and AUR helper remain available as source, but are not this fork's release path. SignPath and GitHub build attestations are not enabled for these artifacts; their presence in upstream documentation must not be treated as verification of a fork package. This fork does not publish to AUR.

Verify downloads using the application's signed manifest checks and the platform-specific inspectors described in [MACOS_CI.md](MACOS_CI.md). A SHA-256 comparison alone proves consistency with a manifest, not the manifest's authenticity:

```bash
sha256sum -c --ignore-missing SHA256SUMS
```
