# 作业速览

在 Mac 上查看 [学校任务](https://naisstu.schoolis.cn/Home#!/task/list/) 和课表。应用用各自的学校账号同步作业、提交状态、已发布成绩及附件。可切换中英文界面，使用本机模型翻译任务要求，详情中可展开老师原文。

## 从 GitHub 安装

1. 在仓库页面点 **Code → Download ZIP**，解压整个文件夹。也可以克隆仓库。
2. 双击文件夹里的 **安装并打开.command**。首次使用时如果系统提示安装 Apple 命令行工具，按提示完成，再运行一次。若无法双击，可以打开「终端」，输入 `zsh` 后加一个空格，将安装文件拖进终端，再按回车。
3. 安装完成后会打开 **作业速览**。进入 **设置**，填写自己的学校账号和密码，再点 **保存并验证**。学校要求验证码时，在应用里打开 **学校登录窗口** 完成验证，再点 **保存登录**。

支持搭载 Apple 芯片或 Intel 芯片、运行 macOS 14 或更新版本的 Mac。安装时需要联网下载 Python、翻译依赖和模型。Apple 命令行工具可按[官方说明](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools)安装，无需下载完整的 Xcode。

以后从 Finder 的个人「应用程序」文件夹打开作业速览。下载较新的源码后，再运行安装文件即可更新，应用会沿用已有记录。

## 使用

- **作业**默认显示今天布置的任务，也可以查看昨天、近 3 天、近 7 天和本月。支持同时勾选多个科目、任务类型、提交状态，可把当前筛选里的待办导出为 Markdown。
- **置顶**可从任务详情或列表右键菜单开启，分两种：**全局置顶**不受当前筛选影响，始终显示在列表顶部；**仅当前筛选**只在任务符合筛选条件时置顶。列表里实心图钉表示全局，空心表示筛选内。置顶状态会留在本机。
- **任务详情**包含要点、截止时间、老师原文、附件和已发布成绩。作业列表与详情之间的宽度可拖动，应用会记住位置。
- **同步**在应用运行时按北京时间工作日 08:00–20:00 每分钟检查一次，也可以点 **立即同步**。只查询本月的新任务，按日更新本地记录。
- **课表**可查看今天、本周和下周。在 Mac 菜单栏可以看当前与下一节课，也可在应用内打开 **课表小窗**。打开应用同步后，右键桌面，选择 **编辑小组件 → 作业速览 / Assignment Overview → 课表 / Timetable**。小组件提供小号和中号，点击可打开完整课表。

连接暂时失败时，应用会保留上一次结果，并在同步时段自动重试。单条详情失败也会在下一轮补查。学校要求额外验证时，可以从设置打开学校登录窗口。图片和文档里的要求需要打开附件查看。

## 本机文件

应用安装到 `~/Applications/作业速览.app`。任务、课表、已下载附件和登录会话保存在 `~/Library/Application Support/作业速览/`。自动登录凭据由 macOS 钥匙串保管。通过 Finder 的 **前往 → 前往文件夹** 可以打开这些位置。

独立计划器 Fieldnotes 的源码与使用方式见 [PlannerWidget](PlannerWidget/README.md)。

## 源码

- `Desktop/` 是 Mac 界面。
- `backend/` 负责同步、课表、附件与报告。
- `scripts/` 负责安装与构建。组件见[第三方说明](scripts/THIRD_PARTY.md)。
- `tests/` 是离线测试。已有 Python 3.13 的开发环境可运行 `python3 -B -m unittest discover -s tests`。


## Gemini homework assistant

Open **Settings → AI Assistant → Get a free Gemini API key**. Create a key in Google AI Studio from a project on the **Free tier with billing disabled**. Paste it into the app, confirm that billing is disabled, and save it to macOS Keychain. Do not share your key in chat. The app cannot inspect project billing from a key; a billing-enabled project can incur charges, even for the same model. Regional availability and free quotas apply.

The assistant uses only `gemini-4-hydrogen`, currently listed with free input/output on Google's Free tier. It does not use paid fallback models, paid tools, or automatically retry quota failures. It never reads an old OpenAI key. Check [Google pricing](https://aistudio.google.com/docs/pricing) and your project tier before use.

Deadline reminders default to 24 hours before the due date. Allow notifications in macOS System Settings and enable reminders in the app. Scheduled notifications may appear while the app is closed; new or changed deadlines require the app to run and sync. Delivery depends on macOS notification settings and Focus.

Click a reminder or **AI Assistant**, select the assignment and necessary files, and click **Yes — Generate Answers**. Only this explicit action sends assignment text and selected files to Google Gemini. Google may use free-tier content to improve its products. School credentials and session cookies are not sent. Supported inputs: PDF, DOCX, PNG/JPG/WebP, UTF-8 TXT/MD/CSV (10 MB per file, 20 MB total). DOCX is read as text; export to PDF for diagrams or visual layout. The app does not fetch external attachment links.

Answers are saved as Markdown drafts in the app data directory under **AI Homework/**. Use **Export File** or **Show in Finder**, and review before submitting yourself. Missing information is identified instead of invented. Cancel stops the request; errors and incomplete responses do not save an answer file.

## Appearance (local version 1.3.0)

Open **Settings → Appearance** to choose your theme and icon. A theme selects its matching icon, which you can change separately. The app restores your chosen Dock icon on launch. Changing the icon in Settings also applies a Finder custom icon. The original icon is preserved in `Desktop/ClassicIcon.icns`.

## Creature themes (local version 1.4.0)

**Settings → Appearance** now includes **Little Otter** (cream surfaces, clear-water blue/teal accents, a floating pixel otter with a gently curved tail) and **Fossil Cove** (fossil ivory, moss green, sandstone accents, the preserved monochrome curled Anomalocaris). Both use flat colors, transparent mascot icons, and matching header mascots. Ocean White and Classic Jade remain available. Selecting a theme selects its matching icon; the icon can also be chosen separately. Little Otter is the default. The app remembers your theme and icon choices.

Little Otter and Fossil Cove include matching scenery inside their rounded app icons. Toggle **Icon background** in Appearance to choose the scenery tile or transparent mascot. Page backgrounds remain solid colors. All artwork is bundled locally.
