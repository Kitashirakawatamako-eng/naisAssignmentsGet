# Assignment Overview

English · [简体中文](README.zh-CN.md)

A bilingual Mac app for [SchoolPal assignments](https://naisstu.schoolis.cn/Home#!/task/list/), timetables and published grades. Each student signs in with their own school account. Assignment instructions can be translated on-device, and the teacher’s original text is available in the detail view.

## Install and sign in

1. Clone the repository or choose **Code → Download ZIP** on GitHub and extract the entire folder.
2. Double-click **安装并打开.command**. If macOS requests Apple Command Line Tools, install them and run the installer again. You can also type `zsh ` in Terminal, drag the installer into the window and press Return.
3. Open **Settings → School Account**, enter your school credentials and choose **Save and Verify**. If the school requests a verification code, use the school login window and save the session.

Requires macOS 14 or later on Apple silicon or Intel. Installation downloads Python, translation dependencies and models. [Apple Command Line Tools](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools)

The installed app is in `~/Applications/Assignment Overview.app`. To update, run the installer from the new source folder. Existing records are retained.

## Assignments, timetable and desktop widgets

- Browse today, yesterday, the last three or seven days, or the current month. Combine course, task-type and submission filters, arrange by deadline, or export filtered pending work to Markdown. Mark offline work finished and reopen it later. Completion is local.
- Pin a task globally or within the current filter using task details or the list’s context menu. Task details show instructions, deadlines, files and published scores. Drag the divider to resize the list.
- While running, the app checks current-month tasks each minute on weekdays between 08:00 and 20:00 Beijing time. **Sync Now** runs a manual check. Failed requests keep the last result and can be retried. Open attachments to see instructions embedded in documents or images.
- View today, this week or next week in **Timetable**. The optional menu bar item shows the current and next lesson. A floating timetable is also available.
- After syncing, right-click the desktop and choose **Edit Widgets → Assignment Overview**. Choose pinned assignments, timetable or next class, or configure **My Overview** and **My Second Overview** separately for deadlines, GPA, classes or pins. Each slot offers theme colors, mint, blue, lavender, peach or rose, and can show all visible pins, global pins, filtered pins or one selected task. Deadlines prioritize pinned, unfinished upcoming work. The GPA widget displays SchoolPal’s published value.
- Use **Settings → Desktop Widgets** to configure small widgets, preview data or request a refresh. Medium overview widgets have an Edit action. macOS controls actual refresh timing and desktop tinting. [Design and verification notes](DESIGN_REVIEW.md)

## Grades and forecasts

Open **Grades → Sync Semester Grades** for current-semester published task scores and SchoolPal Realtime Performance. Select a course to inspect its published grade, category weights, category scores and grade-point ranges. **Grade Tools** can open SchoolPal, import a captured SchoolPal grades directory, or copy sync diagnostics.

In **Reverse-calculate a course goal**, choose a forecast:

- **Mixed tasks** accepts independent rows. For example, enter mini-quizzes of 7/10 and 9/10 alongside homework scores of 60/100, 70/100, 80/100, 90/100 and 100/100. Use the count field when several tasks have the same score and maximum.
- **Repeated score** calculates the score or number of equal-score tasks needed to meet a course goal. It can also show the best attainable result with full marks.
- Expand **Published category scores** to see SchoolPal’s current values. Both modes show current and projected results for affected categories, the course percentage, the distance from the target and course grade points when a scale is available. School-category forecasts average individual task percentages and apply the course’s category weights. If the school supplies a category grade without its item count, enter a known count or an explicit assumption.
- **Estimated semester GPA change** holds other included courses constant. Choose equal course weights or enter all course credits under **Course Credits** for a credit-weighted result. The before/after averages and signed difference use the same weighting. Forecasts are separate from the GPA published by SchoolPal.
- Semester and cumulative planning also supports custom scales, prior GPA and credits, expected final section scores and multi-course scenarios. Use **Grade Tools → Record Transcript GPA** to keep a transcript value. [Calculation details](GPA_PLAN.md)

**Grade Tools → Import Grades CSV** previews additions, supplements, duplicates, conflicts and out-of-term records. Use UTF-8, give each row a subject and title, and supply a score or level. A maximum is required to calculate a percentage. Dates and school IDs help match existing items. Published school scores take priority. Imports before semester identification are available under **View Offline Grades**.

```csv
科目,项目,类别,日期,得分,满分,项目ID,等级
Math,Unit quiz,Quiz,2026-11-10,18,20,,
```

## Accounts, files and appearance

Switch accounts in Settings. Switching restarts the app. Each account has its own school session, records and reports in `~/Library/Application Support/作业速览/Users/<account>/` and its own Keychain credentials. The school client contacts the school host and restricts downloads to school domains. The app has no telemetry.

Downloaded attachments are copied into task folders under `~/Downloads/作业速览/` by default. Change **Settings → Attachment Folder** or open the folder from task details. Changing folders copies current attachments and preserves earlier copies.

Choose Little Otter, Fossil Cove, Ocean White or Classic Jade under **Settings → Appearance**. The app remembers the theme and Dock/Finder icon. Select an icon separately, or toggle the rounded white background on the otter and Anomalocaris. The original icon is bundled in `Desktop/ClassicIcon.icns`.

## Optional Gemini homework assistant

Under **Settings → AI Assistant**, open Google AI Studio and create a key for a free-tier project with billing disabled. Save it to macOS Keychain. Check your project’s billing status yourself. Model availability, regional access and quotas vary. The app uses `gemini-4-hydrogen` and has no paid-model fallback. [Google pricing](https://aistudio.google.com/docs/pricing)

Enable reminders in the app and allow macOS notifications. Reminders default to 24 hours before the deadline. Scheduled reminders can fire while the app is closed. New deadlines require a sync, and Focus can affect delivery.

Select an assignment and files, then choose **Yes — Generate Answers** to send them to Gemini. School login credentials stay on your Mac. Google may use free-tier content to improve its products. Supported files include PDF, DOCX, PNG/JPG/WebP and UTF-8 TXT/MD/CSV, up to 10 MB each and 20 MB combined. DOCX contributes text only. Export as PDF to include diagrams. Review Markdown drafts in **AI Homework/**, use **Export File** or **Show in Finder**, and submit them yourself. Cancelling or receiving an incomplete response does not save a draft.

## Source and tests

The Mac app is in `Desktop/`, synchronization and reports in `backend/`, widgets in `TimetableWidget/`, and installation in `scripts/`. Run `python3 -B -m unittest discover -s tests` with Python 3.13. See the [third-party notices](scripts/THIRD_PARTY.md) and the separate [Fieldnotes planner](PlannerWidget/README.md).
