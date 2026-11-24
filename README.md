# MyIPhoneApp

这是一个原生 SwiftUI 计数器，支持 iOS 16.0 及以上的 iPhone。Windows 上用 VS Code 编辑源代码，GitHub Actions 的标准 macOS Runner 使用 Xcode 编译，Windows 上再用 Sideloadly 签名并安装到自己的 iPhone。

- 项目、Target、Scheme：`MyIPhoneApp`
- 构建用 Bundle ID：`com.example.myiphoneapp`
- 版本：`1.0.0`。CI 用 Actions 的运行编号作为 Build 编号。
- 日志保存最近 100 条应用事件，关闭进程后清空。点「复制日志」可复制带时间戳、级别和版本号的文本。

## 1. 首次提交并触发构建

在当前项目目录打开 VS Code 的 PowerShell 终端。Git 可用后，如果 `gh` 尚未安装，运行以下命令，然后重新打开终端。

```powershell
winget install --id GitHub.cli --exact --source winget
```

在浏览器完成 GitHub 授权。确认公开提交使用你愿意公开的 Git 邮箱，或者使用 [GitHub 提供的 noreply 邮箱](https://docs.github.com/en/account-and-profile/how-tos/email-preferences/setting-your-commit-email-address)。密码、验证码和令牌留在相应的官方登录界面。

```powershell
gh auth login --hostname github.com --git-protocol https --web
gh auth status
git status --short --branch
git remote -v
git config --get user.email
```

下面的首次发布命令适用于当前这个尚无提交、也没有 `origin` 的仓库。逐条执行，有错误就先处理。GitHub 账户下如果已有同名项目，选另一个仓库名，或在确认远程仓库为空后连接它。

```powershell
if ((git branch --show-current) -ne 'main') { git branch -m main }
git add -- .gitignore .github/workflows/build-ios.yml App/MyApp.swift App/ContentView.swift App/Services/AppLogger.swift project.yml README.md
git diff --cached --stat
git commit -m "Create SwiftUI iPhone app and build workflow"
gh repo create MyIPhoneApp --public --source . --remote origin --push
```

如果已经在 GitHub 网页创建了空仓库，用下面的两行替换 `gh repo create`。先将 `YOUR_GITHUB_USERNAME` 替换成实际用户名。如果已有 `origin`，先检查它的地址和内容。

```powershell
git remote add origin https://github.com/YOUR_GITHUB_USERNAME/MyIPhoneApp.git
git push -u origin main
```

推送 `main` 会自动触发构建。查看最新运行并在需要时用运行编号查询细节。

```powershell
gh run list --workflow build-ios.yml --branch main --limit 5
$runId = Read-Host '输入上一步显示的运行 ID'
gh run watch $runId --exit-status
```

要手动重跑当前 `main` 上的代码，可以执行 `gh workflow run build-ios.yml --ref main`。工作流会生成 Xcode 工程，构建 Release 真机 App，校验 `iPhoneOS`、`arm64` 与 Bundle ID，并检查 IPA 内的 `Payload/MyIPhoneApp.app/`。产物保留 14 天。标准托管 Runner 在公共仓库可免费使用，参见 [GitHub Runner 文档](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)。

## 2. 下载未签名 IPA

在 GitHub 打开仓库 → **Actions** → **Build iPhone IPA** → 成功的运行 → **Artifacts**。下载 `MyIPhoneApp-unsigned` 并解压，得到 `MyIPhoneApp-unsigned.ipa`。也可以用 PowerShell 下载到 `downloads`。

```powershell
gh run download $runId --name MyIPhoneApp-unsigned --dir downloads
Get-Item .\downloads\MyIPhoneApp-unsigned.ipa
```

## 3. 在 Windows 签名并安装

1. 从 [Sideloadly 官网](https://sideloadly.io/) 下载 Windows 版，按官网说明安装它要求的 Apple 连接组件。官网提供适用的 iTunes 和 iCloud 网页版链接。
2. 用 USB 数据线连接并解锁 iPhone。手机提示「信任此电脑」时点「信任」，按提示输入手机锁屏密码。打开 Sideloadly，确认设备下拉列表显示你的 iPhone。
3. 在 Sideloadly 选择 `MyIPhoneApp-unsigned.ipa`，选中你的 iPhone，用个人 Apple 账号点击 **Start**。在 Sideloadly 或系统验证界面完成登录和双重认证。Apple 账号凭据不需要交给 GitHub Actions，也不需要发到聊天中。
4. 出现开发者模式提示时，在 iPhone 打开「设置 → 隐私与安全性 → 开发者模式」，打开开关。按提示重启并再次确认。
5. 如提示不受信任的开发者，在「设置 → 通用 → VPN 与设备管理」中选对应开发者并按提示信任。
6. 回主屏幕打开 App。看见计数器后按下面的清单验收。

免费 Apple 账号的开发配置文件通常有效 7 天，到期需要重新签名或刷新。免费账号还受 App 数量、App ID 和可用权限限制。更新时使用同一 Apple 账号及同一有效 Bundle ID，正常覆盖安装通常可保留 App 数据，但不能保证。保存重要数据时先备份，保留旧 App 直到确认覆盖安装结果。这个示例的计数和日志仅保存在内存中。参见 [Apple 免费开发账号说明](https://developer.apple.com/help/account/basics/about-your-developer-account/) 和 [Sideloadly FAQ](https://sideloadly.io/faq)。

## 4. 真机验收

- [ ] iPhone 主屏幕出现 App 图标，App 能打开。
- [ ] 初次打开显示 0，连续按两次「点击 +1」后显示 2，点「重置」后回到 0。
- [ ] 能看到应用版本和 Build 编号。
- [ ] 调试日志显示应用启动、加一及重置事件。
- [ ] 点「复制日志」后能粘贴到备忘录，能看到日期、时间、级别和事件。
- [ ] 在浅色和深色模式下文字都可读。

Actions 成功只确认编译和打包。Sideloadly 是否能签名、设备是否能安装，以及按钮是否正常，都以实际 iPhone 验收为准。

## 5. 日常开发和排错

首次使用已有仓库时，用 `gh repo clone YOUR_GITHUB_USERNAME/MyIPhoneApp` 克隆，再用 VS Code 打开项目。修改 Swift 文件后提交并推送，等待流水线完成，然后下载新 IPA 并覆盖安装。

```powershell
git status --short
git diff
git add -- App/ContentView.swift
git commit -m "Update counter screen"
git push
gh run list --workflow build-ios.yml --branch main --limit 5
```

如果遇到问题，在 iPhone 复现后复制日志，并记录复现步骤、iOS 版本和 App Build 编号。修复后重新构建、覆盖安装，再执行相关的真机检查。

| 现象 | 如何处理 |
|---|---|
| 没看到 Actions 运行 | 确认已经推送到 `main`，仓库启用了 Actions，且工作流位于仓库根目录的 `.github/workflows/`。 |
| Actions 失败 | 运行 `gh run view $runId --log-failed`，查看最先失败的步骤。XcodeGen、Xcode 版本与打包校验各有独立日志。 |
| Artifact 不见了 | 确认运行成功且未超过 14 天保留期。过期后手动触发新构建。 |
| Sideloadly 看不到手机 | 解锁手机并确认信任提示，换 USB 数据线或接口，按 Sideloadly 官网说明检查 Apple 连接组件。 |
| 签名或安装失败 | 保留 Sideloadly 的错误信息，检查账号验证、免费账号限制、设备 iOS 版本及 IPA 是否下载完整。若错误明确指出 Bundle ID 不可用，检查 Sideloadly 分配的 ID 或为项目选择自己专用的 ID，再重新构建。 |
| 安装后提示开发者模式或信任 | 按第 3 节在手机上处理提示。 |
| 几天后打不开 | 核对签名有效期，使用原 Apple 账号和相同的有效 Bundle ID 重新签名或刷新。 |

公共仓库只存示例源代码和构建配置。提交前检查暂存内容，确保没有账号凭据、签名私钥、真实设备标识或以后接入 BLE 的密钥。
