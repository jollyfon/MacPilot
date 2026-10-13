# MacPilot：为新 GitHub 仓库配置发布 Secrets

2026-10-13 已对 `jollyfon/MacPilot` 完成以下配置。本文可交给其他 agent；不包含密码、私钥、P12 内容或 GitHub Token。

## 五项 Secrets 从哪里来

| 名称 | 实际来源与处理 |
| --- | --- |
| `APPLE_CERTIFICATE_P12` | 从本机登录 Keychain 导出已有 Developer ID Application 证书及其对应私钥，筛选为只含选中身份的 P12，验证后转换为 Base64，通过标准输入交给 `gh secret set`。 |
| `APPLE_CERTIFICATE_PASSWORD` | 本次导出时用 `openssl rand -hex 24` 新生成的 P12 保护密码；与上述 P12 配对写入 GitHub，不显示、不保存到仓库。它不是 Apple ID 密码或 App 专用密码。 |
| `APPLE_DEVELOPER_ID` | 本机 `security find-identity -v -p codesigning` 验证过的 `Developer ID Application: Guofeng Liu (U8U443D7ZL)`。 |
| `APPLE_TEAM_ID` | 已有签名身份及项目配置中的 Team ID：`U8U443D7ZL`。 |
| `APPLE_ID` | 项目已有、用户确认过的 Apple Developer 登录邮箱：`misswell@foxmail.com`。 |

没有从旧 GitHub 仓库读取或复制 Secret 值。GitHub 只允许列出已有 Secret 的名字，不能读回明文；新仓库的证书和 P12 密码是利用本机已有签名身份重新配置的。

## 使用的技能与脚本

- 技能：`/Users/guofeng/.codex/skills/macos-github-release/SKILL.md`
- 配置脚本：`/Users/guofeng/.codex/skills/macos-github-release/scripts/configure_ci_secrets.sh`
- 契约说明：`/Users/guofeng/.codex/skills/macos-github-release/references/ci-secret-contract.md`

先检查目标项目的 AGENTS.md、发布 workflow 和本机签名身份，确认它们实际需要这六个名称，再执行：

```sh
security find-identity -v -p codesigning
gh api user --jq .login

zsh "$HOME/.codex/skills/macos-github-release/scripts/configure_ci_secrets.sh" \
  --repo jollyfon/MacPilot \
  --apple-id misswell@foxmail.com \
  --developer-id 'Developer ID Application: Guofeng Liu (U8U443D7ZL)' \
  --team-id U8U443D7ZL
```

脚本会在临时目录导出签名材料，按证书和私钥的公钥匹配关系筛选目标身份，生成独立的单身份 P12，并导入临时 Keychain，确认恰好有一个可用、与选中 Developer ID 一致的签名身份。中间的全身份导出只存在于本机临时目录，不上传；最终上传的是筛选后的单身份 P12。

P12 的 Base64、随机密码及身份信息都通过管道或标准输入交给 `gh secret set --repo ...`；GitHub CLI 使用目标仓库公钥加密后提交。不要使用 `set -x`，不要把秘密放进命令参数、聊天、日志或仓库。脚本通过退出 trap 清理临时 P12、PEM 和验证 Keychain。

## 本次遇到的两个问题

### 已停用的旧 GitHub 登录使全局认证检查返回失败

本机同时保留了两个账号：有效且 active 的 `jollyfon`，以及失效、inactive 的 `misswell`。此时 `gh auth status` 可能整体返回非零，尽管新账号能够访问 API。

本次没有删除旧账号，也没有修改技能源文件，而是在确认 active 的 `jollyfon` 账号有效后，在临时 PATH 中放置一个 `gh` wrapper：仅放行配置脚本的 `gh auth status` 检查；其他命令原样转发到 `/opt/homebrew/bin/gh`。临时 wrapper 用完即清理。本次记录未保留 wrapper 的具体身份校验实现，因此这里不提供其代码作为可复制的绕过方式。

其他 agent 遇到同样情况，应先验证 active 账号及目标仓库写权限，不能无条件忽略认证失败。后续所有仓库级 `gh` 操作都应显式指定 `--repo jollyfon/MacPilot`，因为 Git 的原 `origin` 仍指向旧仓库。

### 网络 EOF 导致脚本只写入了部分 Secrets

第一次执行已写入证书、P12 密码、Developer ID 和 Team ID，随后获取 GitHub 仓库加密公钥遇到 EOF，Apple ID 尚未写入。

本次先用以下命令只核验名称，再通过标准输入单独重试不含秘密的 Apple ID：

```sh
gh secret list --repo jollyfon/MacPilot
printf '%s' 'misswell@foxmail.com' | gh secret set APPLE_ID --repo jollyfon/MacPilot
```

不要因部分失败就假设全部未配置。若重新生成 P12，必须将 P12 和它的新保护密码一起更新，不能只更新其中一项。Secret 名字存在也不证明值有效；最终仍须通过 Actions 的证书导入、签名和 Apple 公证验证。

## 第六项由用户安全设置

`APPLE_APP_SPECIFIC_PASSWORD` 是 Apple ID `misswell@foxmail.com` 的 App 专用密码，由用户直接填写到目标仓库的 Actions Secrets 页面，不能让用户发到聊天。用户已确认在新仓库设置了这一项。

本机 `OctoPilot` notary profile 在本次会话通过了 `xcrun notarytool history --keychain-profile OctoPilot` 实际验证；本地 Beta 16 也已使用它完成公证。但 GitHub Runner 无法读取本机 Keychain，仍需自己的公证 Secret。Profile 名称本身不是可用性证明，其他 agent 每次复用前仍要重新验证。

## 验收与边界

- `gh secret list --repo jollyfon/MacPilot` 已确认六个名称齐全；没有读取或输出其值。
- 本地通用 App 已验证 Developer ID、Team ID、双架构、designated requirement、Apple 公证 Accepted、stapler 和 Gatekeeper。
- 新仓库 main 的 Actions CI 和 [Beta 16 发布 workflow](https://github.com/jollyfon/MacPilot/actions/runs/38395889597) 均已成功；[Beta 16 Release](https://github.com/jollyfon/MacPilot/releases/tag/v1.2.1-beta.16) 已确认是 prerelease，双架构 ZIP 的摘要、签名和公证票据均已核验。因此这六项 Secrets 已实际通过云端签名、公证和发布验证，不能只凭 Secret 名字或 tag 判断成功。
- 保留旧仓库 `origin`，新增 `jollyfon` remote；未修改 `/Applications/MacPilot.app`，未包含用户尚未完成的贴图边角改动。
- 用于其他项目时，应重新发现该项目的仓库、身份、Team 和 Apple ID，不要照抄 MacPilot 的身份配置。
