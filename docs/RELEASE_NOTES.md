# Keqdroid v0.20.1

基于上游 Lemonochka/keqdroid `2e7e8871acb0d68a35059e6ec2d7d645346d9031`（0.20.1+49），保留产品名 **KEQDIS**。本仓库修改整理为通用功能、macOS 支持、发行配置、CI 与发布四类。

## 本次变化

- 保留上游新版设置文案与图标行、客户端身份预设、滚动列表加载动画，以及服务器编辑器和图标配色。
- 同步 Windows/Linux 的设置恢复与启动诊断、Android 后台权限入口，以及 mihomo TUN 下临时测速核心的直连规则。Linux 设置恢复在单实例检查成功后执行，避免第二次启动覆盖正在写入的设置。
- 新安装采用中国流量直连、其余流量代理，复用现有多行 DNS 与分离开关。升级保留已有设置。
- 修复桌面 GET 延迟探测的响应解析、超时清理与复用失败处理，显示具体失败阶段；改进国旗识别。
- macOS 提供 Proxy/TUN、系统代理与网络恢复、LAN 共享、应用分流、快捷键、登录启动、深链接和菜单栏实时速率。
- 应用及 Geo 下载使用 caocaocc/keqdroid；所有发布文件由本仓库 CI 构建或按锁定输入验证复用。

## 安装与迁移

- **macOS**：按处理器下载 `keqdroid-0.20.1-macos-arm64.pkg` 或 `keqdroid-0.20.1-macos-x64.pkg`。安装前断开并退出 KEQDIS，在系统界面完成管理员授权。内部应用和组件使用 ad-hoc 签名，安装包未经 Apple 公证。旧版仅识别 DMG 的更新器需要手动安装本次 PKG，此后使用 PKG 更新。卸载包名称包含 `-uninstall`，默认保留用户配置。
- **Android**：独立应用 ID 为 `io.github.caocaocc.keqdroid`，使用本仓库持久发布签名，可与上游版本并存。请先在原版本导出备份，再导入此版本；它不会覆盖上游应用或自动迁移其私有数据。
- **Windows / Linux**：选择对应 ZIP、AppImage、DEB、RPM 或 TAR 包；本仓库不向 AUR 发布。
- 下载后使用 `SHA256SUMS` 校验文件。`geoip.dat.sha256` 继续提供给现有数据下载器。

## 验证与支持边界

发布流程要求完整 Flutter 分析与回归、Windows/macOS Socket/TLS 测试、macOS 原生与安装包检查以及全平台产物校验通过。构建报告记录目标提交、架构、源版本、签名或校验结果及组件复用来源；具体本机验收结果随交付报告提供。

当前本机验收环境为 Apple Silicon、macOS 15.6。Intel、macOS 12、Windows/Android/Linux 真机、跨设备 LAN 与缺少对应节点的场景仍需额外验证；CI 构建通过不代表这些真机组合已经验收。macOS 不提供系统级 Kill Switch，也不保证与另一全局 VPN 同时工作。

上游项目：https://github.com/Lemonochka/keqdroid
本仓库更新与问题反馈：https://github.com/caocaocc/keqdroid
