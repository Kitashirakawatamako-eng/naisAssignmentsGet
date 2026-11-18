import copy
from datetime import datetime, timedelta
from http.client import IncompleteRead
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))

import desktop_bridge
import school_tasks as app
from school_timetable import read_timetable
from task_records import published_grade, task_metadata
from task_report import translate_lines


NOW = datetime(2026, 11, 11, 12, tzinfo=app.TZ)
MONTH_START = NOW.replace(day=1, hour=0)


class FakeClient:
    def __init__(self, rows=None):
        self.rows = rows if rows is not None else [{"id": "task/1", "name": "练习", "subjectName": "数学", "beginTime": "2026-11-11T10:00:00", "endTime": "2026-11-12T16:00:00", "finishState": 2}]
        self.fail_detail = False
        self.detail = {"content": "<p>完成第 5 页第 1—4 题。</p>", "learningTaskDocuments": []}
        self.detail_requests = []

    def get(self, path, **params):
        if path.endswith("GetSchoolSemesters"):
            return [{"id": "s1", "isNow": True, "startDate": "2026-09-01", "endDate": "2027-01-31"}]
        if path.endswith("GetList"):
            size = params["pageSize"]
            start = (params["pageIndex"] - 1) * size
            return {"list": copy.deepcopy(self.rows[start:start + size]), "totalCount": len(self.rows)}
        self.detail_requests.append(params["learningTaskId"])
        if self.fail_detail:
            raise app.LoginRequired("expired")
        return copy.deepcopy(self.detail)

    def download(self, url, target):
        raise app.SyncError("测试下载失败")


class SyncTests(unittest.TestCase):
    def test_new_install_saves_browser_session_only_after_successful_verification(self):
        cookies = [
            {"name": "SessionId", "value": "test-session", "domain": "naisstu.schoolis.cn"},
            {"name": "Other", "value": "discard", "domain": "example.invalid"},
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            auth = root / ".private/session.json"
            with (patch.object(app, "ROOT", root), patch.object(app, "AUTH", auth),
                  patch.object(app, "get_semester") as verify):
                verify.side_effect = app.LoginRequired("需要登录")
                with self.assertRaises(app.LoginRequired):
                    app.accept_browser_session(cookies)
                self.assertFalse(auth.exists())
                verify.side_effect = None
                app.accept_browser_session(cookies)
            saved = app.load_json(auth, {})
            self.assertEqual([cookie["name"] for cookie in saved["cookies"]], ["SessionId"])
            self.assertEqual(auth.stat().st_mode & 0o777, 0o600)

    def test_translated_text_drops_tokenizer_markers_and_keeps_real_underscores(self):
        original = ("请上传 task_4.pdf 并完成第 4 题。", "Fill in: ____")
        tokenizer, translator = MagicMock(), MagicMock()
        tokenizer.decode.return_value = "▁Upload task_4.pdf▁and complete question 4.▁"
        translator.translate_batch.return_value = [MagicMock(hypotheses=[["▁请"]])]
        with tempfile.TemporaryDirectory() as directory:
            with patch("task_report.load_translator", return_value=(tokenizer, translator)):
                lines, translated = translate_lines(Path(directory), original)
        self.assertTrue(translated)
        self.assertEqual(lines, ("Upload task_4.pdf and complete question 4.", "Fill in: ____"))

    def test_timetable_uses_beijing_weeks_and_keeps_only_real_class_times(self):
        math = {"scheduleType": 3, "name": "Advanced Math", "beginTime": "2026-11-11T00:00:00Z",
                "endTime": "2026-11-11T00:45:00Z", "playgroundName": "205",
                "teacherList": [{"name": "教师 A"}, {"name": "教师 A"}]}
        client = MagicMock()
        client._json_request.return_value = {
            "state": 0, "data": [
                math, dict(math), dict(math, scheduleType=2, name="校历"),
                dict(math, scheduleType=4, name="临时课", beginTime="2026-11-16T09:00:00",
                     endTime="2026-11-16T09:45:00"),
            ]
        }
        timetable = read_timetable(client, NOW)
        self.assertEqual((timetable["start_day"], timetable["end_day"]), ("2026-11-09", "2026-11-22"))
        client._json_request.assert_called_once_with(
            "/api/Schedule/ListScheduleByParent", {},
            body={"beginTime": "2026-11-09", "endTime": "2026-11-22"}, referer=app.BASE + "/Home",
            retry_read=True)
        math, temporary = timetable["courses"]
        self.assertEqual((math["title"], math["start_at"], math["teacher"], math["room"]),
                         ("Advanced Math", "2026-11-11T08:00:00+08:00", "教师 A", "205"))
        self.assertTrue(temporary["temporary"])

    def test_desktop_reads_legacy_and_native_daily_records(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, client = Path(tmp), FakeClient()
            app.sync(client, root, NOW)
            before = (root / "reports/latest.html").read_bytes()
            task = desktop_bridge.snapshot(root)["tasks"][0]
            self.assertEqual(task["assigned_day"], "2026-11-11")
            self.assertIn("完成第 5 页第 1—4 题", task["brief"])
            self.assertTrue(task["pending"])

            client.rows[0].update(learningTaskState=4, finishState=1, scoreType=1, score=0,
                                  totalScore=10, isSynchroToMobiled=1)
            app.sync(client, root, NOW.replace(minute=1), write_html=False)
            self.assertEqual((root / "reports/latest.html").read_bytes(), before)
            self.assertEqual(len(list((root / "data/report-days").glob("*.json"))), 1)
            task = desktop_bridge.snapshot(root)["tasks"][0]
            self.assertEqual(task["grade"], "0 / 10")
            self.assertEqual(task["submission_bucket"], "submitted")
            self.assertFalse(task["pending"])

    def test_initial_dedup_update_and_new(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, client = Path(tmp), FakeClient()
            now = NOW
            first = app.sync(client, root, now)
            self.assertEqual(first["changes"], 1)
            self.assertTrue(first["initial"])
            day_report = Path(first["report"])
            self.assertEqual(day_report.name, "学校任务-2026-11-11.html")
            self.assertIn("完成第 5 页第 1—4 题", day_report.read_text())
            self.assertEqual(app.sync(client, root, now.replace(minute=15))["changes"], 0)
            self.assertIn("完成第 5 页第 1—4 题", day_report.read_text())
            self.assertEqual(client.detail_requests, ["task/1"])
            client.detail["content"] = "更正为完成第 6 页。"
            client.rows[0]["syncTime"] = "2026-11-11T12:01:00"
            self.assertEqual(app.sync(client, root, now)["changes"], 1)
            self.assertIn("更正为完成第 6 页", day_report.read_text())
            client.rows.append(dict(client.rows[0], id="second"))
            self.assertEqual(app.sync(client, root, now)["changes"], 1)
            self.assertEqual(day_report.read_text().count('<details class="task"'), 2)
            self.assertEqual(list((root / "reports").glob("学校任务-*.html")), [day_report])
            next_day = app.sync(client, root, now.replace(day=12))
            self.assertEqual(next_day["changes"], 0)
            self.assertIn('data-age="1" hidden', Path(next_day["report"]).read_text())
            self.assertIn("今天没有布置作业", Path(next_day["report"]).read_text())
            self.assertEqual(day_report.read_text().count('<details class="task"'), 2)

    def test_failed_run_preserves_checkpoint_and_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, client = Path(tmp), FakeClient()
            app.sync(client, root, NOW)
            before = (root / "data/state.json").read_bytes()
            report = (root / "reports/latest.html").read_bytes()
            client.fail_detail = True
            client.rows[0]["name"] = "任务更新"
            with self.assertRaises(app.LoginRequired):
                app.sync(client, root, NOW)
            self.assertEqual(before, (root / "data/state.json").read_bytes())
            self.assertEqual(report, (root / "reports/latest.html").read_bytes())

    def test_pagination_and_duplicate_page_failure(self):
        rows = [{"id": str(x), "beginTime": "2026-11-01T00:00:00"} for x in range(205)]
        self.assertEqual(len(app.collect_list(FakeClient(rows), MONTH_START)[1]), 205)
        rows[-1]["id"] = "0"
        with self.assertRaises(app.SyncError):
            app.collect_list(FakeClient(rows), MONTH_START)

    def test_partial_page_is_not_success(self):
        client = FakeClient()
        original = client.get
        def get(path, **params):
            result = original(path, **params)
            if path.endswith("GetList"):
                result["totalCount"] = 1000
            return result
        client.get = get
        with self.assertRaises(app.SyncError):
            app.collect_list(client, MONTH_START)

    def test_download_retry_and_safe_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, client = Path(tmp), FakeClient()
            client.detail["learningTaskDocuments"] = [{"name": "../../outside.pdf", "url": "https://cdn.schoolis.cn/a.pdf"}]
            self.assertEqual(app.sync(client, root, NOW)["warnings"], 1)
            self.assertEqual(app.sync(client, root, NOW)["warnings"], 1)
            self.assertFalse((root / "outside.pdf").exists())
            self.assertNotIn("/", app.safe_name("../../outside.pdf"))

    def test_existing_download_keeps_original_name_in_daily_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, client = Path(tmp), FakeClient()
            client.detail["learningTaskDocuments"] = [{"name": "Unit 3 (练习).pdf", "url": "https://cdn.schoolis.cn/a.pdf"}]
            task = app.normalize(client.rows[0], client.detail)
            item = task["attachments"][0]
            folder = root / "data/tasks" / app.fingerprint(task["id"])[:24]
            folder.mkdir(parents=True)
            legacy = folder / (app.fingerprint(item)[:12] + "-" + app.safe_name(item["name"]))
            legacy.write_bytes(b"existing download")
            result = app.sync(client, root, NOW)
            self.assertEqual(result["downloaded"], 1)
            local = next(folder.glob("文件/*/*.pdf"))
            self.assertEqual(local.name, item["name"])
            self.assertEqual(local.read_bytes(), b"existing download")
            self.assertIn("Unit%203%20%28", Path(result["report"]).read_text())

    def test_watcher_publishes_link_before_file_download(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, client = Path(tmp), FakeClient()
            client.detail["learningTaskDocuments"] = [
                {"name": "Homework.pdf", "url": "https://cdn.schoolis.cn/homework.pdf"}]
            worker = MagicMock()
            worker.submit.return_value = ("下载中", None)
            result = app.sync(client, root, NOW, downloads_worker=worker)
            worker.submit.assert_called_once()
            self.assertEqual((result["links"], result["downloaded"], result["warnings"]), (1, 0, 0))
            self.assertIn('href="https://cdn.schoolis.cn/homework.pdf"', Path(result["report"]).read_text())

    def test_auth_and_unknown_response_fail_closed(self):
        with self.assertRaises(app.LoginRequired):
            app.unwrap({"state": 999901, "data": ""})
        with self.assertRaisesRegex(app.SyncError, "权限"):
            app.unwrap({"state": 999902, "data": ""})
        for response in ({"list": []}, {"state": 12}, []):
            with self.assertRaises(app.SyncError):
                app.unwrap(response)

    def test_auto_login_stops_when_school_asks_for_verification(self):
        client = app.Client(fresh=True)
        with patch.object(client, "_json_request", return_value={"state": 0, "data": "verification image"}) as request:
            with self.assertRaises(app.LoginRequired):
                client.sign_in(app.school_credential("example", "Example123"))
        request.assert_called_once_with("/api/MemberShip/GetStudentCaptchaForLogin", {}, referer=app.LOGIN_URL)

    def test_check_retries_once_with_new_session_and_saves_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            auth = root / ".private/session.json"
            settings = auth.with_name("auto-login.json")
            app.save_json(auth, {"cookies": []})
            app.save_json(settings, {"enabled": True})
            old_client = app.Client(auth)
            fresh_client = app.Client(fresh=True)
            cookie = {"name": "SessionId", "value": "example", "domain": "naisstu.schoolis.cn"}
            credential = app.school_credential("example", "Example123")
            with (patch.object(app, "ROOT", root),
                  patch.object(app, "AUTH", auth),
                  patch.object(app, "AUTO_LOGIN", settings),
                  patch.object(app, "read_credential", return_value=credential),
                  patch.object(app, "new_school_session", return_value=fresh_client) as sign_in,
                  patch.object(fresh_client, "session_cookies", return_value=[cookie]),
                  patch("builtins.print")):
                check = MagicMock(side_effect=[app.LoginRequired("过期"), "同步完成"])
                self.assertEqual(app.check_with_login(check, old_client), "同步完成")
                sign_in.assert_called_once_with(credential)
            self.assertEqual([args.args[0] for args in check.call_args_list], [old_client, fresh_client])
            self.assertEqual(app.load_json(auth, {})["cookies"], [cookie])
            self.assertEqual(auth.stat().st_mode & 0o777, 0o600)

    def test_rejected_credential_is_not_retried_on_later_checks(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            auth = root / ".private/session.json"
            settings = auth.with_name("auto-login.json")
            app.save_json(settings, {"enabled": True})
            with (patch.object(app, "ROOT", root),
                  patch.object(app, "AUTH", auth),
                  patch.object(app, "AUTO_LOGIN", settings),
                  patch.object(app, "read_credential", return_value=app.school_credential("example", "Example123")),
                  patch.object(app, "new_school_session", side_effect=app.CredentialRejected("错误密码")) as sign_in):
                with self.assertRaises(app.CredentialRejected):
                    app.recover_session(None)
                with self.assertRaises(app.LoginRequired):
                    app.recover_session(None)
                sign_in.assert_called_once()
            self.assertFalse(auth.exists())

    def test_html_and_timezones(self):
        self.assertEqual(app.plain("<p>A</p><script>bad()</script><p>B &amp; C</p>"), "A\nB & C")
        self.assertEqual(app.due_date("2026-11-11T00:00:00Z").hour, 8)
        self.assertIsNone(app.due_date("invalid"))

    def test_empty_semester_is_valid_baseline(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(app.sync(FakeClient([]), Path(tmp), NOW)["changes"], 0)

    def test_incomplete_read_retries(self):
        client = app.Client.__new__(app.Client)
        client.opener = MagicMock()
        response = client.opener.open.return_value.__enter__.return_value
        response.url = app.BASE
        response.length = None
        response.read.side_effect = [IncompleteRead(b'{"state":'), b'{"state":0,"data":{"list":[]}}']
        with patch.object(app.time, "sleep"):
            self.assertEqual(client.get("/api/LearningTask/GetList"), {"list": []})
        self.assertEqual(client.opener.open.call_count, 2)

    def test_connection_timeout_is_recoverable_without_retrying_login_post(self):
        client = app.Client(fresh=True)
        with patch.object(client.opener, "open", side_effect=app.urllib.error.URLError(TimeoutError())), \
             patch.object(app.time, "sleep"):
            with self.assertRaisesRegex(app.TemporarySyncError, "响应超时"):
                client.get("/api/LearningTask/GetList")
            self.assertEqual(client.opener.open.call_count, 3)
            client.opener.open.reset_mock()
            with self.assertRaises(app.TemporarySyncError):
                client._json_request("/api/MemberShip/Login", {}, body={})
            client.opener.open.assert_called_once()

    def test_respects_retry_after_without_immediate_requests(self):
        for status in (429, 503):
            with self.subTest(status=status):
                client = app.Client(fresh=True)
                error = app.urllib.error.HTTPError(app.BASE, status, "Retry later", {"Retry-After": "180"}, None)
                with patch.object(client.opener, "open", side_effect=error) as request:
                    with self.assertRaises(app.RateLimited) as caught:
                        client.get("/api/LearningTask/GetList")
                    self.assertEqual(caught.exception.retry_after, 180)
                    with self.assertRaises(app.RateLimited):
                        client.get("/api/LearningTask/GetList")
                    request.assert_called_once()

    def test_exclude_old_tasks_and_extract_links(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, client = Path(tmp), FakeClient()
            client.rows.append(dict(client.rows[0], id="old", beginTime="2026-10-29T12:00:00"))
            client.detail["content"] = '<a href="https://example.com/work.pdf?a=1&amp;b=2">worksheet</a> https://example.com/files.zip'
            result = app.sync(client, root, NOW)
            self.assertEqual(client.detail_requests, ["task/1"])
            self.assertEqual(result["links"], 2)
            self.assertIn('href="https://example.com/work.pdf?a=1&amp;b=2"', (root / "reports/latest.html").read_text())
            client.rows[0]["syncTime"] = "2026-11-11T12:01:00"
            client.detail["publishTime"] = "2026-10-31T23:50:00"
            self.assertEqual(app.sync(client, root, NOW)["tasks"], 0)

    def test_watch_window(self):
        self.assertEqual(app.check_slot(NOW.replace(hour=8, minute=23, second=20)), NOW.replace(hour=8, minute=23))
        self.assertEqual(app.check_slot(NOW.replace(hour=20)), NOW.replace(hour=20))
        self.assertIsNone(app.check_slot(NOW.replace(hour=20, minute=1)))
        self.assertIsNone(app.check_slot(NOW.replace(day=14)))

    def test_watcher_polls_again_after_one_minute(self):
        with tempfile.TemporaryDirectory() as tmp:
            clock = 0
            polls = []

            def sleep(seconds):
                nonlocal clock
                clock += seconds
                if clock >= 65:
                    raise KeyboardInterrupt

            def synchronize(*args, **kwargs):
                polls.append(clock)
                return {"changes": 0, "grades": 0, "report": "测试"}

            with (patch.object(app, "ROOT", Path(tmp)),
                  patch.object(app, "AUTH", Path(tmp) / "test-session"),
                  patch.object(app, "AttachmentWorker"),
                  patch.object(app, "Client", return_value=MagicMock(auth_stamp=None)),
                  patch.object(app, "get_semester") as semester,
                  patch.object(app, "check_slot", return_value=NOW),
                  patch.object(app, "sync", side_effect=synchronize),
                  patch.object(app.time, "monotonic", side_effect=lambda: clock),
                  patch.object(app.time, "sleep", side_effect=sleep),
                  patch("builtins.print")):
                with self.assertRaises(KeyboardInterrupt):
                    app.watch()
            self.assertEqual(polls, [0, 60])
            semester.assert_called_once()

    def test_desktop_recovers_automatically_and_clears_retry_notice(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, client = Path(tmp), FakeClient()
            app.sync(client, root, NOW, write_html=False)
            report = root / "reports/latest.json"
            before = report.read_bytes()
            clock = 100.0

            def recover(now, **kwargs):
                return app.sync(client, root, now, write_html=False)

            with (patch.object(app, "ROOT", root),
                  patch.object(app.time, "monotonic", side_effect=lambda: clock),
                  patch.object(desktop_bridge, "datetime", wraps=datetime) as wall_clock,
                  patch.object(desktop_bridge, "emit"),
                  patch.object(app, "AttachmentWorker"),
                  patch("builtins.print")):
                wall_clock.now.return_value = NOW
                backend = desktop_bridge.DesktopBackend()
                backend.next_timetable = 1000.0
                with patch.object(backend.session, "run",
                                  side_effect=[app.TemporarySyncError("学校接口响应超时。")]) as request:
                    backend.handle({"action": "poll", "automatic": True})
                    clock += 14
                    backend.handle({"action": "poll", "automatic": True})
                    request.assert_called_once()
                self.assertEqual(report.read_bytes(), before)
                self.assertIsNotNone(desktop_bridge.snapshot(root)["retry_at"])
                self.assertEqual(backend.next_check, 115.0)

                clock += 1
                wall_clock.now.return_value = NOW + timedelta(seconds=15)
                with patch.object(backend.session, "run", side_effect=recover) as request:
                    backend.handle({"action": "poll", "automatic": False})
                    request.assert_not_called()
                    backend.handle({"action": "poll", "automatic": True})
                    request.assert_called_once()

            result = desktop_bridge.snapshot(root)
            self.assertIsNone(result["sync_error"])
            self.assertIsNone(result["retry_at"])
            self.assertNotEqual(report.read_bytes(), before)

    def test_detail_only_edit_is_seen_after_cache_window(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, client = Path(tmp), FakeClient()
            app.sync(client, root, NOW)
            client.detail["content"] = "做第 7 题。"
            self.assertEqual(app.sync(client, root, NOW.replace(minute=1))["changes"], 0)
            result = app.sync(client, root, NOW.replace(minute=31))
            self.assertEqual(result["changes"], 1)
            self.assertIn("做第 7 题", Path(result["report"]).read_text())

    def test_failed_detail_is_retried_before_its_cache_expires(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, client = Path(tmp), FakeClient()
            app.sync(client, root, NOW, write_html=False)
            saved = root / "reports/latest.json"
            original_get = client.get

            def interrupt_detail(path, **params):
                if path.endswith("GetDetail"):
                    raise app.TemporarySyncError("学校接口响应超时。")
                return original_get(path, **params)

            with patch.object(client, "get", side_effect=interrupt_detail):
                app.sync(client, root, NOW + timedelta(minutes=1), refresh_details=True, write_html=False)
            task = app.load_json(saved, {})["tasks"][0]
            self.assertTrue(task["detail_pending"])
            self.assertIn("第 5 页", task["content"])

            client.detail["content"] = "更新为完成第 8 页。"
            app.sync(client, root, NOW + timedelta(minutes=2), write_html=False)
            task = app.load_json(saved, {})["tasks"][0]
            self.assertFalse(task["detail_pending"])
            self.assertIn("第 8 页", task["content"])
            self.assertEqual(client.detail_requests, ["task/1", "task/1"])

    def test_grade_publish_change_and_withdrawal(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, client = Path(tmp), FakeClient()
            row = client.rows[0]
            row.update(scoreType=1, score=0, totalScore=10, isSynchroToMobiled=0)
            self.assertEqual(app.sync(client, root, NOW)["grades"], 0)
            row["isSynchroToMobiled"] = 1
            result = app.sync(client, root, NOW.replace(minute=1))
            self.assertEqual(result["grades"], 1)
            self.assertIn("<strong>0</strong> / 10", Path(result["report"]).read_text())
            row["score"] = 8.5
            result = app.sync(client, root, NOW.replace(minute=2))
            self.assertEqual(result["changes"], 1)
            self.assertIn("<strong>8.5</strong> / 10", Path(result["report"]).read_text())
            state = app.load_json(root / "data/state.json", {})
            self.assertEqual(state["tasks"]["task/1"]["task"]["grade"], {"score": "8.5", "total": "10"})
            row["isSynchroToMobiled"] = 0
            self.assertEqual(app.sync(client, root, NOW.replace(minute=3))["grades"], 0)

    def test_submission_filter_state_updates_without_including_non_submissions(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, client = Path(tmp), FakeClient()
            row = client.rows[0]
            row.update(learningTaskState=2, isFirstSubmissionClosed=True)
            client.rows += [
                dict(row, id="submitted", learningTaskState="3", finishState=None),
                dict(row, id="graded", learningTaskState=4, finishState=1),
                dict(row, id="exempt", learningTaskState=4, finishState=6, isExempt=True),
                dict(row, id="confirm", mode=1),
                dict(row, id="unknown", learningTaskState=None, finishState=None,
                     scoreType=1, score=0, isSynchroToMobiled=1),
            ]
            report = Path(app.sync(client, root, NOW)["report"])
            html = report.read_text()
            self.assertEqual(html.count(' data-submission="submitted"'), 2)
            self.assertEqual(html.count(' data-submission="unsubmitted"'), 1)
            self.assertEqual(html.count(' data-submission=""'), 3)
            self.assertIn("未提交（已关闭）", html)

            row.update(learningTaskState=3, finishState=None, isFirstSubmissionClosed=False)
            app.sync(client, root, NOW.replace(minute=1))
            self.assertEqual(report.read_text().count(' data-submission="submitted"'), 3)
            self.assertNotIn(' data-submission="unsubmitted"', report.read_text())

    def test_record_filter_and_actual_homework_are_separate(self):
        row = {"typeName": "作业", "learningTaskState": 2}
        cases = [
            ("AD HW + Participation", "", "record"),
            ("期中考试成绩", "", "record"),
            ("复习资料", "仅供参考，无需提交。", "record"),
            ("期中考试订正", "重做错题并写下错因。", "assignment"),
            ("课堂参与练习", "请上传今天的练习。", "assignment"),
            ("第十三周", "", "uncertain"),
        ]
        for title, body, expected in cases:
            with self.subTest(title=title):
                self.assertEqual(task_metadata(row, {}, title, body)["kind"], expected)
        self.assertEqual(task_metadata(dict(row, mode=1), {}, "阅读", "")["kind"], "confirm")
        self.assertEqual(task_metadata(dict(row, isExempt=True), {}, "第十三周作业", "请提交")["kind"], "record")
        self.assertEqual(task_metadata(row, {}, "阅读 Part 1", "", [{"name": "Homework 1.pdf", "kind": "附件"}])["kind"], "assignment")
        self.assertEqual(published_grade({"scoreType": 2, "isSynchroToMobiled": 1, "levelString": "A+"}, {}),
                         {"level": "A+"})


if __name__ == "__main__":
    unittest.main()
