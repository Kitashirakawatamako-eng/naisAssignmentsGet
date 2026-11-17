"""Interpret the Schoolis task list and detail fields shown to students."""
from decimal import Decimal, InvalidOperation
import re


NO_SUBMISSION = re.compile(
    r"(?:不需要|无需|无须|不用|不必|不要求)(?:在\S{1,12})?(?:提交|上交|上传|交作业)"
    r"|仅供参考|仅作记录|只做记录|no submission (?:is )?(?:needed|required)"
    r"|(?:do not|don't) need to (?:submit|upload)|(?:not required to|do not|don't) (?:submit|upload)"
    r"|for (?:your )?reference only",
    re.I,
)
SUBMISSION = re.compile(
    r"提交|上交|上传|递交|交给|交作业|交纸质|纸质交|录音"
    r"|\b(?:submit|upload|turn in|hand in|send me)\b",
    re.I,
)
RECORD = re.compile(
    r"考勤|出勤|课堂(?:表现|参与)|成绩|得分记录|分数记录"
    r"|\b(?:attendance|participation|(?:exam|quiz|test|midterm|final)\s+(?:results?|scores?|marks?|grades?)|grade\s+record)\b",
    re.I,
)
REVIEW = re.compile(r"复习(?:资料|提纲)?|参考资料|\breview\b|\breference\s+materials?\b", re.I)
WORK = re.compile(
    r"完成|重做|订正|改错|解答|背诵|练习|写下|做(?:完|第|题)"
    r"|\b(?:rework|correction|correct the|complete|finish|write|answer|solve|questions?\s+\d|exercises?\s+\d)\b",
    re.I,
)
HOMEWORK = re.compile(r"家庭作业|作业|作文|练习|\b(?:homework|assignment|hw\s*\d*|worksheet|writing)\b", re.I)
EXAM = re.compile(r"考试|测验|小测|\b(?:exam|test|quiz|midterm|final exam)\b", re.I)


def field(row, detail, key):
    return row[key] if key in row else detail.get(key)


def flag(value):
    return value in (True, 1, "1")


def number(value):
    """Store decimal strings without rounding or ambiguous floating point display."""
    if value is None or isinstance(value, bool):
        return None
    try:
        result = Decimal(str(value))
        if result.is_finite() and -100 <= result.adjusted() <= 100:
            if not result:
                return "0"
            text = format(result, "f")
            return text.rstrip("0").rstrip(".") if "." in text else text
    except InvalidOperation:
        pass
    return None


def published_grade(row, detail):
    # The student UI displays task scores only when this publication flag is set.
    if not flag(field(row, detail, "isSynchroToMobiled")):
        return None
    score_type = field(row, detail, "scoreType")
    if score_type in (1, "1"):
        score = number(field(row, detail, "score"))
        total = number(field(row, detail, "totalScore"))
        if score is not None:
            return {"score": score, "total": total if total and Decimal(total) > 0 else None}
    if score_type in (2, "2"):
        level = field(row, detail, "levelString")
        if isinstance(level, str) and level.strip() not in ("", "-", "--", "—"):
            return {"level": level.strip()}
    return None


def task_metadata(row, detail, title, content, attachments=()):
    task_type = detail.get("learningTaskTypeName") or row.get("typeName") or row.get("typeEName") or ""
    submit_time = detail.get("stuCommitTime")
    submitted = isinstance(submit_time, str) and bool(submit_time) and not submit_time.startswith("0001-")
    state = field(row, detail, "learningTaskState")
    grade = published_grade(row, detail)
    label = f"{title} {task_type}"
    requirements = NO_SUBMISSION.sub("", content)
    if flag(field(row, detail, "isExempt")) or field(row, detail, "finishState") in (6, "6"):
        kind = "record"
    elif submitted or SUBMISSION.search(requirements):
        kind = "assignment"
    elif flag(field(row, detail, "mode")):
        # The portal's Lite mode has a “确认完成” button instead of a file submission.
        kind = "confirm"
    elif NO_SUBMISSION.search(content) or NO_SUBMISSION.search(label):
        kind = "record"
    elif WORK.search(content):
        kind = "assignment"
    elif RECORD.search(label) or REVIEW.search(label) or (grade and EXAM.search(label)):
        kind = "record"
    elif (HOMEWORK.search(title) or (HOMEWORK.search(task_type) and content)
          or any(HOMEWORK.search(item["name"]) for item in attachments if item.get("kind") != "正文链接")):
        kind = "assignment"
    else:
        kind = "uncertain"
    return {
        "task_type": task_type,
        "kind": kind,
        "submission_state": state,
        "submission_closed": flag(field(row, detail, "isFirstSubmissionClosed")),
        "grade": grade,
    }
