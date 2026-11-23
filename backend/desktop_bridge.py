"""Local JSON pipe between the Mac app and the existing school sync engine."""
from datetime import datetime, timedelta
import json
import os
import sys
import time

import school_tasks as school
from school_timetable import REFRESH_SECONDS, TIMETABLE_FILE, load_timetable, read_timetable, week_start
from task_report import SUBJECT_NAMES, display_status, pending, submission_bucket, task_summary
from task_records import flag, number, published_grade

GRADE_FILE = "data/semester-grades.json"
GRADE_STATUS_FILE = "data/semester-grades-status.json"


def grade_label(grade):
    if not grade:
        return None
    if "level" in grade:
        return grade["level"]
    return f"{grade['score']} / {grade['total']}" if grade.get("total") else f"{grade['score']} 分"


def semester_grades(client, now):
    semester = school.get_semester(client)
    start = school.due_date(semester.get("startDate"))
    end = school.due_date(semester.get("endDate"))
    if start is None or end is None or not start.date() <= now.date() <= end.date():
        raise school.SyncError("学校未提供可核对的当前学期日期，已保留上次成绩。")
    rows = school.collect_term_rows(client, semester, start.date().isoformat(), end.date().isoformat())
    records = []
    for row in rows:
        if not flag(row.get("isSynchroToMobiled")):
            continue
        grade = published_grade(row, {}) or {}
        course = row.get("subjectName") or row.get("subjectEName") or "未标明科目"
        day = school.due_date(row.get("beginTime"))
        if day and not start.date() <= day.date() <= end.date():
            continue
        records.append({"id": str(row["id"]), "course": course, "title": row.get("name") or "未命名任务",
                        "day": day.date().isoformat() if day else None,
                        "category": row.get("typeName") or row.get("typeEName") or "",
                        "exempt": flag(row.get("isExempt")) or row.get("finishState") in (6, "6"), **grade})
    summary = client.get("/api/DynamicScore/GetStuSemesterDynamicScore", semesterId=semester["id"])
    published = summary["studentSemesterDynamicScoreBasicDtos"]
    course_scores = []
    for row in published:
        subject = row.get("subjectName") or row.get("subjectEName")
        score = number(row.get("subjectScore")) if row.get("scoreType") == 1 else row.get("levelString")
        if subject and score is not None:
            course_scores.append({"course": subject, "subject": row.get("subjectEName") or subject, "value": str(score)})
    gpa = number(client.get("/api/DynamicScore/GetGpa", semesterId=semester["id"])) if published else None
    return {"semester_id": str(semester["id"]), "start_day": start.date().isoformat(),
            "end_day": end.date().isoformat(), "checked_at": now.isoformat(), "records": records,
            "source_published_count": len(records), "school_gpa": gpa, "school_scores": course_scores}


def grade_snapshot(root, state, subjects):
    try:
        imported = school.load_json(root / GRADE_FILE, {})
    except (OSError, ValueError):
        imported = {}
    if not isinstance(imported, dict):
        imported = {}
    local_semester = state.get("semester_id")
    external_at = school.due_date(imported.get("checked_at"))
    local_at = school.due_date(state.get("last_success"))
    other_semester = local_semester is not None and imported.get("semester_id") != str(local_semester)
    if other_semester and (external_at is None or (local_at and local_at > external_at)):
        imported = {}
    history = imported.get("records", [])
    if not isinstance(history, list) or any(
        not isinstance(record, dict) or
        not all(isinstance(record.get(key), str) for key in ("id", "course", "title", "category")) or
        not isinstance(record.get("exempt"), bool) or
        any(record.get(key) is not None and not isinstance(record[key], str) for key in ("day", "score", "total", "level"))
        for record in history
    ):
        imported = {}
        history = []
    merge_local = not (imported and other_semester)
    lower = imported.get("start_day") or state.get("semester_start")
    upper = imported.get("end_day") or state.get("semester_end")
    imported_at = school.due_date(imported.get("checked_at"))
    cached = {record["id"]: record for record in history}
    for ident, entry in (state.get("tasks", {}) if merge_local else {}).items():
        task = entry.get("task") or {}
        day = school.due_date(task.get("published")) or school.due_date(task.get("started"))
        day = day.date().isoformat() if day else None
        if day and ((lower and day < lower) or (upper and day > upper)):
            continue
        grade = task.get("grade")
        last_seen = school.due_date(entry.get("last_seen") or entry.get("first_seen"))
        if ident in cached and imported_at and (not last_seen or last_seen < imported_at):
            continue
        if not grade:
            cached.pop(ident, None)
            continue
        cached[ident] = {"id": ident, "course": task["subject"], "title": task["title"], "day": day,
                         "category": task.get("task_type") or "", "exempt": task.get("status") == "免交", **grade}
    records = [dict(record, subject=subjects.get(record["course"], record["course"])) for record in cached.values()]
    try:
        status = school.load_json(root / GRADE_STATUS_FILE, {})
    except (OSError, ValueError):
        status = {}
    if not isinstance(status, dict):
        status = {}
    return {"semester_id": imported.get("semester_id") or (str(local_semester) if local_semester is not None else None),
            "start_day": lower, "end_day": upper, "checked_at": imported.get("checked_at"),
            "last_attempt_at": status.get("attempted_at"), "sync_issue": status.get("error"),
            "school_gpa": imported.get("school_gpa"), "school_scores": imported.get("school_scores", []),
            "source_published_count": imported.get("source_published_count"),
            "records": sorted(records, key=lambda x: (x.get("day") or "", x["id"]), reverse=True)}


def snapshot(root, model_dir=None):
    latest = school.load_latest_report(root)
    checked_at = school.due_date(latest.get("checked_at"))
    daily = school.load_json(root / "data/report-days" / f"{checked_at:%Y-%m-%d}.json", {}) if checked_at else {}
    current = {task["id"]: task for task in latest.get("tasks", [])}
    notes = school.load_json(root / "data/任务中文备注.json", {})
    archive = school.load_json(root / "data/state.json", {})
    state = archive.get("tasks", {})
    model_dir = model_dir or school.translation_model(root)
    subjects = ({value: key for key, value in SUBJECT_NAMES.items()} if model_dir.name == "zh-en" else SUBJECT_NAMES)
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
            "id": ident, "course": course, "subject": subjects.get(course, course),
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
    timetable = load_timetable(root)
    if timetable is not None:
        timetable["courses"] = [dict(course, title=subjects.get(course["title"], course["title"]))
                                for course in timetable["courses"]]
    return {
        "checked_at": checked_at.isoformat(timespec="seconds") if checked_at else None,
        "tasks": cards,
        "warning_count": len(latest.get("warnings", [])),
        "auto_login": settings.get("enabled") is True,
        "has_session": (root / ".private/session.json").is_file(),
        "sync_error": desktop_error(status.get("error")),
        "retry_at": status.get("retry_at"),
        "requires_login": bool(status.get("requires_login")),
        "timetable": timetable,
        "grade_book": grade_snapshot(root, archive, subjects),
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
        self.model_dir = school.translation_model(self.root)
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
        timetable = load_timetable(self.root)
        if timetable is not None:
            checked = school.due_date(timetable.get("checked_at"))
            if checked and timetable.get("start_day") == week_start(now.date()).isoformat():
                age = (now - checked).total_seconds()
                if 0 <= age < REFRESH_SECONDS:
                    self.next_timetable = time.monotonic() + REFRESH_SECONDS - age

    def update_snapshot(self):
        paths = ("reports/latest.json", "data/status.json", "data/state.json",
                 "data/任务中文备注.json", ".private/session.json", ".private/auto-login.json", TIMETABLE_FILE,
                 GRADE_FILE, GRADE_STATUS_FILE)
        stamp = [self.model_dir]
        for name in paths:
            try:
                stat = (self.root / name).stat()
                stamp.append((stat.st_ino, stat.st_mtime_ns))
            except FileNotFoundError:
                stamp.append(None)
        if stamp != self.cached_stamp:
            emit("snapshot", data=snapshot(self.root, self.model_dir))
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
                language = request.get("language")
                if language in ("en", "zh-Hans"):
                    self.model_dir = self.model_dir.with_name("zh-en" if language == "en" else "en-zh")
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
            elif action == "grades":
                started = time.monotonic()
                if started < self.rate_limit_until:
                    raise school.RateLimited(self.rate_limit_until - started)
                emit("working", operation="grades")
                try:
                    grades = school.check_with_login(lambda client: semester_grades(client, now))
                    school.save_json(self.root / GRADE_FILE, grades)
                except school.RateLimited as exc:
                    self.wait_for_server(exc)
                    raise
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
            if operation == "grades":
                try:
                    school.save_json(self.root / GRADE_STATUS_FILE, {"attempted_at": now.isoformat(), "error": error})
                except OSError:
                    error = error or "无法写入成绩同步状态。"
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
