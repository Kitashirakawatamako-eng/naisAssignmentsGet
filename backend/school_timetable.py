"""Read lessons from the student's Schoolis calendar."""
from datetime import timedelta
import hashlib

from school_tasks import BASE, SyncError, due_date, unwrap
from task_report import SUBJECT_NAMES

TIMETABLE_FILE = "data/timetable.json"
REFRESH_SECONDS = 30 * 60


def label(*values):
    return next((value.strip() for value in values if isinstance(value, str) and value.strip()), None)


def week_start(day):
    return day - timedelta(days=day.weekday())


def read_timetable(client, now):
    start = week_start(now.date())
    end = start + timedelta(days=13)
    response = client._json_request(
        "/api/Schedule/ListScheduleByParent", {},
        body={"beginTime": start.isoformat(), "endTime": end.isoformat()},
        referer=BASE + "/Home", retry_read=True,
    )
    events = unwrap(response)
    if not isinstance(events, list) or any(not isinstance(item, dict) or "scheduleType" not in item for item in events):
        raise SyncError("学校课表格式暂时无法读取。")

    courses = {}
    for event in events:
        kind = str(event["scheduleType"])
        if kind not in ("3", "4") or event.get("isAllDay") in (True, "true", "1"):
            continue
        begins = due_date(event.get("beginTime"))
        ends = due_date(event.get("endTime"))
        title = label(event.get("name"), event.get("eName"))
        if not title or not begins or not ends or begins >= ends:
            raise SyncError("学校课表中有课程缺少有效的名称或时间。")
        if not start <= begins.date() <= end:
            continue
        room = label(event.get("playgroundName"), event.get("playgroundEName"))
        teachers = [label(teacher.get("name"), teacher.get("eName"))
                    for teacher in (event.get("teacherList") or []) if isinstance(teacher, dict)]
        teacher = "、".join(dict.fromkeys(name for name in teachers if name)) or label(event.get("teacherName"))
        start_at = begins.isoformat(timespec="seconds")
        end_at = ends.isoformat(timespec="seconds")
        key = (title, start_at, end_at, room)
        course = courses.get(key)
        if course is not None and kind == "3":
            continue
        courses[key] = {
            "id": hashlib.sha256(repr(key).encode()).hexdigest()[:24],
            "title": SUBJECT_NAMES.get(title, title),
            "start_at": start_at,
            "end_at": end_at,
            "room": room,
            "teacher": teacher,
            "temporary": kind == "4",
        }
    return {
        "checked_at": now.isoformat(timespec="seconds"),
        "start_day": start.isoformat(),
        "end_day": end.isoformat(),
        "courses": sorted(courses.values(), key=lambda item: (item["start_at"], item["end_at"], item["title"])),
    }
