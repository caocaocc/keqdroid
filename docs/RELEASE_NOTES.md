# Keqdroid v0.31.1

基于上游 Lemonochka/keqdroid `ae2939e4b1afe591168926a44fcbdac718a1fb9b`（0.31.1+67），保留产品名 **KEQDIS**。本仓库修改按通用功能、macOS 支持、发行配置、CI 与发布四类组织。

## 本次变化

- 同步上游新版路由卡片、按应用/站点指定节点、订阅路由配置、在线规则列表，以及 Auto 跨订阅切换和恢复原订阅逻辑。
- 保留上游 DesktopRail、Modern 连接面板、主题和动效、Android 视频卡片及新版服务器编辑界面；macOS 恢复提示继续使用既有状态区域。
- Windows/Linux 使用上游原生 Xray TUN。macOS 保留 keqrnel 和特权网络服务，升级到相同 Xray 源版本、sing-box 1.14.3 与 mihomo 1.19.32，补齐新应用路由的进程路径和桥接信息。
- macOS 继续提供 Proxy/TUN、系统代理、断网恢复、LAN、应用分流、全局快捷键、登录启动、深链接和菜单栏实时速率。取消、切节点和修改路由配置使旧异步准备失效。
- 新安装采用中国流量直连、其余流量代理；升级和旧备份保留原设置。现有 DNS 分离、物理 DNS 防环与 GET 延迟阶段诊断继续保留。
- 更新器保留上游 Android 32 位、Linux DEB/RPM/AppImage/便携安装类型选择，同时严格匹配本仓库 macOS PKG 版本和架构并验证 SHA-256。
- CI 独立构建各平台和架构，立即保存成功组件。校验新增 Shader、Windows 运行库和 Android 必需库；Linux 使用 Ubuntu 22.04 构建并隔离中间缓存。发布只收集目标提交的可信产物，重试上传不重新编译。

## 安装与迁移

- **macOS**：选择 `keqdroid-0.31.1-macos-arm64.pkg` 或 `keqdroid-0.31.1-macos-x64.pkg`。断开并退出旧版后，在系统界面完成管理员授权。内部组件使用 ad-hoc 签名，未经 Apple 公证。卸载包名称包含 `-uninstall`，默认保留用户配置。仅识别 DMG 的旧客户端需要手动安装一次 PKG。
- **Android**：应用 ID 为 `io.github.caocaocc.keqdroid`，使用本仓库持久签名，与上游版本并存。首次通过原应用导出备份并在此版本导入迁移。arm64 使用主 APK；32 位 Android 固件使用 `armeabi-v7a` APK。
- **Windows / Linux**：选择对应 ZIP、AppImage、DEB、RPM 或 TAR 包；本仓库不向 AUR 发布。
- 应用及 Geo 更新来自 `caocaocc/keqdroid`。下载后使用 `SHA256SUMS` 校验；保留 `geoip.dat.sha256` 兼容旧数据下载器。

## 验证范围

发布须通过目标提交的完整分析、Flutter 回归、Windows/macOS Socket/TLS、原生权限与配置校验、安装包验证和本机验收。macOS 仍固定 Flutter 3.44.4、Go 1.26.8、Xcode 16.4 与 CocoaPods 1.16.2。

本机验收环境为 Apple Silicon、macOS 15.6。Intel、macOS 12、Windows/Android/Linux 真机、跨设备 LAN、真实睡眠与缺少对应节点的场景须单独记录；构建通过不代表这些组合已经验收。macOS 不提供系统级 Kill Switch，也不保证与另一全局 VPN 同时工作。

上游项目：https://github.com/Lemonochka/keqdroid
本仓库更新与问题反馈：https://github.com/caocaocc/keqdroid
