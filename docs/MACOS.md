# macOS 开发与验收

本分支实现 macOS 桌面客户端的源代码、核心构建、安装打包和 CI。目标为 macOS 12 及以上、Apple Silicon 与 Intel，产品名 `KEQDIS`，Bundle ID 为 `io.github.caocaocc.keqdroid`。

**当前为开发实现，尚未通过发布验收。** 本机只有 Command Line Tools，完整应用改由 GitHub CI 构建；Runner 和原生插件已经完成两个架构的编译，安装包仍须通过实际最低系统版本与签名检查。安装授权和真实网络路径分别记录验收结果，不能把新系统编译成功当作 macOS 12 已验证。分段构建、复用和本机校验方法见 [MACOS_CI.md](MACOS_CI.md)。

## 工程结构与运行边界

| 位置 | 职责 |
| --- | --- |
| `macos/Runner` | Flutter 窗口、应用生命周期、桌面和网络 MethodChannel |
| `macos/DesktopSupport` | 菜单栏、Carbon 全局快捷键、窗口恢复、应用枚举、用户 LaunchAgent |
| `macos/NetworkService` | C XPC 身份验证、Swift 客户端、root 网络服务、系统配置恢复 |
| `lib/tunnel/macos_tunnel_backend.dart` | 串行连接/取消/断开、会话状态、端口、统计、网络变化重建 |
| `lib/tunnel/macos_session_config.dart` | macOS 运行副本与原生请求协议 |
| `lib/platform/desktop_capabilities.dart` | 各桌面平台已实现的能力 |
| `lib/tunnel/desktop_runtime.dart` | 为连接列表、日志、诊断提供运行中核心信息 |
| `lib/models/macos_app_routing.dart` | 独立的 Bundle ID、安装位置和进程路径记录 |
| `tool/macos`、`tool/patches/macos` | 固定来源的 Darwin 核心、DNS 补丁、安装生命周期 |
| `tool/package_macos.py` | 检查、逐层签名、PKG、DMG 和 SHA-256 |

GUI 始终使用普通账户运行。网络服务统一监督长期会话，Proxy 核心在执行前降为调用账户 UID/GID；TUN 主核心使用 root，AWG 的上游 wireproxy 仍降权。临时测速核心由 GUI 从应用包运行。此处选择统一的 helper 监督与恢复协议，避免两个长期进程管理器争抢会话。

安装位置固定如下，用户配置保存在用户 Application Support 中：

```text
/Applications/KEQDIS.app
  Contents/Resources/cores/{keqrnel,mihomo,wireproxy}
  Contents/Resources/geo/{geoip.dat,geosite.dat}
/Library/Application Support/io.github.caocaocc.keqdroid/
  bin/{keqdis-network-service,keqrnel,mihomo,wireproxy}
  geo/{geoip.dat,geosite.dat}
  client-requirement.txt
  core-manifest.json
  provenance.json
  state/                  # root 私有恢复记录、授权记录
  sessions/               # 按会话/账户隔离，含密钥文件0600
/Library/LaunchDaemons/io.github.caocaocc.keqdroid.network-service.plist
~/Library/LaunchAgents/io.github.caocaocc.keqdroid.login.plist
```

桌面通道为 `keqdis_vpn_channel`；网络通道为 `io.github.caocaocc.keqdroid/network`。网络协议版本为 `1`，独立 helper 组件版本为 `1.0.0`，与应用产品版本分别管理。

| 网络方法 | 作用 |
| --- | --- |
| `getServiceStatus` | 返回已安装、TUN 账户授权、免提权 Proxy 能力、协议/组件版本、是否被其他账户占用 |
| `authorize` | GUI 取得 TUN 系统管理员授权，helper 校验后保存账户与客户端版本指纹 |
| `prepareNetworkContext` | 捕获物理出口、真实 DNS、网络服务 ID；返回短期有效 context ID |
| `startProxySession` | 无需 TUN 授权；只接收 Proxy 配置，自动设置系统代理；核心降为调用账户 UID/GID |
| `startSession` | 需要 TUN 账户授权；固定核心类型、结构化配置、会话 ID、实际端口、DNS 目标；不接收命令/环境/二进制路径 |
| `getSession` | 同一账户和连接的会话状态、实际 utun、PID、API 凭据、日志和重连提示 |
| `stopSession` | 根据会话所有权恢复网络，然后终止进程 |

启动和停止串行；Dart 按会话 ID 丢弃迟到事件。helper 拒绝接管其他账户或连接的活动会话；停止必须匹配会话 ID，恢复失败也保留原连接的所有权。helper 监测 GUI 断开、核心退出和网络变化。关闭窗口不关闭 XPC；退出或 GUI 失联会触发恢复。GUI 的 Cmd+Q 在恢复失败时取消退出并显示错误，不把恢复失败伪装为成功。

## 安全与授权

采用 **ad-hoc 签名，无 Developer ID，无 Apple 公证**，不在 Mac App Store 分发。用户需要在 macOS 安全设置中允许可信下载，并在 PKG 安装/升级时授权管理员操作。不要全局关闭 Gatekeeper。

PKG 管理全部受保护二进制、客户端指纹和核心摘要；普通客户端不能扩大信任清单。XPC 对所有消息（包括状态查询）使用发送方真实代码身份与精确 cdhash，验证固定应用位置、root 所有权、完整资源、嵌套代码与包内链接。主程序 cdhash 不是完整性检查的替代品。

Proxy 连接不请求管理员授权；只有已通过签名和完整资源验证的固定位置客户端、普通 macOS 账户可以使用免提权接口。该接口拒绝 TUN 模式、TUN 配置、系统 DNS 目标和物理网络上下文；系统代理由安装时已获授权的 helper 设置、验证并恢复。旧 helper 缺少能力标记时提示升级，不回退到弹窗授权。

首次 TUN 手动连接或权限页授权时，客户端申请系统 `system.privilege.admin` 权限；helper 验证外部授权表单后，写入当前 UID 与已安装版本指纹。升级改变指纹后需为新版本再次授权；之后该版本的正常连接和明确的登录自动连接不重复弹窗。

根服务只执行已安装清单内的核心，启动前重新校验核心 SHA-256。配置先在 Dart 准备，再由 helper 独立校验、写入私有目录。外部文件依赖、外部监听、脚本和越界路径被明确拒绝。HTTP 规则提供者只能使用受限相对缓存路径；TUN 拒绝未经预先展开和校验的远程代理提供者，防止 root 核心在初始校验之后解析新的文件引用。原始订阅/手工配置不被改写。

root TUN 核心固定收到 `KEQDIS_PRIVILEGED_RUNTIME=1`。Darwin 核心补丁对白名单外的控制 API 返回 403，包括配置替换、升级、重启、提供者更新、调试/UI/DoH 入口，防止使用 Clash API 凭据绕过 helper 校验。只保留统计读取、关闭连接和选择已经存在的代理。原生校验也禁用 embedded Xray 独立管理服务、服务端文件入口和 TLS/Reality 文件日志等额外能力。

`Release.entitlements` 允许 ad-hoc Flutter 框架加载所需的 library-validation 例外；不授予 `get-task-allow` 或任意 DYLD 环境注入。已用真实 Flutter 3.44.4 框架和 ad-hoc Hardened Runtime 小程序验证本机动态加载；该测试不启动 GUI/引擎，不替代完整 Runner、插件和真实下载环境的 M0 验收。

## TUN、DNS 与系统代理

keqrnel、Mihomo、AWG 均有 Proxy/TUN 请求路径；AWG TUN 使用 wireproxy → keqrnel。Darwin 配置省略固定接口名，由核心分配 utun，helper 确认实际接口和路由。未达到就绪条件时不报告已连接。

系统代理通过 SystemConfiguration 按网络服务 ID 操作，使用当前分配的 SOCKS/HTTP 端口；保存 HTTP、HTTPS、SOCKS、PAC、自动发现和绕过字段。Proxy 模式不改 DNS。修改系统设置前持久化 journal；恢复只处理仍等于本会话写入值的字段，保留连接期间用户/其他程序所做的修改。

TUN DNS 使用核心虚拟端点：keqrnel/AWG 为 `172.19.0.2`，Mihomo 从运行配置推导（默认 `198.18.0.2`）。Swift 不在 `127.0.0.1:53` 新建 DNS 服务。先测试 UDP/TCP DNS，再修改系统 DNS，并复测系统解析路径。恢复 DNS/代理后才停止核心。

虚拟 DNS 探测每条查询最多等待 8 秒，UDP 和 TCP 共享 15 秒总期限，避免把代理 DNS 的冷启动延迟误判为不可用。查询期间保留同一个 socket，定期读取有限数量的核心日志并检查核心与接口；UDP 失败也会检查 TCP，错误中分别保留两者结果。TCP 连接、帧头和响应分片共用同一单调时钟期限，不因收到部分数据而重新计时。这只检查 DNS 协议响应，提交设置后仍须通过下面的系统解析检查。

提交设置后，helper 最多等待 5 秒核验全部受管服务已提交的字段和协议启用状态，以及主服务的有效全局代理/DNS。第三方修改会使连接失败，并由原有比较后恢复逻辑保留其修改。仅 TUN 使用公开 `DNSServiceQueryRecord`，按当前系统 DNS 策略查询随机 `keqdis-<UUID>.example.com.` 的 A 记录。该 API 在 macOS 12 及较新版本中无法仅凭 `NoSuchRecord` 区分正常 NXDOMAIN 与部分 SERVFAIL，因此负响应必须再由 `example.com.` 的有效 A 正答案确认；两次查询共享总计 5 秒期限，失败或超时不进入已连接状态。若用户规则屏蔽了整个 `example.com`，此项就绪检查可能失败，诊断会明确指出探测域，用户 DNS 规则不会被更改。系统允许的正常缓存仍适用于正答案兜底查询；本检查不承诺绕过系统缓存或验证所有域名策略。

启动前保存物理 DNS 和出口，注入固定环境契约：

```text
KEQDIS_BOOTSTRAP_DNS=["192.168.1.1"]
KEQDIS_BOOTSTRAP_INTERFACE=en0
```

macOS TUN 在未启用自定义 DNS 时，自动生成的链接和代理链使用这份物理快照解析各节点的实际服务器域名。该策略只应用于节点的精确 bootstrap 域名，普通业务 DNS 仍按现有规则运行；明确开启的自定义 DNS、完整作者配置、Proxy 和其他平台保持原策略。这样可以避免物理网络无法直连默认公共 DoH 时，节点启动先消耗一次失败等待。合理的 DNS 就绪期限仍保留，作为慢响应的容错上限。

Darwin 补丁覆盖 keqrnel local DNS、Xray 隐式/新建 resolver 和 Mihomo system resolver。有效快照绑定物理出口；错误或不完整快照拒绝启动；失败不静默回退公共 DNS。用户明确配置的 DoH/DoT/代理 DNS 保留。网络切换后重建整个快照与会话。补丁来源、范围和单独测试方法见 [`tool/patches/macos/README.md`](../tool/patches/macos/README.md)。

开启 IPv6 防泄漏要求时，必须证明捕获/阻断成立；否则拒绝连接。目前 Mihomo 的该组合会明确拒绝，keqrnel/AWG 必须同时通过配置与实际 IPv6 路由校验。保留 mDNS/系统本地域行为，不承诺接管另一 VPN 的 scoped DNS；发现冲突时停止并报告。

当前物理网络上下文需要可识别的 IPv4 默认出口。纯 IPv6-only 网络会明确拒绝，尚未作为支持场景；双栈网络仍按上述 IPv6 策略验收。Mihomo 使用包内 DAT Geo 模式，不自动下载 MMDB/ASN 数据；依赖未随包提供数据库的规则需先转换或移除。

## 桌面行为与兼容性

- 使用现有桌面首页和主题；默认关闭窗口后留在菜单栏，Dock/菜单栏可恢复窗口。窗口位置会重新限制到可用显示器范围。
- 全局快捷键使用 Carbon `RegisterEventHotKey`，冲突反馈设置页；保持存储 token，macOS 显示 `⌘ ⌥ ⌃ ⇧`。
- `keqdroid://`、`keqdis://` 走现有导入确认流程；冷启动排队、热启动提示、重复事件去重。
- 应用枚举保存 Bundle ID 与路径，展开主程序、嵌套 Helper 和 XPC 可执行文件；不把 Bundle ID 当进程名，不添加 `.exe`。缺失应用保留为待匹配项。共享系统进程不能保证归属到应用。
- macOS 分流记录使用独立可选备份字段；旧备份没有该字段时恢复为空列表。
- 登录启动默认关闭，使用用户 LaunchAgent、显式 `--login` 标记且没有 `KeepAlive`。只有登录启动、启用自动连接且网络组件匹配时才连接上次节点；TUN 还必须已有账户授权。用户禁用系统后台项后不会循环重建。
- Firebase 初始化、扫码与移动后台任务保持 Android 范围；macOS 的 Podfile 和显式插件注册器不链接这些 SDK。
- Geo 数据和核心随完整 PKG 更新。macOS 不提供单独核心自更新或写入应用包的 Geo 下载。
- 首版监听仅 loopback，不开放 LAN 共享入口；没有系统级 Kill Switch 承诺。

## 构建

锁定 Flutter `3.44.4`、现有 `pubspec.lock`、CocoaPods `1.16.2` 和 `macos/Podfile.lock`。CI 使用 Xcode `16.4`、明确的 `macos-15`/`macos-15-intel`。所有目标最低 macOS 为 12；打包再次检查每个 Mach-O 的实际最低版本。

核心使用 Go `1.26.8`，构建脚本下载并校验独立工具链，设置 `GOTOOLCHAIN=local`。来源及补丁校验在 `tool/macos/core-manifest.json`：

| 核心 | 固定版本 |
| --- | --- |
| keqrnel | `38155c34606f77299a62902da11372ff1c1921d7` |
| Mihomo | `v1.19.30`，保留原有仓库补丁 |
| wireproxy-awg | `v1.0.18` |

安装完整 Xcode 并选择其 Developer 目录后，在项目根目录运行：

```sh
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
python3 tool/macos/check_flutter_framework.py --flutter-root "$FLUTTER_ROOT"
swift test --package-path macos/DesktopSupport
swift run --package-path macos/DesktopSupport keqdis-desktop-tests
swift test --package-path macos/NetworkService
swift run --package-path macos/NetworkService keqdis-network-tests
bash tool/build_macos_cores.sh --arch arm64
python3 tool/package_macos.py --arch arm64
```

Intel 在 Intel 构建环境将最后两个参数改为 `x64`。核心构建可在同一 Mac 交叉编译；Flutter/插件实际安装和运行仍要分别测试。打包不安装服务、不执行 TUN、不修改构建机器的系统代理。

产物在 `build/macos-release/`：

```text
keqdroid-<version>-macos-arm64.dmg
keqdroid-<version>-macos-arm64.dmg.sha256
keqdroid-<version>-macos-arm64-verification.json
keqdroid-<version>-macos-x64.dmg
keqdroid-<version>-macos-x64.dmg.sha256
keqdroid-<version>-macos-x64-verification.json
```

DMG 包含 `Install KEQDIS.pkg`、`Uninstall KEQDIS.pkg` 和安装说明。所有嵌套 Mach-O、框架、应用由内到外签名，然后生成客户端指纹和签名后核心摘要，最后制作 PKG/DMG。`provenance.json` 保留原始核心构建来源、补丁、Go 模块和签名前摘要；签名后摘要单独记录。

## 更新、卸载与中断恢复

macOS 更新源固定为 [`caocaocc/keqdroid`](https://github.com/caocaocc/keqdroid/releases)，其他平台保持原来源。更新器只接受匹配当前 ABI 的 macOS DMG，下载后验证 `.sha256`，断开连接再打开安装介质。它不会选择 APK、Windows ZIP 或其他架构；不做静默自替换。

安装器要求先退出 GUI，将组件放在受保护 staging 目录，验证后恢复并停止旧服务，再整体切换应用和运行时。失败时回滚旧组件，或保留恢复材料且保持断开，避免以半套组件继续运行。

卸载器先恢复网络/停止核心与服务，再移除应用、系统组件和本产品登录项，默认保留用户配置和订阅。

如果安装报告 `.previous` 目录，不要删除它或 journal。也要保留 `.incoming/rollback-network-service.plist`，它保存升级前的 LaunchDaemon 原始文件。它表示一次中断的升级：

1. 退出 GUI，保留两个目录及日志，确认没有其他账户仍使用连接。
2. 由管理员停止本产品 LaunchDaemon，并对**仍安装在固定 runtime 位置的服务**执行 `--recover`。只有恢复成功才能继续更换目录；不要随意执行来自下载目录的“修复工具”。
3. 若自动回滚已完成，重新运行完整安装器；若原运行时/应用仍在 `.previous`，需在断开状态下成对恢复旧目录，再使用对应旧版本 LaunchDaemon plist。保留现存 `state` 中尚未恢复的 journal，不能用旧的空 state 覆盖它。
4. 不确定哪一份 journal 持有网络设置时停止手工操作并检查日志/系统设置。禁止直接清空 state 来绕过安装检查。

`keqdis-network-service --self-check` 只输出版本/协议，不提权、不修改系统；`--recover` 仅允许 root，用于安装恢复，正常运行由 launchd 管理。

## 发布闸门

CI 只上传 `unvalidated` 开发产物，不自动发布 GitHub Release。新系统构建不能替代下列验收；通过后才在 `caocaocc/keqdroid` 发布对应两种资产及校验文件。

| 阶段 | 需要确认 |
| --- | --- |
| M0 | macOS 12 两架构实际启动；真实浏览器下载的 ad-hoc 应用/PKG可允许安装；XPC授权有效，伪造客户端被拒绝 |
| M1 | 三类核心 Proxy、订阅、测速、连接统计可用；系统代理实际生效；退出/崩溃后无死代理 |
| M2 | 三类核心 TUN、TCP/UDP/DNS、链式与手工配置；现有 utun、端口占用、IPv6及缺少上游；路由/DNS验证和异常恢复 |
| M3 | Safari/Chromium/Electron/命令行分流；热键冲突；窗口/Dock/菜单栏；登录标记和系统禁用后台项；冷/热/重复深链接 |
| M4 | 双架构 DMG、升级授权/取消、安装失败回滚、卸载；现有 PAC/DNS/搜索域与用户中途修改；完整回归通过 |

网络场景还须覆盖 Wi-Fi/有线切换、睡眠唤醒、断网重连、IPv4/双栈、GUI/核心/helper 崩溃、连续快速连接断开和另一个全局 VPN 的冲突。macOS 12 Intel 与 Apple Silicon 是必测项；macOS 13、15、当前稳定版本补充覆盖。

2026-09-10 已实际完成 Flutter 分析及全部 1235 项测试，核心双架构编译、Darwin DNS/路由补丁回归、Swift 服务双架构编译、桌面与恢复策略检查。完整 Xcode 下的 XCTest 和应用构建通过 GitHub CI 执行；本机 CLT 检查与 CI XCTest 分开记录。

CI 演练已确认：仅修改安装脚本的提交中，两个架构共十个组件均恢复成功，所有编译步骤跳过；真实下载组件修改一字节后被校验拒绝。打包检查同时发现了 Flutter 原生资产默认最低 macOS 13 的问题，因此编译成功和符合 macOS 12 部署目标不是同一验收项，必须保留最终 Mach-O 检查。

本机为 macOS 15.6、Apple Silicon。根据使用者要求，现有 VPN 保持连接，TUN 运行验收由使用者人工完成；自动验收聚焦安装、桌面和 Proxy。网络原始快照保存在本机私有目录，不能提交订阅凭据或本机网络详情。Intel 运行、macOS 12 两架构、AWG 节点及尚未执行的完整发布矩阵继续标为待验证。
