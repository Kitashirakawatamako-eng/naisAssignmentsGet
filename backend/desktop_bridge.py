"""Local JSON pipe between the Mac app and the existing school sync engine."""
from datetime import datetime, timedelta
import json
import os
import sys
import time

import school_tasks as school
from school_timetable import REFRESH_SECONDS, TIMETABLE_FILE, read_timetable, week_start
from task_report import SUBJECT_NAMES, display_status, pending, submission_bucket, task_summary


def grade_label(grade):
    if not grade:
        return None
    if "level" in grade:
        return grade["level"]
    return f"{grade['score']} / {grade['total']}" if grade.get("total") else f"{grade['score']} 分"


def snapshot(root):
    latest = school.load_json(root / "reports/latest.json", {})
    checked_at = school.due_date(latest.get("checked_at"))
    daily = school.load_json(root / "data/report-days" / f"{checked_at:%Y-%m-%d}.json", {}) if checked_at else {}
    current = {task["id"]: task for task in latest.get("tasks", [])}
    notes = school.load_json(root / "data/任务中文备注.json", {})
    state = school.load_json(root / "data/state.json", {}).get("tasks", {})
    model_dir = school.translation_model(root)
    cards = []
    for ident, task in (daily | current).items():
        course = task["subject"]
        title, brief, actions, submission, translated = task_summary(
            task, notes.get(ident, {}), model_dir
        )
        assigned = school.due_date(task.get("published")) or school.due_date(task.get("started"))
        if not assigned:
            assigned = school.due_date(state.get(ident, {}).get("first_seen"))
        due = school.due_date(task.get("due"))
        cards.append({
            "id": ident, "course": course, "subject": SUBJECT_NAMES.get(course, course),
            "title": title, "brief": brief, "actions": actions, "submission": submission or None,
            "translated": translated, "original_title": task["title"], "original": task.get("content") or "",
            "detail_pending": bool(task.get("detail_pending")),
            "kind": task.get("kind", "uncertain"), "status": display_status(task, ident in current),
            "submission_bucket": submission_bucket(task), "pending": ident in current and pending(task),
            "grade": grade_label(task.get("grade")),
            "assigned_day": assigned.date().isoformat() if assigned else None,
            "due": due.isoformat(timespec="seconds") if due else None,
            "attachments": task["attachments"],
            "task_type": task.get("task_type") or "",
        })
    status = school.load_json(root / "data/status.json", {})
    settings = school.load_json(root / ".private/auto-login.json", {})
    return {
        "checked_at": checked_at.isoformat(timespec="seconds") if checked_at else None,
        "tasks": cards,
        "warning_count": len(latest.get("warnings", [])),
        "auto_login": settings.get("enabled") is True,
        "has_session": (root / ".private/session.json").is_file(),
        "sync_error": desktop_error(status.get("error")),
        "retry_at": status.get("retry_at"),
        "requires_login": bool(status.get("requires_login")),
        "timetable": school.load_json(root / TIMETABLE_FILE, None),
    }


def desktop_error(message):
    if message and ".command" in message:
        if "验证" in message:
            return "学校要求验证。请在设置中打开学校登录窗口。"
        return "学校会话已过期。请在设置中更新登录。"
    return message


def emit(event, **data):
    print(json.dumps({"event": event, **data}, ensure_ascii=False), flush=True)


class DesktopBackend:
    def __init__(self):
        self.root = school.ROOT
        self.session = school.SyncSession()
        self.worker = school.AttachmentWorker()
        self.cached_stamp = None
        self.next_check = 0.0
        self.rate_limit_until = 0.0
        self.failures = 0
        self.login_block = None
        self.next_timetable = 0.0
        self.timetable_login_block = None
        self.timetable_failures = 0
        now = datetime.now(school.TZ)
        try:
            status = school.load_json(self.root / "data/status.json", {})
        except (OSError, ValueError):
            status = {}
        if isinstance(status, dict) and (retry_at := school.due_date(status.get("retry_at"))):
            self.failures = 1
            self.next_check = time.monotonic() + max(0, (retry_at - now).total_seconds())
            if status.get("server_wait"):
                self.rate_limit_until = self.next_check
        try:
            timetable = school.load_json(self.root / TIMETABLE_FILE, {})
        except (OSError, ValueError):
            timetable = {}
        if isinstance(timetable, dict):
            checked = school.due_date(timetable.get("checked_at"))
            if checked and timetable.get("start_day") == week_start(now.date()).isoformat():
                age = (now - checked).total_seconds()
                if 0 <= age < REFRESH_SECONDS:
                    self.next_timetable = time.monotonic() + REFRESH_SECONDS - age

    def update_snapshot(self):
        paths = ("reports/latest.json", "data/status.json", "data/state.json",
                 "data/任务中文备注.json", ".private/session.json", ".private/auto-login.json", TIMETABLE_FILE)
        stamp = []
        for name in paths:
            try:
                stat = (self.root / name).stat()
                stamp.append((stat.st_ino, stat.st_mtime_ns))
            except FileNotFoundError:
                stamp.append(None)
        if stamp != self.cached_stamp:
            emit("snapshot", data=snapshot(self.root))
            self.cached_stamp = stamp

    def should_poll(self, now):
        if not school.check_slot(now) or time.monotonic() < max(self.next_check, self.rate_limit_until):
            return False
        return self.login_block is None or self.login_block != (school.session_stamp(),)

    def timetable_due(self):
        if time.monotonic() < max(self.next_timetable, self.rate_limit_until):
            return False
        return self.timetable_login_block != (school.session_stamp(),)

    def wait_for_server(self, exc):
        cached_until = self.session.client.rate_limit_until if self.session.client else 0.0
        self.rate_limit_until = max(self.rate_limit_until, cached_until, time.monotonic() + exc.retry_after)

    def synchronize_timetable(self, now):
        started = time.monotonic()
        if started < self.rate_limit_until:
            raise school.RateLimited(self.rate_limit_until - started)
        emit("working", operation="timetable")
        try:
            client = self.session.client
            if client is not None and client.auth_stamp != school.session_stamp():
                client = None
            data = school.check_with_login(lambda active: read_timetable(active, now), client)
            school.save_json(self.root / TIMETABLE_FILE, data)
        except school.LoginRequired:
            self.timetable_login_block = (school.session_stamp(),)
            raise
        except school.RateLimited as exc:
            self.wait_for_server(exc)
            self.next_timetable = self.rate_limit_until
            raise
        except school.TemporarySyncError:
            self.timetable_failures += 1
            self.next_timetable = time.monotonic() + school.recovery_delay(self.timetable_failures)
            raise
        except (school.SyncError, OSError, ValueError):
            self.next_timetable = time.monotonic() + 5 * 60
            raise
        else:
            self.timetable_login_block = None
            self.timetable_failures = 0
            self.next_timetable = time.monotonic() + REFRESH_SECONDS

    def synchronize(self, now, *, manual):
        started = time.monotonic()
        if started < self.rate_limit_until:
            raise school.RateLimited(self.rate_limit_until - started)
        self.next_check = started + school.POLL_SECONDS
        emit("working", operation="sync")
        try:
            self.session.run(now, downloads_worker=self.worker, refresh_details=manual, write_html=False)
        except school.SyncBusy:
            self.next_check = started + 5
            if manual:
                raise
        except school.LoginRequired as exc:
            self.login_block = (school.session_stamp(),)
            school.record_failure(exc)
            raise
        except (school.SyncError, OSError, ValueError) as exc:
            self.failures += 1
            if isinstance(exc, school.RateLimited):
                self.wait_for_server(exc)
                self.next_check = self.rate_limit_until
            elif isinstance(exc, school.TemporarySyncError):
                self.next_check = time.monotonic() + school.recovery_delay(self.failures)
            else:
                self.next_check = time.monotonic() + min(900, school.POLL_SECONDS * 2 ** min(self.failures - 1, 4))
            retry_at = None
            if isinstance(exc, (school.TemporarySyncError, school.RateLimited)):
                remaining = max(0, self.next_check - time.monotonic())
                retry_at = datetime.now(school.TZ) + timedelta(seconds=remaining + 1)
            school.record_failure(exc, retry_at=retry_at)
            raise
        else:
            self.failures = 0
            self.login_block = None

    def handle(self, request):
        action = request.get("action")
        operation = action
        now = datetime.now(school.TZ)
        error = None
        requires_login = False
        try:
            if action == "poll":
                self.update_snapshot()
                if request.get("automatic"):
                    timetable_due = self.timetable_due()
                    if self.should_poll(now) and (self.failures or not timetable_due):
                        operation = "sync"
                        try:
                            with school.lock(self.root, "watch"):
                                self.synchronize(now, manual=False)
                        except school.SyncBusy:
                            self.next_check = time.monotonic() + 5
                    elif timetable_due:
                        operation = "timetable"
                        self.synchronize_timetable(now)
            elif action == "sync":
                self.synchronize(now, manual=True)
            elif action == "timetable":
                self.synchronize_timetable(now)
            elif action == "configure":
                emit("working", operation="configure")
                school.configure_auto_login(request["name"], request.pop("password"))
                self.next_timetable = 0.0
            elif action == "verify":
                emit("working", operation="verify")
                school.accept_browser_session(request.pop("cookies", []))
                self.next_timetable = 0.0
        except school.SyncError as exc:
            error = desktop_error(str(exc))
            requires_login = isinstance(exc, school.LoginRequired)
        except ImportError:
            error = "本地运行组件缺失，请重新运行安装。"
        except (OSError, ValueError, KeyError):
            error = "本地数据或同步环境暂时无法读取。"
        finally:
            try:
                self.update_snapshot()
            except (OSError, ValueError, KeyError):
                error = error or "暂时无法读取本地作业记录。"
            emit("finished", operation=operation, error=error, requires_login=requires_login)


def main():
    os.umask(0o077)
    if sys.argv[1:] == ["--snapshot"]:
        print(json.dumps(snapshot(school.ROOT), ensure_ascii=False))
        return
    backend = DesktopBackend()
    for line in sys.stdin:
        try:
            request = json.loads(line)
            if isinstance(request, dict):
                backend.handle(request)
        except (UnicodeError, ValueError):
            emit("finished", operation="unknown", error="应用请求格式异常。")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
