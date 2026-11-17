"""Prepare task summaries and render local daily reports."""
from __future__ import annotations

from datetime import datetime, timedelta
from functools import lru_cache
from html import escape
from pathlib import Path
import re
from string import Template
from urllib.parse import quote


SUBMISSION_STATES = {"2": "待提交", "3": "已提交", "4": "已批改", "5": "批改中"}
OPEN_STATES = {"待提交", "未完成", "状态未知"}
SUBJECT_NAMES = {"Advanced Math": "进阶数学"}
VIEW_LABELS = (("homework", "作业"), ("pending", "待办"), ("uncertain", "待确认"),
               ("records", "仅记录"), ("grades", "成绩"))
GREETING = re.compile(r"^(?:各位同学|亲爱的同学们|同学们|各位好|大家好|dear (?:all|students)|hello everyone)[：:，,\s]+", re.I)
TASK_WORDS = re.compile(
    r"第\s*\d|\d\s*(?:[题页篇段词字道份]|words?\b|questions?\b|pages?\b)"
    r"|完成|订正|重做|阅读|背诵|作答|解答|朗读|写|提交|上交|上传|录音|复习"
    r"|\b(?:read|write|finish|complete|solve|submit|upload|review|record|answer)\b",
    re.I,
)
FILLER = re.compile(r"^(?:谢谢[大家同学们]*|加油|祝大家.*|thank you|thanks|good luck)[！!。.]?$", re.I)


@lru_cache(maxsize=2)
def load_translator(model_dir):
    if not (model_dir / "model/model.bin").is_file():
        return None
    try:
        import ctranslate2
        import sentencepiece

        tokenizer = sentencepiece.SentencePieceProcessor(model_file=str(model_dir / "sentencepiece.model"))
        translator = ctranslate2.Translator(str(model_dir / "model"), device="cpu", intra_threads=2)
        return tokenizer, translator
    except (ImportError, OSError, RuntimeError, ValueError):
        return None


def mostly_english(text):
    english_words = len(re.findall(r"[a-zA-Z]{2,}", text))
    chinese_chars = len(re.findall(r"[\u3400-\u9fff]", text))
    return english_words >= 2 and english_words > chinese_chars / 2


@lru_cache(maxsize=512)
def translate_lines(model_dir, lines):
    model = load_translator(model_dir)
    if model is None:
        return lines, False
    tokenizer, translator = model
    indices = [index for index, line in enumerate(lines) if mostly_english(line)]
    if not indices:
        return lines, False
    try:
        tokens = tokenizer.encode([lines[index] for index in indices], out_type=str)
        results = translator.translate_batch(tokens, beam_size=4, replace_unknowns=True)
        output = list(lines)
        for index, result in zip(indices, results):
            # SentencePiece's whitespace marker can survive decoding as a literal glyph.
            translated = tokenizer.decode(result.hypotheses[0]).replace("\u2581", " ").strip()
            if re.search(r"[\u3400-\u9fff]", translated):
                numbers = re.findall(r"\d+(?:\.\d+)?", lines[index])
                translated_numbers = re.findall(r"\d+(?:\.\d+)?", translated)
                if any(number not in translated_numbers for number in numbers):
                    translated = f"{translated}（题号或数字请核对原句：{lines[index]}）"
                output[index] = translated
        return tuple(output), tuple(output) != lines
    except (RuntimeError, ValueError):
        return lines, False


def action_lines(content):
    lines = re.split(r"\n+|[；;]\s*|(?<=[。！？!?])\s*|(?<=\.)\s+(?=[A-Z0-9])", content)
    return tuple(re.sub(r"^\s*(?:[-•]|\d{1,2}[.)](?!\d))\s*", "", line).strip()
                 for line in lines if line.strip())


def task_status(task):
    status = task.get("status") or "状态未知"
    if status == "状态未知":
        state = str(task.get("submission_state"))
        if state == "2" and task.get("kind") == "confirm":
            return "待确认完成"
        return SUBMISSION_STATES.get(state, status)
    return status


def submission_bucket(task):
    if task.get("kind") != "assignment":
        return ""
    state = str(task.get("submission_state"))
    if state in ("3", "4", "5"):
        return "submitted"
    if state == "2":
        return "unsubmitted"
    status = task_status(task)
    if status in ("按时完成", "延迟完成", "抄袭"):
        return "submitted"
    if status == "未完成":
        return "unsubmitted"
    return ""


def describe(task, note, model_dir):
    content = task.get("content") or ""
    title = note.get("title") or task["title"].strip()
    if note.get("actions"):
        return title, note["actions"], note.get("submit"), False
    if not content:
        if task.get("detail_pending"):
            action = "任务已找到，学校详情暂未读到。可在学校网站查看。"
        elif task.get("external"):
            action = "打开学校网站中的课程页面查看任务要求。"
        elif task["attachments"]:
            action = "老师没有填写正文，请打开下方附件查看题目或要求。"
        elif task.get("kind") == "record":
            action = "学校发布的记录，无需在这里提交作业。"
        else:
            action = "老师只填写了任务标题，具体要求请查看课堂记录或向老师确认。"
        return title, [action], None, False
    original_lines = action_lines(content)
    lines, translated = translate_lines(model_dir, original_lines)
    actions, submission = [], []
    for line in lines:
        if re.match(r"^(?:请\s*)?(?:提交|上交|上传|递交|交给|交作业)", line):
            submission.append(line)
        else:
            actions.append(line)
    if not actions:
        actions = ["按下方的提交要求完成。"]
    return title, actions, " ".join(submission), translated


def task_brief(task, note, title, actions, submission):
    if note.get("brief"):
        return note["brief"]
    if not (task.get("content") or note.get("actions")):
        files = [item["name"] for item in task["attachments"] if item.get("kind") != "正文链接"]
        if files:
            filename = next((name for name in files if re.search(r"homework|worksheet|作业|练习", name, re.I)), files[0])
            return f"{title} · 见附件 {filename}"
        return title

    def clean(line):
        _, marker, original = line.partition("（题号或数字请核对原句：")
        if marker:
            line = original.removesuffix("）")
        return GREETING.sub("", " ".join(line.split())).strip(" 。；;")

    lines = [clean(line) for line in actions]
    lines = [line for line in lines if line and not FILLER.fullmatch(line)
             and line != "按下方的提交要求完成"]
    key = [line for line in lines if TASK_WORDS.search(line)]
    parts = list(dict.fromkeys((key or lines)[:2]))
    if submission and (submit := clean(submission)) and not any(submit in line for line in parts):
        parts.append(submit)
    brief = "；".join(parts)
    if len(brief) > 112:
        brief = brief[:109].rstrip(" ，,；;") + "…"
    return brief or title


def task_summary(task, note, model_dir):
    attachment_urls = {item.get("url") for item in task["attachments"]}
    if note.get("content") != task.get("content") or (
        note.get("source_url") and note["source_url"] not in attachment_urls
    ):
        note = {}
    title, actions, submission, translated = describe(task, note, model_dir)
    brief = task_brief(task, note, title, actions, submission)
    if task.get("kind") == "confirm":
        submission = "在学校网站点「确认完成」。"
    return title, brief, actions, submission, translated


def display_status(task, current):
    category = task.get("kind", "uncertain")
    status = task_status(task)
    if not current:
        return "已归档"
    if category == "record":
        return "免交" if status == "免交" else "仅记录"
    if category == "uncertain":
        return "待确认"
    bucket = submission_bucket(task)
    if bucket == "unsubmitted":
        return "未提交（已关闭）" if task.get("submission_closed") else "未提交"
    if bucket == "submitted":
        return status if status in ("已批改", "批改中", "延迟完成", "抄袭") else "已提交"
    return "提交已关闭" if task.get("submission_closed") else status


def date_text(value, now):
    if value.date() == now.date():
        return f"今天 {value:%H:%M}"
    if value.date() == now.date() + timedelta(days=1):
        return f"明天 {value:%H:%M}"
    return value.strftime("%m月%d日 %H:%M")


def grade_text(grade):
    if not grade:
        return "—"
    if "level" in grade:
        return f"<strong>{escape(grade['level'])}</strong>"
    total = f" / {escape(grade['total'])}" if grade.get("total") else " 分"
    return f"<strong>{escape(grade['score'])}</strong>{total}"


def file_links(attachments):
    links = []
    for item in attachments:
        name = escape(item["name"])
        original, local = item.get("url"), item.get("local_path")
        status = item.get("download_status")
        if local:
            label = f'<a href="../{quote(local)}">{name}</a>'
            if original:
                label += f' <a class="origin-link" href="{escape(original)}">原始链接</a>'
        elif original:
            label = f'<a href="{escape(original)}">{name}</a>'
            if status and status != "保留链接":
                label += f' <span class="secondary">{escape(status)}</span>'
        else:
            label = name + ' <span class="secondary">未提供链接</span>'
        links.append(f"<li>{label}</li>")
    return (f'<section class="detail-block"><h3>附件与链接</h3>'
            f'<ul class="task-attachments">{"".join(links)}</ul></section>') if links else ""


def pending(task):
    return (task.get("kind") in ("assignment", "confirm")
            and task_status(task) in OPEN_STATES | {"待确认完成"}
            and not (task.get("grade") or task.get("submission_closed")))


@lru_cache(maxsize=1)
def report_template():
    return Template(Path(__file__).with_name("report_template.html").read_text())


def filter_choice(group, value, label, checked=False):
    selected = " checked" if checked else ""
    return (f'<label class="filter-choice"><input type="checkbox" name="{group}"'
            f' value="{escape(value)}"{selected}>{escape(label)}</label>')


def render_html(day, daily_tasks, current_tasks, now, notes, model_dir, parse_date, school_url, first_seen=None):
    today = {task["id"]: task for task in daily_tasks}
    current = {task["id"]: task for task in current_tasks}
    tasks = today | current
    subjects = {}
    first_seen = first_seen or {}
    today_homework = 0

    def deadline(task):
        return parse_date(task.get("due"))

    def priority(task):
        due = deadline(task)
        is_pending = task["id"] in current and pending(task)
        return (not is_pending, bool(due and due < now), due or datetime.max.replace(tzinfo=now.tzinfo))

    rows = []
    for task in sorted(tasks.values(), key=priority):
        ident = task["id"]
        category = task.get("kind", "uncertain")
        is_homework = category in ("assignment", "confirm")
        is_pending = ident in current and pending(task)
        bucket = submission_bucket(task)
        grade = task.get("grade")
        raw_subject = task["subject"]
        subject = SUBJECT_NAMES.get(raw_subject, raw_subject)
        subjects[raw_subject] = subject
        title, brief, actions, submission, translated = task_summary(task, notes.get(ident, {}), model_dir)
        due = deadline(task)
        assigned = (parse_date(task.get("published")) or parse_date(task.get("started"))
                    or parse_date(first_seen.get(ident)))
        age = (now.date() - assigned.date()).days if assigned else None
        show_today = is_homework and age == 0
        today_homework += show_today
        short_date = assigned.strftime("%m/%d") if assigned else "—"
        when = date_text(due, now) if due else "未注明"
        when_class = ""
        if is_pending and due:
            if due < now:
                when_class = "deadline-alert"
                when = "逾期 · " + when
            elif due.date() == now.date():
                when_class = "deadline-soon"
        if category == "record":
            when = short_date
        when_html = (
            f'<time class="due-when {when_class}" datetime="{due.isoformat(timespec="minutes")}">{when}</time>'
            if due and category != "record" else f'<span class="due-when">{when}</span>'
        )
        status = display_status(task, ident in current)
        actions_html = "".join(f"<li>{escape(step)}</li>" for step in actions)
        submit_html = (
            f'<section class="detail-block"><h3>怎么交</h3><p class="submission-note">{escape(submission)}</p></section>'
            if submission else ""
        )
        origin = escape(task.get("content") or "老师未填写正文。")
        translation_note = "（含本机译文）" if translated else ""
        detail_notice = '<p class="secondary detail-block">学校详情暂未更新。</p>' if task.get("detail_pending") and task.get("content") else ""
        search = " ".join((brief, title, task["title"], subject, raw_subject, task.get("task_type", ""))).lower()
        row_hidden = "" if show_today else " hidden"
        sort_date = assigned.date().isoformat() if assigned else ""
        rows.append(
            f'<details class="task" data-pending="{int(is_pending)}" data-kind="{category}"'
            f' data-grade="{int(bool(grade))}" data-homework="{int(is_homework)}"'
            f' data-submission="{bucket}"'
            f' data-subject="{escape(raw_subject)}" data-search="{escape(search)}" data-date="{sort_date}"'
            f' data-age="{age if age is not None else ""}"{row_hidden}>'
            '<summary class="task-row">'
            f'<span class="task-name"><span class="task-sub"><span class="task-course">{escape(subject)}</span>'
            f' <span class="row-status">· {escape(status)}</span></span>'
            f'<span class="task-brief">{escape(brief)}</span></span>'
            f'<span class="task-when">{when_html}'
            f'<span class="record-when">{short_date}</span></span>'
            f'<span class="task-grade">{grade_text(grade)}</span><span class="arrow" aria-hidden="true"></span>'
            '</summary><div class="task-body">'
            f'<h3 class="detail-title">{escape(title)}{translation_note}</h3>'
            f'<section class="detail-block"><ul>{actions_html}</ul></section>'
            f'{submit_html}{file_links(task["attachments"])}{detail_notice}'
            f'<details class="source"><summary>老师原文</summary><p>{escape(task["title"])}</p><p>{origin}</p></details>'
            '</div></details>'
        )
    views = "".join(filter_choice("view", key, label, checked=key == "homework") for key, label in VIEW_LABELS)
    options = "".join(filter_choice("course", name, label)
                      for name, label in sorted(subjects.items(), key=lambda item: item[1]))
    weekdays = ("星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日")
    return report_template().substitute(
        day=day,
        day_label=f"{now.month}月{now.day}日 · {weekdays[now.weekday()]}",
        checked_iso=now.isoformat(),
        checked_time=f"{now:%H:%M}",
        school_url=escape(school_url),
        views=views,
        subjects=options,
        rows="".join(rows),
        empty_hidden=" hidden" if today_homework else "",
    )
