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

## 提交准备

- 在任务详情打开 **Submission → Writing this now**，把这一项标记为「正在写」。列表里会出现铅笔标记。
- **Add Files…** 可一次选多个文件，也可以直接把文件拖进详情页。文件只复制到本机 `data/submissions/<任务>/`，不会上传。
- 每次生成的草稿按「AI Homework/科目/作业」分文件夹保存，长文档的分批结果会拼在同一份草稿里。
- 打开 **设置 → Collect AirDropped files** 后，标记期间新出现在「下载」里的文件（隔空投送默认落点）会自动加进当前作业。
- 准备好后点 **Submit to School**：应用会先把文件上传到学校，再按学校的提交流程直接提交这份作业，成功后自动重新同步状态。确认框点取消就不会提交。

## 账号与隐私

- **设置 → 学校账号** 可以添加多个账号。每个账号的登录会话、作业、成绩、附件和报告都保存在 `Users/<账号>/`，互相看不到；自动登录凭据在钥匙串里也按账号分开。切换账号会重启应用。
- 应用运行时只请求 `naisstu.schoolis.cn`，附件只从 `*.schoolis.cn` 下载。后端会拒绝指向其他地址的请求，代码里没有遥测或统计上报。
- 作业助手默认关闭。**设置 → AI 助手** 可选 Google Gemini，或任何兼容 OpenAI `/chat/completions` 的服务：填自己的 Base URL、模型名和 Key，密钥按提供商分别存在钥匙串。PDF 和图片会先在本机渲染成页面图再发给模型，模型自己读题、图和表格；页数多时按每 4 页一批分次发送，相邻批次重叠 1 页，跨页的题不会被切断；最多 24 页。PPTX/PPT/DOCX/XLSX 在装了 LibreOffice 时会整页转成图片；没装时 PPTX 会把幻灯片里的图片按原图发送，并附上文字。RTF 与纯文本仍抽成文字。只有你点 **Yes — Generate Answers** 时，当次作业正文和所选文件才会发给你选的那家。

## 本机文件

应用安装到 `~/Applications/作业速览.app`。已下载的附件默认按任务复制到 `~/Downloads/作业速览/`。可在 **设置 → 附件存储位置** 更换目录，或在作业详情点 **打开附件文件夹**。每个学校账号的数据分别在 `~/Library/Application Support/作业速览/Users/<账号>/`，换附件目录时会重新复制当前任务附件，已保存的文件留在原位置。自动登录凭据由 macOS 钥匙串保管。

在 macOS 桌面右击并选择 **编辑小组件**，搜索 **作业速览**，可添加置顶作业、课表和下一节课。置顶作业沿用应用里的全局和筛选内置顶规则。小组件随应用主题切换，macOS 启用单色或系统着色时按系统样式显示。

新增的「我的速览」和「第二个速览」可分别选择作业截止时间、学期 GPA、课表、下一节或置顶作业。中号组件点「编辑」即可切换，小号组件在 **设置 → 桌面小组件** 切换。同名组件共享选择。两个速览可单独选择跟随主题、薄荷绿、天蓝、淡紫、蜜桃或玫瑰色。选择「置顶作业」后，还可指定全部可见置顶、仅全局、仅当前筛选或单项作业。截止时间只列出未完成且尚未到期的作业，置顶优先，同组按截止时间排序。GPA 小组件显示校宝公布的本学期 GPA。

在 **设置 → 桌面小组件 → 预览小组件** 可先查看当前数据和主题，也可以请求刷新。实际桌面刷新时间由 macOS 决定。设计稿、功能入口及本轮检查步骤见 [设计与验收说明](DESIGN_REVIEW.md)。

在 **成绩** 页可同步当前学期的校宝动态成绩和已发布的任务分数。点开课程可查看考勤、参与度、作业、考试等实际计分类别的权重和成绩，以及该课的绩点换算表。**成绩工具 → 导入校宝成绩采集文件** 支持选择包含校宝原始成绩响应的采集目录。同步和导入只存成绩所需字段。

打开课程的 **下次任务对本课绩点的影响**，可逐条添加任务，选择校宝类别并填写得分和满分。试算显示受影响类别的分数、课程总评和绩点变化。需要时可以补填已有计分项数做假设。单科试算使用学校的类别权重和换算区间，多科 GPA 试算仍需按校方记录填写学分。计算方式见 [GPA 分析方案](GPA_PLAN.md)。

学校网页可以正常打开时，点 **成绩 → 同步学期成绩**。若有问题，可从 **成绩工具 → 复制成绩同步诊断** 复制版本、日期、数量和错误信息。

也可以从 **成绩工具 → 导入成绩 CSV** 预览导入。文件须为 UTF-8，可以使用以下列名和格式。科目和项目必填，得分与等级至少填写一项，满分用来计算比例。日期和学校项目 ID 用于核对范围和重复记录。

```csv
科目,项目,类别,日期,得分,满分,项目ID,等级
数学,单元测验,测验,2026-11-10,18,20,,
```

预览会标出新增、补齐、重复、冲突和超出学期范围的记录。学校已公布的有效分数优先。尚未确认学校学期时，导入记录保存在离线学期。之后可从 **成绩工具 → 查看离线成绩** 找到。

用 **课程学分** 补齐参与 GPA 的课程。没有校宝课程换算表时可以在 **GPA 换算表** 填入规则。已有成绩单 GPA 可从 **成绩工具 → 录入成绩单 GPA** 登记。多科提分试算可添加不同课程、类别和满分的项目，并保存预计分数、满分上限及目标条件。

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

Little Otter and Fossil Cove include solid white backgrounds inside their rounded pixel icons. Toggle **Icon background** in Appearance to choose the white tile or transparent mascot. Page backgrounds remain solid colors. All artwork is bundled locally.
