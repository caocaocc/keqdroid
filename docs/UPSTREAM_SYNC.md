# dev 上游同步记录

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
