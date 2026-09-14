# Keqdroid v0.37.0

基于上游 Lemonochka/keqdroid `e13999fe8aceb76e80d2daf20d4aec07c3237c23`（0.37.0+78），显示名称跟随上游改为 **keqdroid**；macOS 安装位置与数据路径保持兼容。本仓库修改按通用功能、macOS 支持、发行配置、CI 与发布四类组织。

## 本次变化

- 同步上游 157 个提交：mihomo 订阅模板与分组、Provider 路由/DNS、协议和端口规则、自定义路由顺序、服务器编辑器、行为设置、Android 小组件与原生修复，以及 Linux TUN 修复。
- 公共界面与提示沿用上游结构；macOS 保留菜单栏速率、快捷键、应用分流、LAN、系统代理、TUN、恢复与取消保护。新协议/端口规则经过同一连接准备流程，分组重置期间取消或切换不能被旧回调重新连接。
- macOS 受限 mihomo API 支持读取分组延迟和取消自动组固定节点，仍禁止重载配置/供应者或任意管理操作。helper 独立拒绝辅助服务器、系统时钟/防火墙修改、Xray reverse 与 webhook 能力。
- 新安装继续采用中国路由和分离 DNS 默认值；升级与旧备份保留用户设置。Geo 精简数据保留所有新版上游分类并补入 `cn`。
- 更新与 Geo 验证本仓库的 Ed25519 `SHA256SUMS.sig` 和精确文件名 SHA-256；保留 APK 差分下载、各平台资产识别，以及 macOS 严格架构/PKG 匹配和网络恢复后退出更新。
- 继续分组件构建和目标提交产物复用；增加上游 Android JVM/Robolectric 测试。发布签名及上传单独执行，失败重试不重新编译。

## 安装与迁移

- **macOS**：选择 `keqdroid-0.37.0-macos-arm64.pkg` 或 `keqdroid-0.37.0-macos-x64.pkg`。断开并退出旧版后，在系统界面完成管理员授权。内部组件使用 ad-hoc 签名，未经 Apple 公证。卸载包名称包含 `-uninstall`，默认保留用户配置。仅识别 DMG 的旧客户端需要手动安装一次 PKG。
- **Android**：应用 ID 为 `io.github.caocaocc.keqdroid`，使用本仓库持久签名，与上游版本并存。首次通过原应用导出备份并在此版本导入迁移。arm64 使用主 APK；32 位 Android 固件使用 `armeabi-v7a` APK。
- **Windows / Linux**：选择对应 ZIP、AppImage、DEB、RPM 或 TAR 包；本仓库不向 AUR 发布。
- 应用及 Geo 更新来自 `caocaocc/keqdroid`。下载后使用 `SHA256SUMS` 与 `SHA256SUMS.sig` 校验；保留 `geoip.dat.sha256` 兼容旧数据下载器。

## 验证范围

发布须通过目标提交的完整分析、Flutter 回归、Windows/macOS Socket/TLS、原生权限与配置校验、安装包验证和本机验收。macOS 仍固定 Flutter 3.44.4、Go 1.26.8、Xcode 16.4 与 CocoaPods 1.16.2。

本机验收环境为 Apple Silicon、macOS 15.6。Intel、macOS 12、Windows/Android/Linux 真机、跨设备 LAN、真实睡眠与缺少对应节点的场景须单独记录；构建通过不代表这些组合已经验收。macOS 不提供系统级 Kill Switch，也不保证与另一全局 VPN 同时工作。

上游项目：https://github.com/Lemonochka/keqdroid
本仓库更新与问题反馈：https://github.com/caocaocc/keqdroid
