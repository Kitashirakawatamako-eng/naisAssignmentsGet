"""Read the same term, mapping, and assessment data as the student grades page."""
from decimal import Decimal, ROUND_HALF_UP
from datetime import datetime
import json
import math
from pathlib import Path

import school_tasks as school
from task_records import flag


DYNAMIC_FILE = "data/dynamic-grades.json"
DYNAMIC_STATUS_FILE = "data/dynamic-grades-status.json"
API = "/api/DynamicScore/"

TASK_TYPES = {
    "考勤": {"考勤"},
    "参与度": {"考勤"},
    "小测试": {"小测试", "课堂测试"},
    "课堂任务/家庭作业": {"课堂任务/家庭作业", "作业", "家庭作业", "假期作业", "当堂作业", "课堂练习"},
}


def number(value):
    if not isinstance(value, (int, float, str)) or isinstance(value, bool):
        return None
    try:
        result = float(value)
    except (ValueError, OverflowError):
        return None
    return result if math.isfinite(result) and abs(result) <= 1_000_000 else None


def mapping_ranges(mapping, show_points):
    ranges = []
    for item in mapping.get("scoreMappingConfigs") or []:
        minimum, maximum = number(item.get("minValue")), number(item.get("maxValue"))
        if minimum is None or maximum is None or minimum > maximum:
            continue
        ranges.append({
            "minimum": minimum, "maximum": maximum,
            "includes_minimum": flag(item.get("isContainMin")),
            "includes_maximum": flag(item.get("isContainMax")),
            "level": item.get("displayName") or "",
            "points": number(item.get("gpa")) if show_points else None,
        })
    return ranges


def match_range(percent, ranges):
    # The portal compares the percentage after toFixed(1), including each bound as configured.
    rounded = float(Decimal.from_float(percent).quantize(Decimal("0.1"), rounding=ROUND_HALF_UP))
    for item in reversed(ranges):
        above = rounded > item["minimum"] or (rounded == item["minimum"] and item["includes_minimum"])
        below = rounded < item["maximum"] or (rounded == item["maximum"] and item["includes_maximum"])
        if above and below:
            return item
    return {}


def categories(items, numeric):
    return [{
        "name": item.get("evaluationProjectName") or item.get("evaluationProjectEName") or "",
        "english_name": item.get("evaluationProjectEName") or "",
        "weight": number(item.get("proportion")),
        "score": number(item.get("score")) if numeric and not flag(item.get("scoreIsNull")) else None,
        "level": (item.get("scoreLevel") if numeric else item.get("levelString"))
        if not flag(item.get("scoreIsNull")) else None,
        "children": categories(item.get("evaluationProjectList") or [], numeric),
    } for item in items]


def semester_summary(client, semester_id, now):
    data = client.get(API + "GetStuSemesterDynamicScore", semesterId=semester_id)
    settings = client.get(API + "ListGpaSettings")
    archived = client.get(API + "IsStudentSemesterScoreStorage", semesterId=semester_id)
    gpa = client.get(API + "GetGpa", semesterId=semester_id)
    return normalize_summary(data, settings, archived, gpa, semester_id, now)


def normalize_summary(data, settings, archived, gpa, semester_id, now):
    if not isinstance(data, dict) or not isinstance(data.get("studentSemesterDynamicScoreBasicDtos"), list):
        raise school.SyncError("校宝动态成绩格式发生变化，已保留上次结果。")
    mappings = {
        str(mapping["scoresMappingId"]): mapping for mapping in data.get("scoreMappingList") or []
        if isinstance(mapping, dict) and mapping.get("scoresMappingId") is not None
    }
    courses = []
    seen = set()
    for row in data["studentSemesterDynamicScoreBasicDtos"]:
        class_id, subject_id = row["classId"], row["subjectId"]
        course_id = f"{class_id}:{subject_id}"
        if course_id in seen:
            continue
        seen.add(course_id)
        numeric = str(row.get("scoreType")) == "1"
        score = number(row.get("subjectScore")) if numeric else None
        total = number(row.get("subjectTotalScore")) if numeric else None
        percent = number(score / total * 100) if score is not None and total is not None and total > 0 else None
        mapping = mappings.get(str(row.get("scoreMappingId")), {})
        ranges = mapping_ranges(mapping, flag(row.get("isInGrade")) and flag(mapping.get("isUseGpa")))
        grade = match_range(percent, ranges) if percent is not None else {}
        courses.append({
            "id": course_id, "class_id": class_id, "subject_id": subject_id,
            "name": row.get("subjectName") or row.get("subjectEName") or "",
            "english_name": row.get("subjectEName") or "",
            "class_name": row.get("className") or row.get("classEName") or "",
            "score": score, "percent": percent, "numeric": numeric,
            "included_in_gpa": flag(row.get("isInGrade")) and flag(mapping.get("isUseGpa")),
            "level": grade.get("level") if numeric else row.get("levelString"),
            "points": grade.get("points"), "ranges": ranges,
        })
    return {
        "semester_id": str(semester_id), "checked_at": now.isoformat(), "gpa": number(gpa),
        "archived": flag(archived) and isinstance(settings, dict) and settings.get("useDynamicGPA") is False,
        "courses": courses,
    }


def course_categories(client, semester_id, course):
    data = client.get(API + "GetDynamicScoreDetail", semesterId=semester_id,
                      classId=course["class_id"], subjectId=course["subject_id"])
    return normalize_categories(data, course)


def normalize_categories(data, course):
    if not isinstance(data, dict) or not isinstance(data.get("evaluationProjectList"), list):
        raise school.SyncError("校宝课程评估项目暂时无法读取。")
    return categories(data["evaluationProjectList"], course["numeric"])


def add_count_estimates(dynamic, records):
    """Use only term-list rows and require a match to the course's own published category."""
    courses = dynamic["courses"]
    aliases = {}
    for course in courses:
        for name in {course["name"], course["english_name"]} - {""}:
            aliases.setdefault(name, []).append(course["id"])
    by_course = {}
    for row in records:
        matches = aliases.get(row["course"], [])
        score, total = number(row.get("score")), number(row.get("total"))
        if len(matches) == 1 and not row["exempt"] and score is not None and score >= 0 and total and total > 0:
            by_course.setdefault(matches[0], []).append((row["category"], score / total * 100))
    for course in courses:
        rows = by_course.get(course["id"], [])
        parts = course.get("categories", [])
        has_attendance = any(part["name"] == "考勤" for part in parts)
        for part in parts:
            name, score = part["name"], part["score"]
            if score is None or not 0 < score < 100 or part["children"] or (has_attendance and name == "参与度"):
                continue
            types = TASK_TYPES.get(name, {name})
            values = [value for kind, value in rows if kind in types]
            if values and abs(math.fsum(values) / len(values) - score) <= 0.0050001:
                part["estimated_count"] = len(values)


def read_dump(folder):
    folder = Path(folder)
    raw = folder / "raw" if (folder / "raw").is_dir() else folder

    def read(name, parent=raw):
        with (parent / name).open("rb") as handle:
            data = handle.read(16 * 1024 * 1024 + 1)
        if len(data) > 16 * 1024 * 1024:
            raise school.SyncError("校宝成绩采集文件过大。")
        return json.loads(data)

    semesters = read("GetSchoolSemesters.json")
    semester = next((item for item in semesters if flag(item.get("isNow"))), None)
    if semester is None:
        raise school.SyncError("采集文件没有标明当前学期。")
    captured = datetime.fromtimestamp((raw / "GetGpa.json").stat().st_mtime, school.TZ)
    manifest_dir = folder if raw != folder else folder.parent
    if (manifest_dir / "schoolis-dynamic-grades.json").is_file():
        manifest = read("schoolis-dynamic-grades.json", manifest_dir)
        source_time = manifest.get("checked_at") if isinstance(manifest, dict) else None
        if isinstance(source_time, str) and (parsed := school.due_date(source_time)) and (
            len(source_time) > 10 or parsed.date() != captured.date()
        ):
            captured = parsed
    dynamic = normalize_summary(read("GetStuSemesterDynamicScore.json"), read("ListGpaSettings.json"),
                                read("IsStudentSemesterScoreStorage.json"), read("GetGpa.json"),
                                semester["id"], captured)
    details = {}
    for path in sorted(raw.glob("detail_*_*_*.json")):
        _, class_id, subject_id, _ = path.name.split("_", 3)
        details.setdefault((class_id, subject_id), path.name)
    for course in dynamic["courses"]:
        name = details.get((str(course["class_id"]), str(course["subject_id"])))
        if name:
            course["categories"] = normalize_categories(read(name), course)
    dynamic["from_dump"] = True
    return semester, captured, dynamic, read("LearningTask_GetList.json")
