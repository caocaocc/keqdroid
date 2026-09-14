# dev 上游同步记录

## 2026-09-19：同步 0.21.1

固定上游 `36d8b1655b550feebe65044b8ad54df93b6be9bc`（`0.21.1+52`），相对旧基线 `2e7e8871acb0d68a35059e6ec2d7d645346d9031` 新增 10 个提交。旧 dev `541f95f88c80ae93c4159cfca76ac15c64f49d95` 已保存到本地和 origin 的 `codex/dev-backup-541f95f`；从明确的旧基线重放四类提交，不创建合并提交。后续修正仍折叠回对应分类。

| 分类 | 旧提交 | 新提交 | 本次范围 |
| --- | --- | --- | --- |
| 1 通用功能 | `91f7d881b86befd57b112771b4e1e7a95a3f38b9` | `d2b96070f33684f5204bd097ab3285047297818c` | 中国默认值、DNS、GET、国旗；在上游共用 ping 组件接回卡片和列表诊断 |
| 2 macOS 支持 | `28d4786d158d78db1e290516ac228d70f1142701` | `8f83080115efe4122a7d50e7b4e3384d350242b0` | macOS 桌面/网络功能、按新来源核验的核心补丁与回归 |
| 3 发行配置 | `aa3211e40080fd3de9619351b9df3a57c32856c4` | `db266fce650c0ff86849d10bb3c3ba8b98c90bd5` | 本仓库更新、Android 身份/签名、PKG 安装与更新 |
| 4 CI 与发布 | `541f95f88c80ae93c4159cfca76ac15c64f49d95` | 本记录所在最终提交 | 分组件复用、全平台产物校验及发行记录 |

新四类完整 SHA 记录在目标构建和交付报告中；本记录不嵌入自身提交哈希。

本地完整 Flutter 测试 1961 项通过、3 项按平台跳过，静态分析无问题；Python 回归 177 项、2 项跳过。两核心通过 arm64 编译、12 份生产生成配置的解析/构造，以及 DNS、路由清理、权限边界、TLS/REALITY 回环测试。两个 helper 输入指纹与上一成功构建相同；CI 和安装验收仍绑定本次最终提交。

- 保留手机双列 Material 卡片、横屏导航栏和双栏服务器布局。GET 的计时类型、失败阶段和 tooltip 接在上游共用 ping 组件上，卡片与列表保持一致；macOS 继续使用已有桌面主页。
- 保留 `PlatformBootstrap.debugIsDesktopOverride`，正常运行仍使用现有桌面能力描述。Mihomo 可选 Mips，keqrnel/sing-box 按上游回退到默认栈；不删除用户保存的 Mips 选择，也不在 macOS 配置中重新引入固定 TUN 名称或不支持的 strict_route。
- VLESS、Trojan 和 XHTTP download 的 REALITY 均保留上游 X25519MLKEM768 参数；已有用户指纹、物理 DNS 与出口绑定继续保留。作者完整配置仍遵循现有优先规则。
- Windows 的关机/注销代理清理保留上游实现。Linux 主实例之后才执行设置恢复的修复继续保留。Android 的独立应用 ID 与持久签名不变。
- 核心依赖跟随上游二进制的明确版本，Darwin 构建继续固定 Go 1.26.8；Xray 的 Go 声明兼容及各依赖 API 适配保留为可追踪的最小构建补丁。新版已有的资源清理逻辑保留，物理 DNS、防环、受限 API 和路由所有权补丁按新源码重新核验。
- 发行版本与标签跟随上游为 `0.21.1+52` / `v0.21.1`。不使用旧版本的构建或安装验收代替本次结果；正式发布仍需目标提交完整 CI 与安装验收通过。

## 2026-09-14：同步测速与启动恢复更新

固定上游 `2e7e8871acb0d68a35059e6ec2d7d645346d9031`，版本仍为 `0.20.1+49`。相对上一基线 `10de499ceabfeb729d447947337e6f4eec23b3bb` 新增 6 个提交。旧 dev `b0527524f3ebb52ceebf535e9a027392bb50e482` 的全平台 CI 已通过，已保存至本地和 origin 的 `codex/dev-backup-b052752`。从明确的旧上游边界重放四类提交，不创建合并提交。

| 分类 | 重放后的提交 | 原提交 |
| --- | --- | --- |
| 1 通用功能 | `91f7d881b86befd57b112771b4e1e7a95a3f38b9` | `0e84b13f35cbaf6f029cb53b9182d5e5a7f14ee7` |
| 2 macOS 支持 | `28d4786d158d78db1e290516ac228d70f1142701` | `f4d7448d40842421384fabea89c2327e63cf32a0` |
| 3 发行配置 | `aa3211e40080fd3de9619351b9df3a57c32856c4` | `a6dc421bb595c958589077dbfff24c3d1a8d0394` |
| 4 CI 与发布 | 本记录所在最终提交，完整 SHA 见构建报告 | `b0527524f3ebb52ceebf535e9a027392bb50e482` |

- mihomo 保留上游四条临时核心进程直连规则，在 macOS 精确应用路径豁免之后、用户分流之前。物理 DNS/接口绑定继续保留，进程名规则不替代 DNS 防环。macOS mihomo/AWG TUN 的两份 golden 各仅新增这四条规则，Windows/Linux 其他既有 golden 不变。
- 启动入口沿用上游组织和格式，接回 macOS 初始化及桌面首页。Windows/Linux 设置恢复、启动日志/首帧诊断以及 Android 后台权限与磁贴改动保持上游实现；macOS 仍使用系统 UserDefaults，不套用 JSON 文件修复。
- 同步验证实际复现了 Linux 次实例在主进程截断写入期间恢复设置导致旧数据覆盖的问题。只把 Linux 恢复调用移到确认主实例之后，保留上游恢复算法。新增真实 main 入口回归，使用独立临时路径和受控单实例 socket，Linux CI 执行；macOS 不用目标平台伪装替代 Linux 验收。
- Android 新权限申请和磁贴打开应用继续使用运行时 packageName，与独立应用 ID、动态 Provider authority 和持久签名兼容。后台授权及快速停止等系统场景仍需 Android 设备验证。

首轮 CI `34861454526` 的功能回归与 macOS/Android 包通过；Windows 遇到 Flutter 版本机器输出解析失败，Linux 中间缓存缺少 native_assets 安装目录。分类 4 补充版本原始输出留证及唯一版本 JSON 校验；仅使缺失原生资源输出的 Flutter 安装目标重新执行，并将 native_assets 与编译缓存一同保存、校验。保留 C++/AOT 缓存，未跳过缺失文件检查。

核心及 helper 输入未变，可复用上一轮成功组件；应用及绑定新提交的安装包重新构建。尚未创建正式发行标签，后续安装验收及发布绑定本次最终 dev，不使用旧包冒充新上游产物。

## 2026-09-14：同步 0.20.1 并折叠 LAN 就绪检查修复

固定上游为 `Lemonochka/keqdroid` 的 `10de499ceabfeb729d447947337e6f4eec23b3bb`（0.20.1+49），在上一基线之后新增 6 个提交。原 dev `d795d8cb0a9e1f32fd56aec55c47322bbe2307ec` 已备份至本地和 origin 的 `codex/dev-backup-d795d8c`。用明确的旧上游边界 `b85d0bf47d2d977544c472d444d9c0a149f110f9` 重放四类提交，没有合并提交。

- 分类 1：`0e84b13f35cbaf6f029cb53b9182d5e5a7f14ee7`，对应原 `25c228a8d16cd88f99c79318c7c4703142fb8f03`。
- 分类 2：`f4d7448d40842421384fabea89c2327e63cf32a0`，对应原 `5b253e9dba006e43ded541bc59c52f285191875b`，包含 LAN 双栈监听修复及其真实 socket 检查。
- 分类 3：`a6dc421bb595c958589077dbfff24c3d1a8d0394`，对应原 `421c76278c895daa1fbea0f91352bcc8f6d1e414`，同时修正遗留的 DMG 安装提示。
- 分类 4：此记录所在的最终提交，对应原 `d795d8cb0a9e1f32fd56aec55c47322bbe2307ec`；完整 SHA 由目标构建和验收报告记录。

保留上游新的设置文案、Windows 图标行、客户端身份预设、加载动画相位以及编辑器测试后端。文案冲突只接回本仓库 DNS 的真实行为说明；macOS 登录设置继续使用同样的图标行，不显示 Windows 专属管理员登录选项。上游已包含等效的编辑器测试隔离，本仓库不再保留重复差异。

本机 mihomo LAN 测试发现其 IPv4 通配监听由内核表示为支持 IPv4 的双栈 `::`。原生就绪检查现在接受此表示，继续拒绝 IPv6-only、loopback、错误 PID 和错误端口；未扩大入站配置、认证或系统权限。该修复折叠入分类 2。

发行版本与标签跟随上游为 `0.20.1+49` / `v0.20.1`。四个 macOS 核心组件输入不变，可以校验后复用；应用、helper 和安装包按实际变化重新构建。旧 0.20.0 产物及验收只作为历史证据，不替代新提交的构建与安装验收。

## 2026-09-13：四类提交整理

本次固定上游 `Lemonochka/keqdroid` 为 `b85d0bf47d2d977544c472d444d9c0a149f110f9`（0.20.0+48）。旧 dev 为 `3d37e1bf16ca42f4ab01827604e18ea8eeaab347`，本地及 origin 备份为 `codex/dev-backup-3d37e1b`。

最终历史只保留上游之后四个分类提交。对应测试、翻译、说明随实现归类，后续修正折叠进所属分类；旧提交跨多项功能时按最终差异分别归入各类，不保留其临时修复过程。

| 分类 | 提交标题 | 主要旧提交来源 |
| --- | --- | --- |
| 1 | Improve shared DNS defaults, desktop probes and country detection | 3fc6bb6、fdf3375（GET）、3d37e1b（国旗） |
| 2 | Add complete macOS desktop and network support | 66c298d（原生和桌面）、d302783、855bedc、c81577d、9df3c77、4bf1b5d、443ae71、31784bc、18194fd、91c1e50、eba19a0、d04d15b、0330983、67f7bc1、fdf3375（恢复/LAN）、824aab2、0db576b、3d37e1b（布局） |
| 3 | Configure fork releases, Android signing and macOS PKG updates | 66c298d（安装/更新）、f09235a（安装核验）及本次独立发行修改 |
| 4 | Build reusable cross-platform artifacts and publish verified releases | 66c298d（CI）、d302783/855bedc/f09235a（续跑验证）及本次全平台发布修改 |

本次前三个分类提交：

- 分类 1: `25c228a8d16cd88f99c79318c7c4703142fb8f03`。
- 分类 2: `5b253e9dba006e43ded541bc59c52f285191875b`。
- 分类 3: `421c76278c895daa1fbea0f91352bcc8f6d1e414`。
- 分类 4 为发布标签指向的末提交；其完整 SHA 与最终四类映射由构建及验收报告记录，避免在提交正文中嵌入自身哈希。

合并设置冲突时保留上游按核心显示参数、Windows 管理员登录启动、服务器编辑器和无国旗图标配色。macOS 登录项仍走自身平台服务；DNS 分离因本仓库已实现 mihomo 接线继续显示；macOS 的 IPv6 保护选项适用于两个核心。

macOS 保留 utun 自动分配、按进程路径分流、物理 DNS/出口上下文、系统设置所有权恢复与 XPC 校验。AWG 沿用上游 mihomo，旧 wireproxy 仅用于历史恢复记录清理。发布改为直接 PKG，旧 DMG-only 更新器需手动升级一次。

组件由相关源码、依赖锁、工具链、架构、构建参数及 Android 签名证书指纹决定复用，不以整提交 SHA 作编译缓存键。发布产物另行绑定最终提交；发布器仅收集对应 SHA 的可信 dev 构建并校验完整资产清单。

此次重组以显式旧 dev SHA 作为远端租约，无合并提交，无需先删除远端 dev。正式标签仅在全部构建、校验及本机验收完成后指向最终分类提交。

## 2026-09-12

本次固定上游 `Lemonochka/keqdroid` 的 master 为 `2a3a3aabdbc1bff2494b8044f8c9cbc6f399fd2b`，将原有 11 个提交按原顺序重放到其后，没有创建合并提交。

- 原 dev：`5f963d851b4dc4bfdfb1a23d623dc10c8c6d79bc`。
- 明确重放边界：`b1a1dee75fdac70eb7ef8deadbcca612b2704777`；不使用重写后的共同祖先推断范围。
- 本地及 origin 备份：`codex/dev-backup-5f963d8`。
- 上游重写后的同版基线为 `57bd07c784036805992e1d4e4bb6e66f85264dd7`；除移除 CLAUDE.md 外，文件内容和模式与旧基线一致。
- 此后 37 个上游提交先于本仓库的 macOS 提交。

| 原提交 | 重放后提交 |
| --- | --- |
| c6b8ee6fba227bf52fc4a9cd9c9d639a56f06ee1 | 66c298dcbf9123af41b7451275b0954f952aed8c |
| 2966e6f1ac692d4abb6924777abaa156fcea830b | d302783d1f1f4d0822dc42c5ea8cc2fe7b36951c |
| afc093d1e7de6fe902bfd0e40dc4e59f4ed18d42 | f09235a2af5978df78b2250a58fcc85c1755cca9 |
| ba12299ae27e754ae089938212207e168e0d2096 | 855bedc3d5fc106e3dcd1f65d913b2e7609dd5b7 |
| eea32dc9cb4dfd2ae0f2b94fe4cb03d02ea74faa | c81577de557f2f0d19e8bc1097d194c00307f185 |
| 3a2e5e22add24ebcf8e51be9439bff0072329e47 | 9df3c779b815ce9056415e007f738edba180abc4 |
| 51cadc0f093600553fa234baa88a918a94f298ab | 4bf1b5dfa43f067654e970ce49a7d7b5312c6b5b |
| 8de8edb5917e038fc30bc992adc092219584dbec | 443ae71813a1de6f89fbb43e5a9f2dfb80283c75 |
| b11694b3da29d84b92a25e89a6b3bda7c37783f8 | 31784bc2707fb0a7d2c7b19fb691af6c8e773265 |
| c30de599d5e18ec35493ceda3ae14a3c5bc87ceb | 18194fd47a1e78573631f77c84e6645bae40162b |
| 5f963d851b4dc4bfdfb1a23d623dc10c8c6d79bc | 91c1e505540607c2cc09862f6e7d3c33e21e36b8 |

冲突处理保留上游当前公共实现，再接回 macOS 分支。后续独立提交收敛以下差异：

- AWG 使用上游 mihomo 转换和运行路径，删除 macOS 新会话的 wireproxy 构建、启动、统计及打包接口；旧恢复记录仍能停止旧核心并恢复网络。
- 保留自动 utun、进程路径规则、物理网络快照、设置所有权恢复和 XPC 权限校验。
- DNS 网络探测移到连接后，每会话一次，失败形成诊断警告。进程、端口、TUN、路由、IPv6 保护和系统设置仍是连接成功的必要条件。
- 使用上游统一 SHA256SUMS 形式，并保留 DMG sidecar；下载校验只接受目标文件名的唯一哈希。
- 中国新默认使用现有规则和多行 DNS 字段；已有 JSON/备份缺字段继续使用旧反序列化默认。

核心锁定版本及工具链不变。5 份缓存源码压缩包均与清单 SHA 匹配，10 个保留补丁按实际构建顺序可应用；锁定源码仍存在对应旧行为，未发现可由这些固定版本替代的补丁。逐项理由与已覆盖检查见 [补丁说明](../tool/patches/macos/README.md)。此结论不代表未纳入构建的新核心 HEAD。

## 后续同步

1. 固定待同步上游及旧远端 dev 的完整 SHA，创建本地和远端备份。
2. 明确上一次上游边界，仅重放其后的本仓库提交：`git rebase --onto <新上游> <旧上游边界> dev`。
3. 审核冲突和提交对应关系，验证新上游是 dev 的祖先且自有区间没有合并提交。
4. 运行分析、完整测试及配置/原生契约校验。
5. 使用 `git push --force-with-lease=refs/heads/dev:<此前核实的远端SHA> origin dev:dev`。租约失效时先核对远端新增内容。

组件缓存继续由实际输入决定，不使用 dev 提交 SHA 代替输入指纹。开发安装包仍需分别记录 CI、安装、真实流量和异常恢复结果；Intel 与 macOS 12 的设备验收不可由本机或新系统 runner 替代。
