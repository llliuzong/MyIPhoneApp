# LongWay

这是一个原生 SwiftUI 通勤、待办和运动工具，支持 iOS 16.0 及以上的 iPhone。Windows 上用 VS Code 编辑源代码，GitHub Actions 的标准 macOS Runner 使用 Xcode 编译，Windows 上再用 Sideloadly 签名并安装到自己的 iPhone。

- 项目、Target、Scheme：`MyIPhoneApp`
- 构建用 Bundle ID：`com.example.myiphoneapp`
- 版本：`1.3.0`。CI 用 Actions 的运行编号作为 Build 编号。
- 「通勤」页有「上班」和「回家」两个按钮。首次点按钮时填写目的地，以后长按对应按钮可以编辑。
- 地点请填写 [高德坐标拾取器](https://lbs.amap.com/tools/picker) 获得的 GCJ-02 经纬度。地点存在手机设置中，不会上传到 GitHub，也不会写入日志。
- 两个按钮分别打开 [高德 iOS 驾车导航](https://lbs.amap.com/api/amap-mobile/guide/ios/navi)，由高德使用手机当前位置作为起点。

## 通勤计时

在「通勤」授权精确定位后，点导航按钮会启动本次定位记录，切到高德后继续。两笔有效定位都离起点至少 100 米时确认出发。进入目的地 150 米内后，低速或停留约 20 秒确认到达。用第一次越过出发距离和第一次进入有效到达范围的定位时间计算用时。误差超过 30 米的定位不参与判断。

普通轨迹点至少间隔 30 秒，出发和到达点单独记录。iOS 决定何时提供新定位。若手机没有给出可靠的定位，App 不补造轨迹点。用于到达判定的坐标会在手机上近似转换为高德坐标。现场准确度需要真机试跑确认。

行程摘要和轨迹一起保存到沙盒的 `Application Support/CommuteTrips/`，每次行程一份 JSON。App 冷启动继续显示上次结果。如果上次已开始计时但没有完成，按最后保存的定位将它标记为中断。调试日志仍按冷启动重置，不包含任何轨迹坐标。

## 待办

在底部切换到「待办」，点右上角加号新增。标题必填，优先级默认为 P1，备注选填。待处理按 P0（红）、P1（黄）、P2（绿）排序。同级中新建的待办在上方。点击项目正文编辑，点击左侧圆圈完成或恢复，向左滑动项目可以删除。

已完成的项目归入灰色分区。待办数据保存在手机沙盒中，调试日志只记录新增、编辑、删除等操作的结果，不写入标题和备注。

## 运动

打开「运动 → 引体向上」，点「开始训练」计时。每组结束后输入次数并点「记一组」，画面会更新总次数和总组数。点「结束并保存」后，本次组数、次数及从开始到结束的总时长会保存到手机，并显示在训练记录中。切换页面或重开 App，可以继续尚未结束的训练。

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
6. 回主屏幕打开 LongWay，按下面的清单验收。

免费 Apple 账号的开发配置文件通常有效 7 天，到期需要重新签名或刷新。免费账号还受 App 数量、App ID 和可用权限限制。更新时使用同一 Apple 账号及同一有效 Bundle ID，正常覆盖安装通常可保留地点设置。参见 [Apple 免费开发账号说明](https://developer.apple.com/help/account/basics/about-your-developer-account/) 和 [Sideloadly FAQ](https://sideloadly.io/faq)。

## 4. 真机验收

- [ ] 初次点「上班」和「回家」能分别设置公司和家。长按已配置的按钮可以修改对应地点。
- [ ] 点「上班」打开高德，确认起点为当前位置、终点为公司。
- [ ] 点「回家」打开高德，确认起点为当前位置、终点为家。
- [ ] 连 USB 导出 `commute.log`，确认有版本、启动、点击及跳转结果，日志没有坐标。
- [ ] 结束 App 进程并重新打开后，地点仍在。再导出日志，确认上一进程的按钮事件已清除。

Actions 确认编译、打包和文件共享配置。签名、跳转及实际 USB 导出以 iPhone 验收为准。

## 5. 日常开发和排错

首次使用已有仓库时，用 `gh repo clone YOUR_GITHUB_USERNAME/MyIPhoneApp` 克隆，再用 VS Code 打开项目。修改 Swift 文件后提交并推送，等待流水线完成，然后下载新 IPA 并覆盖安装。

```powershell
git status --short
git diff
git add -- App/ContentView.swift
git commit -m "Update commute screen"
git push
gh run list --workflow build-ios.yml --branch main --limit 5
```

如果遇到问题，在 iPhone 复现后先导出日志，再重新打开 App。修复后重新构建、覆盖安装，再执行相关的真机检查。

### 通过 USB 取日志

App 每次冷启动会重置 `Documents/commute.log`。当前进程的最近 200 条事件以原子写入方式覆盖文件。从高德切回 App 时会保留当前进程的日志。文件保存时间、版本和场景，例如「点击上班」「系统接受高德导航跳转」或「系统无法打开高德导航」。iOS 接受链接不代表高德成功开始了语音导航，高德内部的日志不在这个文件中。

在 Windows 上连接并解锁 iPhone，首次连接时按提示信任电脑。使用 iTunes 的 Apple Mobile Device Service。采集工具在项目忽略的虚拟环境里，首次安装一次即可。

```powershell
python -m venv .\downloads\device-tools
& .\downloads\device-tools\Scripts\python.exe -m pip install pymobiledevice3==11.63.1
powershell -NoProfile -File .\scripts\Get-CommuteLog.ps1
Get-Content -Encoding UTF8 .\downloads\commute.log
```

如果签名工具修改了 Bundle ID，用脚本的 `-BundleId` 参数传入安装时实际使用的 ID。也可在 [iTunes 的文件共享](https://support.apple.com/guide/itunes/transfer-files-itns32636/windows) 中选择 LongWay，把 `commute.log` 保存到电脑。

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
