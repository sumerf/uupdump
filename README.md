# UUP Auto Build

这个项目会从 [UUP dump](https://uupdump.net/) 自动读取最新构建，下载 UUP dump 生成的转换脚本包，并在 GitHub Actions 的 Windows runner 上构建 ISO。

默认参数：

- 目标：`win11-25h2`
- 架构：`amd64`
- 语言：`zh-cn`
- 版本：由目标预设自动决定，普通版本为 `ALL`，LTSC 目标为 `LTSC`

## 本地测试

```powershell
npm run resolve
```

这一步只会解析最新构建并下载 UUP dump 脚本包到 `uup-work`。真正构建 ISO 会下载大量文件并占用较长时间：

```powershell
npm run build:uup
```

## GitHub Actions

把 `D:\uup` 推到 GitHub 仓库后，打开 Actions 页面，推荐运行对应版本的专用 workflow：

- `Build Windows 11 25H2 ISO`: `amd64`, `arm64`
- `Build Windows 11 26H1 ISO`: `amd64`, `arm64`
- `Build Windows 11 LTSC 2024 ISO`: `amd64`
- `Build Windows 10 22H2 ISO`: `amd64`, `arm64`, `x86`
- `Build Windows 10 LTSC 2021 ISO`: `amd64`

`Build UUP ISO` 是总入口，只用于手动或每月自动构建全部目标；总入口固定使用 `amd64`，避免显示不适用于部分目标的架构选项。

语言下拉目前包含：

- `zh-cn`: 中文简体
- `en-us`: English (United States)
- `zh-tw`: 中文繁体
- `ja-jp`: Japanese
- `ko-kr`: Korean
- `de-de`: German
- `fr-fr`: French
- `es-es`: Spanish
- `ru-ru`: Russian
- `pt-br`: Portuguese (Brazil)

工作流也会在每月第二个周二 18:00 UTC 自动运行一次。构建完成后，ISO、`IMAGE_INFO.txt`、`metadata.json` 和 `SHA256SUMS.txt` 会自动挂到 GitHub Release，同时也会作为 Actions artifact 上传。

保存策略：

- GitHub Release 附件：作为主要下载位置保存；发布同一目标的新 Release 后，旧 Release 会被自动删除。
- Actions artifact：只是每次 workflow run 的临时备份，受 `retention-days: 7` 控制，7 天后自动过期删除。

总入口会构建这些目标：

- `win11-25h2`: Windows 11 25H2
- `win11-26h1`: Windows 11 26H1
- `win11-ltsc-2024`: Windows 11 LTSC 2024
- `win10-22h2`: Windows 10 22H2
- `win10-ltsc-2021`: Windows 10 LTSC 2021

定时运行和总入口会依次尝试构建以上全部目标。GitHub Actions 页面里会显示一个 `build` job，并在里面按步骤显示 `Build win11-25h2`、`Build win11-26h1` 等目标。

Release 的 tag 会自动生成，例如：

```text
uup-win11-25h2-26200.8875-amd64-zh-cn-all
```

重复运行同一个构建时，工作流会更新 Release 并覆盖同名附件。

发布新 Release 后，脚本会自动删除同一目标的旧 Release，只保留最新版本。

`IMAGE_INFO.txt` 会包含镜像标题、构建号、架构、语言、版本、UUP dump UUID、来源、附件大小和 SHA256。

GitHub Release 单个附件有大小限制。ISO 超过限制时，发布脚本会自动拆成：

```text
xxx.iso.part001
xxx.iso.part002
...
```

下载后按顺序合并即可还原 ISO。

## 手动选择版本

目标预设会自动选择 edition：

- 普通目标：`ALL`，构建该语言下全部可用版本
- LTSC 目标：`LTSC`，尝试构建 `ENTERPRISES` 和 `IOTENTERPRISES`

也可以本地指定：

```powershell
$env:UUP_EDITION="ALL"
npm run resolve
```

## 常用版本值

- `PROFESSIONAL`: Windows Pro
- `CORE`: Windows Home
- `CORECOUNTRYSPECIFIC`: Windows Home China
- `ENTERPRISES`: Windows Enterprise LTSC
- `IOTENTERPRISES`: Windows IoT Enterprise LTSC

如果版本或语言不可用，`scripts/resolve-uup.mjs` 会直接输出 UUP dump 返回的可选列表。
