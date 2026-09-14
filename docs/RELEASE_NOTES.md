# Keqdroid v0.21.1

基于上游 Lemonochka/keqdroid `be01e02683ce9c3c61a86f6162c7878d82bbeab5`（0.21.1+52），保留产品名 **KEQDIS**。本仓库修改整理为通用功能、macOS 支持、发行配置、CI 与发布四类。

## 本次变化

- 同步 Android 单核心批量测速和桌面最多 16 路逐节点测速；macOS 保留既有 GET 诊断及物理 DNS 接线。整批核心启动失败时沿用拆分回退，不把其他可用节点一并判为失败。
- 同步 mihomo Firefox 148 ClientHello 修复，macOS 使用同一上游补丁；核心依赖和固定 Go 版本不变。
- 同步服务器列表滚动隐藏添加按钮、粘贴内容说明，以及 Linux 无 polkit 时的明确提示、已有 root 权限下直接启动和缩小后的核心文件。Linux 提权执行使用已解析的 pkexec 路径。
- 同步上游手机双列卡片、横屏导航栏与双栏服务器页，保留桌面侧栏和 GET 测速诊断。
- 同步 Windows 关机/注销时系统代理清理、mihomo 的 Mips TUN 栈选项及 REALITY 的 X25519MLKEM768 参数；keqrnel 对 Mips 继续使用其支持的默认栈。
- 核心更新为 mihomo 1.19.31、Xray 26.9.9、sing-box 1.14.1 与 sing-tun 0.9.3。macOS 保留固定 Go 1.26.8，通过独立补丁与协议回归适配新版依赖。
- 同步 Windows/Linux 的设置恢复与启动诊断、Android 后台权限入口，以及 mihomo TUN 下临时测速核心的直连规则。Linux 设置恢复在单实例检查成功后执行，避免第二次启动覆盖正在写入的设置。
- 新安装采用中国流量直连、其余流量代理，复用现有多行 DNS 与分离开关。升级保留已有设置。
- 修复桌面 GET 延迟探测的响应解析、超时清理与复用失败处理，显示具体失败阶段；改进国旗识别。
- macOS 提供 Proxy/TUN、系统代理与网络恢复、LAN 共享、应用分流、快捷键、登录启动、深链接和菜单栏实时速率。
- 应用及 Geo 下载使用 caocaocc/keqdroid；所有发布文件由本仓库 CI 构建或按锁定输入验证复用。

## 安装与迁移

- **macOS**：按处理器下载 `keqdroid-0.21.1-macos-arm64.pkg` 或 `keqdroid-0.21.1-macos-x64.pkg`。安装前断开并退出 KEQDIS，在系统界面完成管理员授权。内部应用和组件使用 ad-hoc 签名，安装包未经 Apple 公证。旧版仅识别 DMG 的更新器需要手动安装本次 PKG，此后使用 PKG 更新。卸载包名称包含 `-uninstall`，默认保留用户配置。
- **Android**：独立应用 ID 为 `io.github.caocaocc.keqdroid`，使用本仓库持久发布签名，可与上游版本并存。请先在原版本导出备份，再导入此版本；它不会覆盖上游应用或自动迁移其私有数据。
- **Windows / Linux**：选择对应 ZIP、AppImage、DEB、RPM 或 TAR 包；本仓库不向 AUR 发布。
- 下载后使用 `SHA256SUMS` 校验文件。`geoip.dat.sha256` 继续提供给现有数据下载器。

## 验证与支持边界

发布流程要求完整 Flutter 分析与回归、Windows/macOS Socket/TLS 测试、macOS 原生与安装包检查以及全平台产物校验通过。构建报告记录目标提交、架构、源版本、签名或校验结果及组件复用来源；具体本机验收结果随交付报告提供。

当前本机验收环境为 Apple Silicon、macOS 15.6。Intel、macOS 12、Windows/Android/Linux 真机、跨设备 LAN 与缺少对应节点的场景仍需额外验证；CI 构建通过不代表这些真机组合已经验收。macOS 不提供系统级 Kill Switch，也不保证与另一全局 VPN 同时工作。

上游项目：https://github.com/Lemonochka/keqdroid
本仓库更新与问题反馈：https://github.com/caocaocc/keqdroid
