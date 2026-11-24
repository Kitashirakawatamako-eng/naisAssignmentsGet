# GitHub 提交流程

本仓库只保留一条长期分支 `main`，其余分支都是「为一件事临时开的」，合并后立即删除。下面是从改代码到发版本的完整流程。

## 一、分支模型

- `main`：随时可安装、可发布，只通过 PR 合入。
- `feature/短名`、`release/x.y.z`：一次改动一条，从 `main` 切出，合并后立刻删除。
- 不设长期 `dev`、`test` 分支。单人维护时它们只会让 `main` 落后，并在合并时制造冲突。

## 二、一次改动的完整流程

1. 同步主干

   ```sh
   cd '/Users/fangyiyang/Desktop/工具箱/SP_Assignments'
   git fetch origin
   git switch main && git pull --ff-only
   ```

2. 切出分支（名字用英文小写和连字符）

   ```sh
   git switch -c feature/gpa-csv-import
   ```

3. 改代码并本地验证。至少跑：

   ```sh
   python3 -I -B -m unittest discover -s tests -q
   xcrun swiftc -O -swift-version 5 -parse-as-library \
     -target arm64-apple-macosx14.0 Desktop/*.swift -o /tmp/AssignmentDesktop
   ```

   涉及小组件时再编一次 `TimetableWidget`，涉及安装脚本时实际安装到 `~/Applications` 打开确认。

4. 提交。作者身份固定用项目名和占位邮箱，不要用个人邮箱：

   ```sh
   git add -A
   git -c user.name='SP Assignments' \
       -c user.email='sp-assignments@example.invalid' \
       commit -F - <<'MSG'
   Fix duplicate grade rows after CSV import

   同一项目 ID 重复导入时只保留学校分数，其余标为重复。
   验证：35 项离线测试通过，本机安装后导入同一文件两次。
   MSG
   ```

5. 推送并发起 PR

   ```sh
   git push -u origin feature/gpa-csv-import
   ```

   然后打开 `https://github.com/Kitashirakawatamako-eng/naisAssignmentsGet/compare/main...feature/gpa-csv-import?expand=1`，点 **Create pull request**。

6. 合并后删除源分支（网页上点 **Delete branch**，或命令行）

   ```sh
   git push origin --delete feature/gpa-csv-import
   git branch -d feature/gpa-csv-import
   ```

   仓库 Settings → General 勾选 **Automatically delete head branches**，以后合并自动清理。

## 三、提交信息规范

- 首行英文祈使句，不超过 72 字符，说明「做了什么」，不加句号。
- 空一行，正文用中文写清改动范围、原因和验证方式。
- 一次提交只做一件事。格式化、改名、修 bug 不要混在一起。
- 不写「update」「fix bug」这类没有信息量的首行。

## 四、版本号规则

版本号写在 `Desktop/Info.plist` 两处：

| 键 | 含义 | 规则 |
| --- | --- | --- |
| `CFBundleShortVersionString` | 对外版本，如 `1.7.0` | 按下面规则递增 |
| `CFBundleVersion` | 构建号，如 `16` | 只增不减，每次安装到本机前都 +1 |

什么时候升：

- 只修 bug：末位 +1（1.7.0 → 1.7.1）
- 加功能、不破坏已有数据：中间位 +1（1.7.0 → 1.8.0）
- 改数据结构、安装方式或旧版本无法直接升级：首位 +1（1.7.0 → 2.0.0）

构建号必须跟着动，否则「关于」窗口和安装包分不清是哪次编译。

## 五、Tag：什么时候该打

Tag 是给「别人会安装的版本」和「可能要整体回滚的点」做的书签。它不是每个 commit 的存档。

该打：

- 发布到 GitHub、朋友会下载安装的版本
- 改本地数据结构或迁移逻辑之前（出问题能回到旧代码读旧数据）
- 一次大改完成、本机安装并实际用过之后

不用打：

- 中间的调试提交、只改文案或注释的提交
- 还没在本机验证过的版本
- 同一版本反复打（tag 一旦推送就不要改，发错了就发新版本号）

命名与 `Info.plist` 完全一致，前缀加 `v`：`v1.7.0`。用附注 tag（annotated），带一句说明：

```sh
git tag -a v1.7.0 -m "作业速览 1.7.0（构建 16）：成绩与 GPA"
git push origin v1.7.0
```

给历史提交补 tag（指定 commit，不改历史）：

```sh
git tag -a v1.4.2 c2c291d -m "作业速览 1.4.2（构建 11）"
git push origin v1.4.2
```

查看与校验：

```sh
git tag -l                       # 本地所有 tag
git show v1.7.0 --stat           # 该 tag 指向的提交
git ls-remote --tags origin      # 远端已推送的 tag
```

tag 打错：未推送用 `git tag -d v1.7.0`；已推送需要删除远端 `git push origin :refs/tags/v1.7.0`，再重新打，且要通知已经拉取过的人。

## 六、Tag 与 Release 的区别

- **Tag** 只是某个提交的书签，出现在仓库的 Tags 页面。
- **Release** 是在 tag 之上加的说明页，可以写更新内容、附安装包。

发版时两者一起做：网页 **Releases → Draft a new release → 选择已有 tag → 写说明 → Publish**。GitHub 会自动提供 `Source code (zip)`，不需要手动上传源码包。

## 七、本仓库现状与建议

当前 `main` 为 `fa6485fb`，版本 1.7.0（构建 16），tag 数量为 0，另有 3 条已合并分支未删除。

历史版本落点：

| 提交 | 版本 | 构建 | 说明 |
| --- | --- | --- | --- |
| `244ad5c` | 1.1 | 2 | 首次公开 |
| `f75f2e5` | 1.1.1 | 3 | 新图标 |
| `15225c4` | 1.1.3 | 5 | 置顶与自动恢复 |
| `8222732` | 1.2.0 | 6 | 置顶分全局与筛选 |
| `f628edb` | 1.2.1 | 6 | 作业助手与提醒 |
| `6bc9f44` | 1.3.0 | 7 | 图标切换与 Ocean White 主题 |
| `ad9596c` | 1.4.0 | 8 | 配色与图标调整 |
| `c2c291d` | 1.4.2 | 11 | 1.4.2 发布 |
| `e4b893e` | 1.7.0 | 16 | 成绩与 GPA |

说明：`1.2.0` 与 `1.2.1` 构建号相同，是当时漏加；`1.5`、`1.6` 没有提交记录，不必补 tag。

建议补三个：

```sh
git tag -a v1.7.0 e4b893e -m "作业速览 1.7.0（构建 16）：成绩与 GPA"
git tag -a v1.4.2 c2c291d -m "作业速览 1.4.2（构建 11）"
git tag -a v1.1.1 f75f2e5 -m "作业速览 1.1.1（构建 3）：首个公开版本"
git push origin v1.7.0 v1.4.2 v1.1.1
```

之后每发一次公开版本打一个 tag，并在 Releases 写一份说明。

## 八、每次发布前的检查清单

- [ ] 离线测试通过（`python3 -I -B -m unittest discover -s tests -q`）
- [ ] 主应用与小组件编译通过
- [ ] 本机安装后实际打开、同步一次、看过作业与成绩
- [ ] `Desktop/Info.plist` 的版本和构建号已递增
- [ ] README 里的功能说明与实际一致
- [ ] `git status --ignored` 里没有 `.private/`、`data/`、`reports/`、`*.app`、下载的仓库副本
- [ ] 提交里没有个人邮箱、账号、作业内容或附件
- [ ] tag 名与 `CFBundleShortVersionString` 一致
