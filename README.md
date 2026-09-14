<p align="center">
  <img src="assets/icon.png" width="88" alt="KEQDIS">
</p>

<h1 align="center" id="keqdis">KEQDIS</h1>

<p align="center">˚ʚ♡ɞ˚</p>

<p align="center">
  <strong>English</strong> · <a href="#русский">Русский</a>
</p>

<p align="center">
  Proxy and VPN client: subscriptions, standalone configs, routing.<br>
  Android · Windows · Linux · macOS
</p>

<p align="center">
  <a href="https://github.com/caocaocc/keqdroid/releases"><img src="https://img.shields.io/github/v/release/caocaocc/keqdroid?label=release&style=flat-square&color=f5a9b8" alt="release"></a>
  <a href="https://github.com/caocaocc/keqdroid/releases"><img src="https://img.shields.io/github/downloads/caocaocc/keqdroid/total?label=downloads&style=flat-square&logo=github&color=b5e8d5" alt="downloads"></a>
  <a href="https://github.com/caocaocc/keqdroid/actions/workflows/macos.yml"><img src="https://img.shields.io/github/actions/workflow/status/caocaocc/keqdroid/macos.yml?branch=dev&label=build&style=flat-square" alt="build"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-c9b8f5?style=flat-square" alt="license"></a>
  <img src="https://img.shields.io/badge/made%20with-Flutter-9bc7f0?style=flat-square" alt="flutter">
  <a href="https://t.me/keqdroid"><img src="https://img.shields.io/badge/Telegram-chat-8ec5e6?style=flat-square&logo=telegram&logoColor=white" alt="Telegram chat"></a>
</p>

<p align="center">
  <a href="https://github.com/caocaocc/keqdroid/releases"><strong>Download</strong></a>
  &nbsp;·&nbsp;
  <a href="https://t.me/keqdroid">Telegram chat</a>
  &nbsp;·&nbsp;
  <a href="docs/BUILD.md">Build from source</a>
</p>

---

<h2 id="screenshots">Screenshots</h2>

| Android | Windows |
|:-------:|:-------:|
| <img src="docs/readme/android.png" width="280" alt="Android"> | <img src="docs/readme/windows.png" width="480" alt="Windows"> |

---

## Download

This fork follows [Lemonochka/keqdroid](https://github.com/Lemonochka/keqdroid), retaining the upstream KEQDIS name. App updates and Geo downloads come from this repository.

Pre-built binaries are on [Releases](https://github.com/caocaocc/keqdroid/releases).
One `SHA256SUMS` holds the hash of every file in the release. The built-in updater looks its own asset up there and refuses to install when the line is missing or the hash does not match.

| Platform | Files in release |
|----------|------------------|
| **Android** 7.0+ | `keqdroid-<version>-android.apk` |
| **Windows** x64 | `keqdroid-windows-x64-<version>.zip` (portable) |
| **Linux** x64 | `keqdroid-<version>-x86_64.AppImage` · `keqdroid_<version>_amd64.deb` · `keqdroid-<version>-1.x86_64.rpm` · `keqdroid-<version>-linux-x64.tar.gz` · `PKGBUILD` for a manual Arch build |
| **macOS** arm64 / x64 | `keqdroid-<version>-macos-arm64.pkg` · `keqdroid-<version>-macos-x64.pkg` |

The app **does not provide servers**. Bring your own subscription or configs. Comply with the laws of your country.

---

## Features

**Servers and subscriptions**
- subscription URLs with scheduled auto-update; `keqdroid://` and `keqdis://` deep links from provider panels
- manual entry, config import, QR code scan (Android)
- proxy chains: traffic passes through several servers in the order you set
- device identity per subscription — what the panel sees when the app fetches it
- checks: TCP, HTTP, ICMP, speed test; sorting by ping, name or speed

**Routing and tunnel**
- three lists — direct, through the VPN, blocked — plus ready-made presets to start from
- split tunnel: per-app on Android, per-program on Windows, Linux and macOS (TUN mode)
- **Connections** — a live list of where traffic is going and which rule sent it there

**Appearance and data**
- color presets, dark and light, Material You palette on Android
- interface size, on top of the system text size
- backup and restore: settings, servers, subscriptions with their images, split-tunnel lists
- share the local proxy over LAN
- hotkeys for connect/disconnect, TUN mode, best-ping server, show/hide window — system-wide on Windows and macOS, while the window is focused on Linux
- English, Русский, Deutsch, 中文, فارسی
- updates from GitHub Releases

---

## Cores

Four cores ship inside the app. Which one runs a given server is decided by the server's format, not by preference — a ready-made config only makes sense to the core it was written for:

| Server format | Runs on |
|---------------|---------|
| Links: `vless://` `vmess://` `trojan://` `ss://` `hy2://` | Xray or mihomo — your pick |
| Ready-made Xray config (`.json`) | Xray |
| Ready-made Clash / mihomo config | mihomo |
| Proxy chain | Xray |
| AmneziaWG profile (`.conf`) | mihomo |

The choice lives in **Settings → About** and applies to links, where both cores fit. **Automatic** leaves it to the format. When a server cannot run on the core you picked, the app says so on the spot instead of quietly switching — a silent fallback is exactly what makes "I selected mihomo and it says Xray" impossible to debug.

---

## Protocols

| Protocol | Link format / import |
|----------|----------------------|
| VLESS | `vless://` |
| VMess | `vmess://` |
| Trojan | `trojan://` |
| Shadowsocks | `ss://` |
| Hysteria 2 | `hysteria2://`, `hy2://` |
| AmneziaWG | `.conf` profile |
| Ready-made Xray config | whole `.json` (paste, file, subscription) |
| Ready-made Clash config | whole config (paste, file, subscription) |

Hysteria v1 is not supported.

A ready-made config runs as its author wrote it — routing, DNS and outbound chains included; only the inbounds are replaced with the app's own. The name comes from the config's root `remarks`. The author's rules decide first, and your own direct / proxy / block lists only see what those rules did not already match — if the config ends with a catch-all, and most do, they never come into play at all.

---

## Platforms

### Android

| Mode | What it does |
|------|--------------|
| **VPN** | Everything on the device goes through the tunnel. VPN permission on first connect. |
| **Proxy** | SOCKS and HTTP on `127.0.0.1`, nothing captured on its own — point an app or the Wi-Fi proxy settings at it. |

Per-app routing and DNS interception belong to VPN mode. Notification shade icon and a Quick Settings tile; subscriptions update in the background.

This fork uses its own application ID (`io.github.caocaocc.keqdroid`) and persistent release signing key. It installs alongside the upstream app. Export a backup from the old app and import it here when migrating; later updates keep this installation and its data.

### Windows

| Mode | What it does |
|------|--------------|
| **Proxy** | System proxy — browsers and most apps. No administrator rights. |
| **TUN** | All traffic through a VPN adapter. Run as administrator. |

The window minimizes to the tray and remembers its size and position. Launch at system startup with optional auto-connect. Global hotkeys are in Settings → Advanced → Hotkeys. Subscriptions refresh while the app is open.

**Settings location:** `%APPDATA%\com.keqdroid\keqdroid\` — not next to the exe. To move to another PC, use backup and restore in settings.

### Linux

Debian/Fedora/Arch, x86_64. Releases ship AppImage, deb, rpm and tar.gz. The release includes `PKGBUILD` for a manual Arch build with `makepkg -si`; this fork does not publish to the AUR.

| Mode | What it does |
|------|--------------|
| **Proxy** | No root |
| **TUN** | Root via `pkexec` (polkit) on connect |

The window remembers its size and position; hotkeys work while the app window is focused.

### macOS

Install the PKG matching your Mac: arm64 for Apple Silicon, x64 for Intel. The installer places the app and protected network components in their managed locations and asks for administrator authorization. Proxy mode runs its core as the current user and switches the system proxy; TUN uses the installed network service. Closing the window keeps the connection and menu bar item running. Quit disconnects and restores network settings.

The app uses ad-hoc signing, without Developer ID signing or Apple notarization. Allow installation in the system UI when prompted. Each architecture also has a `keqdroid-<version>-macos-<arch>-uninstall.pkg`; it restores the network, removes system components and keeps user settings by default.

Clients that only recognize DMG updates need one manual PKG upgrade. Build targets start at macOS 12; the release acceptance report lists the systems and architectures actually tested. Build success alone does not establish macOS 12 or Intel runtime support.

---

## Getting started

1. **Subscriptions** — paste the URL, then «Add and fetch».
2. **Servers** — pick a node.
3. Connect.
4. If needed — **Settings**: routing, split tunnel, hotkeys, connection mode.

---

## Development

Environment, per-platform builds, tests and releases: [`docs/BUILD.md`](docs/BUILD.md).

### Build

```bash
flutter pub get
flutter build apk --release      # Android
flutter build windows --release  # Windows
```

The Windows plugin list (`windows/flutter/app_plugins.cmake`) is checked in with Firebase (Android-only) already stripped, so a normal build just works. Re-run `powershell -File tool/sync_windows_plugins.ps1` only after adding or removing plugins.

**Linux** — build on Linux or WSL only, the Windows SDK cannot target Linux:

```bash
wsl -e bash /mnt/c/.../keqdroid/tool/build_linux_wsl.sh
# binary: build/linux/x64/release/bundle/keqdroid
```

Place the required core binaries in `assets/bin/windows/` before a Windows build — see [`assets/bin/windows/README.md`](assets/bin/windows/README.md).

### Releases

The `dev` workflows build Android, Windows, Linux and both macOS architectures independently, retaining completed components for reuse. The release workflow publishes the verified artifacts for the exact tagged commit; it does not rebuild them. The tag `vX.Y.Z` and version come from `pubspec.yaml`.

Release files share one `SHA256SUMS`; `geoip.dat.sha256` is also included for older clients. When retrying a failed build or upload, retain successful artifacts. This fork publishes GitHub Releases only, not AUR packages.

---

## License

[GPL-3.0](LICENSE). The bundled cores keep their upstream licenses: Xray-core (MPL-2.0), mihomo (GPL-3.0), sing-box (GPL-3.0).

---

<h2 id="русский">Русский</h2>

<p align="center">˚ʚ♡ɞ˚</p>

<p align="center">
  <a href="#keqdis">English</a> · <strong>Русский</strong>
</p>

<p align="center">
  Клиент прокси и VPN: подписки, отдельные конфиги, маршрутизация.<br>
  Android · Windows · Linux · macOS
</p>

<p align="center">
  <a href="https://github.com/caocaocc/keqdroid/releases"><img src="https://img.shields.io/github/v/release/caocaocc/keqdroid?label=%D1%80%D0%B5%D0%BB%D0%B8%D0%B7&style=flat-square&color=f5a9b8" alt="релиз"></a>
  <a href="https://github.com/caocaocc/keqdroid/releases"><img src="https://img.shields.io/github/downloads/caocaocc/keqdroid/total?label=%D1%81%D0%BA%D0%B0%D1%87%D0%B8%D0%B2%D0%B0%D0%BD%D0%B8%D1%8F&style=flat-square&logo=github&color=b5e8d5" alt="скачивания"></a>
  <a href="https://github.com/caocaocc/keqdroid/actions/workflows/macos.yml"><img src="https://img.shields.io/github/actions/workflow/status/caocaocc/keqdroid/macos.yml?branch=dev&label=%D1%81%D0%B1%D0%BE%D1%80%D0%BA%D0%B0&style=flat-square" alt="сборка"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/%D0%BB%D0%B8%D1%86%D0%B5%D0%BD%D0%B7%D0%B8%D1%8F-GPL--3.0-c9b8f5?style=flat-square" alt="лицензия"></a>
  <img src="https://img.shields.io/badge/сделано%20на-Flutter-9bc7f0?style=flat-square" alt="flutter">
  <a href="https://t.me/keqdroid"><img src="https://img.shields.io/badge/Telegram-%D1%87%D0%B0%D1%82-8ec5e6?style=flat-square&logo=telegram&logoColor=white" alt="Чат в Telegram"></a>
</p>

<p align="center">
  <a href="https://github.com/caocaocc/keqdroid/releases"><strong>Скачать</strong></a>
  &nbsp;·&nbsp;
  <a href="https://t.me/keqdroid">Чат в Telegram</a>
  &nbsp;·&nbsp;
  <a href="docs/BUILD.md#русский">Сборка из исходников</a>
</p>

---

## Скачать

Этот форк следует за [Lemonochka/keqdroid](https://github.com/Lemonochka/keqdroid) и сохраняет имя KEQDIS. Обновления приложения и загрузка Geo-баз идут из этого репозитория.

Скриншоты — [выше](#screenshots).

Готовые сборки — в [Releases](https://github.com/caocaocc/keqdroid/releases).
Хеши всего релиза лежат в одном `SHA256SUMS`: встроенный апдейтер находит там свой файл и не ставит обновление, если строки нет или хеш не сошёлся.

| Платформа | Файлы в релизе |
|-----------|----------------|
| **Android** 7.0+ | `keqdroid-<версия>-android.apk` |
| **Windows** x64 | `keqdroid-windows-x64-<версия>.zip` (portable) |
| **Linux** x64 | `keqdroid-<версия>-x86_64.AppImage` · `keqdroid_<версия>_amd64.deb` · `keqdroid-<версия>-1.x86_64.rpm` · `keqdroid-<версия>-linux-x64.tar.gz` · `PKGBUILD` для ручной сборки Arch |
| **macOS** arm64 / x64 | `keqdroid-<версия>-macos-arm64.pkg` · `keqdroid-<версия>-macos-x64.pkg` |

Приложение **не раздаёт серверы** — нужна своя подписка или конфиги. Соблюдайте законы вашей страны.

---

## Возможности

**Серверы и подписки**
- подписки по URL с автообновлением по расписанию; deep-ссылки `keqdroid://` и `keqdis://` из панелей провайдеров
- ручное добавление, импорт конфигов, сканирование QR-кодов (Android)
- цепочки прокси: трафик проходит через несколько серверов в заданном порядке
- идентичность устройства для каждой подписки — то, каким приложение представляется панели при загрузке
- проверки: TCP, HTTP, ICMP, тест скорости; сортировка по пингу, имени или скорости

**Маршрутизация и туннель**
- три списка — напрямую, через VPN, блокировать — и готовые пресеты, чтобы начать
- split tunnel: на Android по приложениям, на Windows, Linux и macOS по программам (режим TUN)
- **Соединения** — живой список того, куда идёт трафик и какое правило его туда отправило

**Оформление и данные**
- цветовые пресеты, тёмная и светлая тема, палитра Material You на Android
- размер интерфейса, поверх системного размера текста
- резервная копия и восстановление: настройки, серверы, подписки вместе с их картинками, списки split tunnel
- раздача локального прокси в локальную сеть
- хоткеи на подключение, режим TUN, сервер с лучшим пингом, показать/скрыть окно — глобальные на Windows и macOS, в фокусе окна на Linux
- English, Русский, Deutsch, 中文, فارسی
- обновление из GitHub Releases

---

## Ядра

Внутри приложения четыре ядра. Какое исполняет конкретный сервер, решает формат этого сервера, а не предпочтение: готовый конфиг понятен только тому ядру, для которого он написан.

| Формат сервера | Исполняет |
|----------------|-----------|
| Ссылки: `vless://` `vmess://` `trojan://` `ss://` `hy2://` | Xray или mihomo — на выбор |
| Готовый конфиг Xray (`.json`) | Xray |
| Готовый конфиг Clash / mihomo | mihomo |
| Цепочка прокси | Xray |
| Профиль AmneziaWG (`.conf`) | mihomo |

Выбор живёт в **Настройки → О приложении** и касается ссылок — там подходят оба ядра. **Автоматически** отдаёт решение формату. Если сервер не может поехать на выбранном ядре, приложение скажет об этом сразу, а не переключится молча: именно тихий откат превращает «включила mihomo, а пишет Xray» в неразрешимую загадку.

---

## Протоколы

| Протокол | Формат ссылки / импорт |
|----------|------------------------|
| VLESS | `vless://` |
| VMess | `vmess://` |
| Trojan | `trojan://` |
| Shadowsocks | `ss://` |
| Hysteria 2 | `hysteria2://`, `hy2://` |
| AmneziaWG | профиль `.conf` |
| Готовый конфиг Xray | `.json` целиком (вставка, файл, подписка) |
| Готовый конфиг Clash | конфиг целиком (вставка, файл, подписка) |

Hysteria v1 не поддерживается.

Готовый конфиг исполняется так, как его написал автор: роутинг, DNS и цепочки аутбаундов остаются его, подменяются только инбаунды на собственные. Имя берётся из корневого `remarks`. Первыми решают авторские правила, и до списков обход / прокси / блок доходит только то, что они не поймали, — а если конфиг кончается catch-all-правилом, как бывает почти всегда, не доходит вовсе.

---

## Платформы

### Android

| Режим | Что делает |
|-------|------------|
| **VPN** | Через туннель идёт всё устройство. При первом подключении — разрешение VPN. |
| **Proxy** | SOCKS и HTTP на `127.0.0.1`, сам по себе не перехватывает ничего — на него нужно направить программу или настройки прокси в Wi-Fi. |

Маршрутизация по приложениям и перехват DNS живут в режиме VPN. Значок в шторке и плитка в быстрых настройках; подписки обновляются в фоне.

У форка свой ID приложения (`io.github.caocaocc.keqdroid`) и постоянный ключ подписи релизов. Он устанавливается рядом с апстримом. Для перехода экспортируйте резервную копию из старого приложения и импортируйте здесь; дальнейшие обновления сохраняют эту установку и её данные.

### Windows

| Режим | Что делает |
|-------|------------|
| **Proxy** | Системный прокси — браузеры и большинство программ. Без прав администратора. |
| **TUN** | Весь трафик через VPN-адаптер. Запуск от имени администратора. |

Окно сворачивается в трей и запоминает свой размер и позицию. Автозапуск вместе с системой, при желании с автоподключением. Глобальные хоткеи — в Настройки → Расширенные → Горячие клавиши. Подписки обновляются, пока приложение открыто.

**Где лежат настройки:** `%APPDATA%\com.keqdroid\keqdroid\` — не в папке с exe. Перенос на другой ПК: резервная копия и восстановление в настройках.

### Linux

Debian/Fedora/Arch, x86_64. В релизе — AppImage, deb, rpm и tar.gz. Для Arch среди файлов релиза есть `PKGBUILD` для ручного `makepkg -si`; этот форк не публикуется в AUR.

| Режим | Что делает |
|-------|------------|
| **Proxy** | Без root |
| **TUN** | Root через `pkexec` (polkit) при подключении |

Окно запоминает размер и позицию; хоткеи работают, пока окно приложения в фокусе.

### macOS

Установите PKG для своего Mac: arm64 для Apple Silicon, x64 для Intel. Установщик размещает приложение и защищённые сетевые компоненты и запрашивает права администратора. В Proxy ядро работает от текущего пользователя и переключает системный прокси; TUN использует установленную сетевую службу. Закрытие окна оставляет соединение и значок в строке меню; выход восстанавливает сетевые настройки.

Используется ad-hoc подпись, без Developer ID и нотариализации Apple. При необходимости разрешите установку в системном интерфейсе. Для каждой архитектуры есть `keqdroid-<версия>-macos-<архитектура>-uninstall.pkg`: он восстанавливает сеть и удаляет системные компоненты, по умолчанию сохраняя пользовательские настройки.

Клиентам, распознающим только DMG, нужен один ручной переход на PKG. Минимальная цель сборки — macOS 12; реально проверенные системы и архитектуры перечислены в отчёте приёмки релиза. Успешная сборка сама по себе не подтверждает работу на macOS 12 или Intel.

---

## Начало работы

1. **Подписки** — вставить URL, затем «Добавить и загрузить».
2. **Серверы** — выбрать узел.
3. Подключиться.
4. При необходимости — **Настройки**: маршрутизация, split tunnel, хоткеи, режим подключения.

---

## Разработка

Окружение, сборка под каждую платформу, тесты и релизы — [`docs/BUILD.md`](docs/BUILD.md#русский).

### Сборка

```bash
flutter pub get
flutter build apk --release      # Android
flutter build windows --release  # Windows
```

Список Windows-плагинов (`windows/flutter/app_plugins.cmake`) лежит в репозитории уже без Firebase (он только для Android), так что обычная сборка работает сразу. Перезапускать `powershell -File tool/sync_windows_plugins.ps1` нужно только после добавления или удаления плагинов.

**Linux** — только на Linux или в WSL, Windows SDK для Linux не подходит:

```bash
wsl -e bash /mnt/c/.../keqdroid/tool/build_linux_wsl.sh
# бинарь: build/linux/x64/release/bundle/keqdroid
```

Для Windows перед сборкой нужно положить бинарники ядер в `assets/bin/windows/` — см. [`assets/bin/windows/README.md`](assets/bin/windows/README.md).

### Релизы

Workflow ветки `dev` независимо собирают Android, Windows, Linux и обе архитектуры macOS, сохраняя готовые компоненты для повторного использования. Workflow релиза публикует проверенные артефакты точного коммита тега, без повторной сборки. Тег `vX.Y.Z` и версия берутся из `pubspec.yaml`.

Общий `SHA256SUMS` содержит хеши файлов релиза; `geoip.dat.sha256` сохраняется для старых клиентов. При повторе неудачной сборки или загрузки уже готовые артефакты используются повторно. Форк публикуется только в GitHub Releases, не в AUR.

---

## Лицензия

[GPL-3.0](LICENSE). Встроенные ядра — под своими лицензиями: Xray-core (MPL-2.0), mihomo (GPL-3.0), sing-box (GPL-3.0).

---

<p align="center">✦ ˚ · . &nbsp; ˚ʚ♡ɞ˚ &nbsp; . · ˚ ✦</p>
<p align="center"><sub>made with ♡ · Flutter + Xray + mihomo + sing-box</sub></p>
