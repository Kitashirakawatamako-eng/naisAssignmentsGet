#!/usr/bin/env python3
"""Schoolis read-only task sync. No passwords or credentials in logs."""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
import fcntl
import hashlib
from html.parser import HTMLParser
import http.cookiejar
import http.client
import json
import os
from pathlib import Path
from queue import Full, Queue
import re
import sys
import tempfile
from threading import Lock, Thread
import time
import urllib.error
import urllib.parse
import urllib.request
from zoneinfo import ZoneInfo

from school_keychain import KeychainError, read_credential, save_credential
from task_report import render_html
from task_records import task_metadata

DEFAULT_HOME = Path.home() / "Library/Application Support/作业速览"
ROOT = Path(os.environ.get("SP_ASSIGNMENTS_HOME") or DEFAULT_HOME).resolve()
BASE = "https://naisstu.schoolis.cn"
URL = BASE + "/Home#!/task/list/"
LOGIN_URL = BASE + "/login"
TZ = ZoneInfo("Asia/Shanghai")
AUTH = ROOT / ".private/session.json"
AUTO_LOGIN = AUTH.with_name("auto-login.json")
STATUS = {1: "按时完成", 2: "未完成", 3: "延迟完成", 4: "抄袭", 5: "按时完成", 6: "免交"}
PAGE_SIZE = 12  # Match the student portal's usual request size.
POLL_SECONDS = 60
DETAIL_RECHECK = timedelta(minutes=30)
SEMESTER_RECHECK_SECONDS = 1800
RETRYABLE_READ = (urllib.error.URLError, OSError, http.client.HTTPException)
FILE_EXTENSIONS = {".pdf", ".doc", ".docx", ".ppt", ".pptx", ".xls", ".xlsx",
                   ".zip", ".rar", ".7z", ".txt", ".csv", ".png", ".jpg", ".jpeg",
                   ".gif", ".webp", ".mp3", ".mp4", ".m4a", ".mov", ".wav"}
HTTP_LINK = re.compile(r"""(?:https?://|(?<!:)//)[^\s<>"'，。；、！？（）「」]+""", re.IGNORECASE)


def translation_model(root):
    bundled = os.environ.get("SP_ASSIGNMENTS_MODEL_DIR")
    return Path(bundled) if bundled else root / ".models/en-zh"


class SyncError(Exception):
    pass


class LoginRequired(SyncError):
    pass


class CredentialRejected(LoginRequired):
    pass


class SyncBusy(SyncError):
    pass


class RateLimited(SyncError):
    def __init__(self, retry_after):
        super().__init__("学校网站暂时限制检查频率，稍后会重试。")
        self.retry_after = retry_after


class AttachmentTooLarge(SyncError):
    pass


def retry_delay(header):
    if header:
        try:
            return max(POLL_SECONDS, int(header))
        except ValueError:
            try:
                until = parsedate_to_datetime(header)
                return max(POLL_SECONDS, (until - datetime.now(timezone.utc)).total_seconds())
            except (TypeError, ValueError, OverflowError):
                pass
    return 2 * POLL_SECONDS


def atomic_write(path, content):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(dir=path.parent, prefix=".tmp-")
    try:
        with os.fdopen(fd, "wb") as out:
            out.write(content if isinstance(content, bytes) else content.encode("utf-8"))
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def save_json(path, value):
    atomic_write(path, json.dumps(value, ensure_ascii=False, indent=2))


class PlainText(HTMLParser):
    def __init__(self):
        super().__init__()
        self.parts = []
        self.skip = 0
        self.links = []

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style"):
            self.skip += 1
        if not self.skip and tag == "a":
            attributes = dict(attrs)
            if attributes.get("href"):
                self.links.append((attributes["href"], attributes.get("download") or attributes.get("title"), "download" in attributes))
        if tag in ("p", "br", "div", "li", "tr"):
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in ("script", "style"):
            self.skip = max(0, self.skip - 1)
        if tag in ("p", "div", "li", "tr"):
            self.parts.append("\n")

    def handle_data(self, data):
        if not self.skip:
            self.parts.append(data)


def parse_content(value):
    parser = PlainText()
    parser.feed(str(value or ""))
    content = "\n".join(line.strip() for line in "".join(parser.parts).splitlines() if line.strip())
    return content, parser.links


def plain(value):
    return parse_content(value)[0]


def web_link(value):
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        url = urllib.parse.urljoin(BASE + "/", value.strip())
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme in ("http", "https") and parsed.hostname and not (parsed.username or parsed.password):
            return url
    except ValueError:
        pass
    return None


def content_links(content, anchors, attachments):
    seen = {item["url"] for item in attachments}
    for raw, title, download in anchors + [(m.group().rstrip(".,;!?)]}"), None, False) for m in HTTP_LINK.finditer(content)]:
        url = web_link(raw)
        if not url or url in seen:
            continue
        seen.add(url)
        parsed = urllib.parse.urlsplit(url)
        name = urllib.parse.unquote(parsed.path.rsplit("/", 1)[-1])
        is_file = download or Path(name).suffix.lower() in FILE_EXTENSIONS
        yield {"name": title or (name if is_file and name else parsed.hostname), "url": url,
               "kind": "正文文件" if is_file else "正文链接"}


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def safe_name(value):
    return re.sub(r"[^\w.\-\u4e00-\u9fff]+", "_", str(value)).strip("._")[:100] or "file"


def attachment_path(folder, attachment):
    key = fingerprint(attachment)[:12]
    original = str(attachment["name"])
    name = re.sub(r"[/\\:\x00-\x1f\x7f]+", " ", original).strip(" .") or "附件"
    extension = Path(name).suffix
    if len(extension) <= 12:
        stem = name[:-len(extension)] if extension else name
        name = stem.encode()[:210].decode("utf-8", errors="ignore") + extension
    else:
        name = name.encode()[:220].decode("utf-8", errors="ignore")
    target = folder / "文件" / key / name
    legacy = folder / (key + "-" + safe_name(original))
    if not target.exists() and legacy.is_file():
        target.parent.mkdir(parents=True, exist_ok=True)
        legacy.rename(target)
    return target


def due_date(value):
    try:
        result = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        return result.replace(tzinfo=TZ) if result.tzinfo is None else result.astimezone(TZ)
    except (ValueError, TypeError):
        return None


def unwrap(value):
    if not isinstance(value, dict) or "state" not in value:
        raise SyncError("网站返回格式发生变化，已停止同步。")
    if value["state"] in (999901, 999904):
        raise LoginRequired("学校登录已失效。")
    if value["state"] in (999902, 999903):
        raise SyncError("学校账号没有查看该数据的权限。")
    if value["state"] != 0:
        raise SyncError(f"学校接口错误（state={value['state']}），未更新本地同步记录。")
    return value.get("data")


class SchoolCookies(urllib.request.HTTPCookieProcessor):
    def http_request(self, request):
        return super().http_request(request) if school_origin(request.full_url) else request

    def http_response(self, request, response):
        if school_origin(request.full_url):
            return super().http_response(request, response)
        return response

    https_request = http_request
    https_response = http_response


def school_origin(url):
    parsed = urllib.parse.urlsplit(url)
    return parsed.scheme == "https" and parsed.netloc.lower() == "naisstu.schoolis.cn"


class SchoolRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if req.get_method() == "POST":
            return None
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class Client:
    rate_limit_until = 0.0

    def __init__(self, auth=None, *, fresh=False):
        if auth is None:
            auth = AUTH
        state = {}
        self.auth_stamp = None
        if not fresh:
            try:
                with auth.open() as saved:
                    state = json.load(saved)
                    self.auth_stamp = os.fstat(saved.fileno()).st_mtime_ns
            except FileNotFoundError:
                raise LoginRequired("尚未登录。") from None
        self.jar = http.cookiejar.CookieJar()
        self.add_cookies(state.get("cookies", []))
        self.opener = urllib.request.build_opener(SchoolCookies(self.jar), SchoolRedirects())

    def add_cookies(self, cookies):
        for c in cookies:
            domain = c["domain"].lower()
            # Only import cookies belonging to the requested school host.
            if not (domain.lstrip(".") == "naisstu.schoolis.cn" or domain == ".schoolis.cn"):
                continue
            expires = c.get("expires", -1)
            self.jar.set_cookie(http.cookiejar.Cookie(
                0, c["name"], c["value"], None, False, domain, domain.startswith("."),
                domain.startswith("."), c.get("path", "/"), True, c.get("secure", True),
                int(expires) if expires > 0 else None, expires <= 0, None, None, {}, False))

    def get(self, path, **params):
        return unwrap(self._json_request(path, params))

    def _json_request(self, path, params, *, body=None, referer=URL, retry_read=False):
        query = urllib.parse.urlencode({k: v for k, v in params.items() if v is not None})
        url = BASE + path + ("?" + query if query else "")
        headers = {"Accept": "application/json", "Referer": referer}
        data = None
        attempts = 3 if body is None or retry_read else 1
        if body is not None:
            headers.update({"Content-Type": "application/json", "Origin": BASE})
            data = json.dumps(body).encode()
        for attempt in range(attempts):
            if self.rate_limit_until > time.monotonic():
                raise RateLimited(self.rate_limit_until - time.monotonic())
            try:
                req = urllib.request.Request(url, headers=headers, data=data)
                with self.opener.open(req, timeout=30) as response:
                    if not school_origin(response.url) or urllib.parse.urlsplit(response.url).path.lower().rstrip("/") == "/login":
                        raise LoginRequired("学校网站返回了登录页。")
                    raw = response.read(16 * 1024 * 1024 + 1)
                    if response.length not in (None, 0):
                        raise http.client.IncompleteRead(raw, response.length)
                    if len(raw) > 16 * 1024 * 1024:
                        raise SyncError("学校接口响应过大，未更新本地同步记录。")
                try:
                    return json.loads(raw)
                except ValueError:
                    if attempt + 1 == attempts:
                        raise SyncError("学校接口未返回完整 JSON，未更新本地同步记录。") from None
            except urllib.error.HTTPError as exc:
                if exc.code == 401:
                    raise LoginRequired("学校登录已失效。") from None
                if exc.code == 429:
                    delay = retry_delay(exc.headers.get("Retry-After"))
                    self.rate_limit_until = time.monotonic() + delay
                    raise RateLimited(delay) from None
                if exc.code not in (500, 502, 503, 504) or attempt + 1 == attempts:
                    raise SyncError(f"学校接口 HTTP {exc.code}。") from None
            except RETRYABLE_READ as exc:
                if attempt + 1 == attempts:
                    reason = "学校接口响应未传完" if isinstance(exc, http.client.IncompleteRead) else "学校接口连接失败"
                    raise SyncError(f"{reason}，已保留上次结果。") from None
            time.sleep(2 ** attempt)

    def sign_in(self, credential):
        challenge = self._json_request("/api/MemberShip/GetStudentCaptchaForLogin", {}, referer=LOGIN_URL)
        image = unwrap(challenge)
        if "data" not in challenge or (image not in ("", None) and image is not False):
            raise LoginRequired("学校要求额外验证，请在设置中打开学校登录窗口。")
        timestamp = int(time.time())
        # Match the school login page's timestamped password format.
        password = hashlib.md5(f"{credential['digest']}{timestamp}".encode(), usedforsecurity=False)
        body = {"name": credential["name"], "password": password.hexdigest().upper(),
                "timestamp": timestamp, "isWeekPassword": credential["weak"], "LanguageType": 1}
        result = self._json_request("/api/MemberShip/Login", {"captcha": ""}, body=body, referer=LOGIN_URL)
        state = result.get("state") if isinstance(result, dict) else None
        if state == 1010078:
            raise LoginRequired("学校要求图形验证码，请在设置中打开学校登录窗口。")
        if state in (1010076, 1010082, 1010083):
            raise CredentialRejected("学校拒绝了账号或密码，请核对后再启用自动登录。")
        unwrap(result)

    def session_cookies(self):
        return [{"name": c.name, "value": c.value, "domain": c.domain, "path": c.path,
                 "secure": c.secure, "expires": c.expires if c.expires is not None else -1}
                for c in self.jar if not c.is_expired()]

    def download(self, url, target):
        url = urllib.parse.urljoin(BASE, url)
        parsed = urllib.parse.urlparse(url)
        # Attachments on other hosts are left as links; never send credentials there.
        if parsed.scheme != "https" or not (parsed.hostname == "schoolis.cn" or (parsed.hostname or "").endswith(".schoolis.cn")):
            raise SyncError("外部附件仅保留原始链接")
        # Separate unauthenticated client for CDN files; school-host requests use scoped cookies.
        opener = self.opener if parsed.hostname == "naisstu.schoolis.cn" else urllib.request.build_opener()
        fd, temp = tempfile.mkstemp(dir=target.parent, prefix=".download-")
        try:
            with os.fdopen(fd, "wb") as out, opener.open(url, timeout=45) as response:
                if "text/html" in response.headers.get("Content-Type", "").lower():
                    raise SyncError("附件返回网页，可能需要重新登录")
                size = 0
                limit = 100 * 1024 * 1024
                if response.length and response.length > limit:
                    raise AttachmentTooLarge("附件超过 100 MB，仅保留链接")
                while chunk := response.read(65536):
                    size += len(chunk)
                    if size > limit:
                        raise AttachmentTooLarge("附件超过 100 MB，仅保留链接")
                    out.write(chunk)
                if response.length not in (None, 0):
                    raise http.client.IncompleteRead(b"", response.length)
                if not size:
                    raise SyncError("附件下载返回空文件")
            os.replace(temp, target)
        finally:
            if os.path.exists(temp):
                os.unlink(temp)


class AttachmentWorker:
    """Download in the background so a slow file cannot block the task list."""

    def __init__(self):
        self.queue = Queue(maxsize=64)
        self.pending = set()
        self.failed = {}
        self.lock = Lock()
        Thread(target=self.run, name="attachment-download", daemon=True).start()

    def submit(self, client, url, path):
        with self.lock:
            if path in self.pending:
                return "下载中", None
            failure = self.failed.get(path)
            if failure and time.monotonic() < failure[0]:
                return failure[1], failure[2]
            try:
                self.queue.put_nowait((client, url, path))
            except Full:
                return "待下载", None
            self.pending.add(path)
            return "下载中", None

    def run(self):
        while True:
            client, url, path = self.queue.get()
            failure = None
            try:
                if not path.is_file():
                    client.download(url, path)
            except AttachmentTooLarge as exc:
                failure = float("inf"), "保留链接", str(exc)
            except (SyncError, ValueError, *RETRYABLE_READ) as exc:
                reason = str(exc) if isinstance(exc, SyncError) else "网络或文件写入失败"
                failure = time.monotonic() + 300, "待重试", reason
            finally:
                with self.lock:
                    self.pending.remove(path)
                    if failure:
                        self.failed[path] = failure
                    else:
                        self.failed.pop(path, None)
                self.queue.task_done()


def get_semester(client):
    semesters = client.get("/api/School/GetSchoolSemesters")
    if not isinstance(semesters, list) or not semesters:
        raise SyncError("没有可用学期，未更新同步记录。")
    return next((x for x in semesters if x.get("isNow")), semesters[0])


def collect_list(client, since, semester=None):
    semester = semester if semester is not None else get_semester(client)
    begin = max(since.date().isoformat(), str(semester["startDate"])[:10])
    end = str(semester["endDate"])[:10]
    if begin > end:
        return semester, []
    rows, seen, total = [], set(), None
    for page in range(1, 1001):
        data = client.get("/api/LearningTask/GetList", semesterId=semester["id"],
                          beginTime=begin, endTime=end,
                          pageIndex=page, pageSize=PAGE_SIZE, key="")
        if not isinstance(data, dict) or not isinstance(data.get("totalCount"), int):
            raise SyncError("任务分页格式发生变化，未更新同步记录。")
        items = data.get("list")
        if items is None and data["totalCount"] == 0:
            items = []
        if not isinstance(items, list):
            raise SyncError("任务分页缺少列表，未更新同步记录。")
        if total is None:
            total = data["totalCount"]
        if data["totalCount"] != total:
            raise SyncError("抓取期间任务列表发生变化，请稍后重试。")
        for row in items:
            ident = str(row.get("id") or "")
            if not ident or ident in seen:
                raise SyncError("分页出现缺失或重复任务 ID，请稍后重试。")
            seen.add(ident)
            rows.append(row)
        if len(rows) == total:
            # The list supplies beginTime. The detail has publishTime, checked before saving.
            return semester, [row for row in rows
                              if (started := due_date(row.get("beginTime"))) and started >= since]
        if not items or len(rows) > total:
            break
    raise SyncError("任务分页不完整，未更新同步记录。")


def normalize(row, detail):
    content, anchors = parse_content(detail.get("content"))
    attachments = [{"id": doc.get("id"), "name": doc.get("name") or doc.get("title") or "附件",
                    "url": web_link(doc.get("url")), "type": doc.get("type"), "kind": "附件"}
                   for doc in (detail.get("learningTaskDocuments") or [])]
    attachments.extend(content_links(content, anchors, attachments))
    title = detail.get("learningTaskName") or row.get("name") or "未命名任务"
    return {
        "id": str(row["id"]), "title": title,
        "subject": detail.get("subjectName") or row.get("subjectName") or row.get("subjectEName") or "未标明科目",
        "due": detail.get("endDate") or row.get("endTime"),
        "published": detail.get("publishTime"), "started": row.get("beginTime") or detail.get("beginDate"),
        "status": STATUS.get(row.get("finishState", detail.get("finishState")), "状态未知"),
        "content": content, "external": row.get("sourceType") == 2,
        "attachments": attachments,
        **task_metadata(row, detail, title, content, attachments),
    }


@contextmanager
def lock(root, name="sync"):
    (root / "data").mkdir(parents=True, exist_ok=True)
    with (root / f"data/{name}.lock").open("a") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            message = {"watch": "已有实时同步程序正在运行。", "login": "另一个登录正在进行。"}
            raise SyncBusy(message.get(name, "已有同步正在运行。")) from None
        yield


def load_json(path, default):
    return json.loads(path.read_text()) if path.is_file() else default


def archive_old_reports(root, day):
    report_dir = root / "reports"
    old_folder = report_dir / day
    backup = root / "data/report-history" / day
    if old_folder.is_dir():
        for path in old_folder.iterdir():
            if path.is_file() and re.fullmatch(r"\d{6}-\d{6}\.md", path.name):
                backup.mkdir(parents=True, exist_ok=True)
                if not (backup / path.name).exists():
                    path.rename(backup / path.name)
    legacy = report_dir / "latest.md"
    legacy_backup = backup / "旧版最新简报.md"
    if legacy.is_file() and not legacy_backup.exists() and legacy.read_text().startswith("# 学校任务简报"):
        backup.mkdir(parents=True, exist_ok=True)
        legacy.rename(legacy_backup)


def publish_report(root, tasks, changes, state, now, initial, warnings, *, write_html=True):
    day = now.date().isoformat()
    day_file = root / "data/report-days" / f"{day}.json"
    daily = load_json(day_file, {})
    changed = {task["id"] for task in changes}
    for task in tasks:
        ident = task["id"]
        first_seen = due_date(state["tasks"].get(ident, {}).get("first_seen"))
        if ident in daily or ident in changed or (first_seen and first_seen.date() == now.date()):
            daily[ident] = task
    report_path = day_file
    if write_html:
        report_path = root / "reports" / f"学校任务-{day}.html"
        notes = load_json(root / "data/任务中文备注.json", {})
        first_seen = {ident: task.get("first_seen") for ident, task in state["tasks"].items()}
        html = render_html(day, daily.values(), tasks, now, notes, translation_model(root), due_date, URL, first_seen)
        atomic_write(report_path, html)
    save_json(day_file, daily)
    save_json(root / "reports/latest.json", {"checked_at": now.isoformat(), "initial": initial,
              "changes": changes, "warnings": warnings, "report": str(report_path), "tasks": tasks})
    # Keep the previously shared latest.html address working without duplicating the daily report.
    if write_html:
        latest = root / "reports/latest.html"
        if not latest.is_symlink() or os.readlink(latest) != report_path.name:
            with tempfile.TemporaryDirectory(dir=latest.parent) as temp:
                alias = Path(temp) / "latest.html"
                alias.symlink_to(report_path.name)
                os.replace(alias, latest)
    archive_old_reports(root, day)
    return report_path


def rebuild_report(root=ROOT):
    with lock(root):
        cached = load_json(root / "reports/latest.json", None)
        if not cached:
            raise SyncError("还没有可用的任务记录，请先运行一次立即检查。")
        state = load_json(root / "data/state.json", {"tasks": {}})
        tasks = cached["tasks"]
        for task in tasks:
            folder = root / "data/tasks" / fingerprint(task["id"])[:24]
            source = load_json(folder / "source.json", {})
            if not source:
                continue
            snapshot = normalize(source["list"], source["detail"])
            old = state["tasks"].get(task["id"])
            if old:
                old.update(fingerprint=fingerprint(snapshot), task=snapshot)
            task.update({key: value for key, value in snapshot.items() if key != "attachments"})
            normalized = {item["url"]: item for item in snapshot["attachments"]}
            for item in task["attachments"]:
                if item.get("local_path") and item["url"] in normalized:
                    new_path = attachment_path(folder, normalized[item["url"]])
                    if new_path.is_file():
                        item["local_path"] = str(new_path.relative_to(root))
            save_json(folder / "attachments.json", task["attachments"])
        by_id = {task["id"]: task for task in tasks}
        changes = [dict(by_id[item["id"]], change=item.get("change", "更新"))
                   for item in cached["changes"] if item["id"] in by_id]
        report = publish_report(root, tasks, changes, state, due_date(cached["checked_at"]),
                                cached["initial"], cached["warnings"])
        save_json(root / "data/state.json", state)
        return report


def sync(client, root=ROOT, now=None, *, semester=None, refresh_details=False, downloads_worker=None, write_html=True):
    now = now or datetime.now(TZ)
    since = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    with lock(root):
        state_file = root / "data/state.json"
        state = json.loads(state_file.read_text()) if state_file.exists() else {"tasks": {}}
        initial = not state_file.exists()
        semester, rows = collect_list(client, since, semester)
        tasks, changes, warnings = [], [], []
        excluded = state.setdefault("outside_window", {})
        rows = [row for row in rows if excluded.get(str(row["id"])) != row.get("beginTime")]

        def fetch_detail(row):
            ident = str(row["id"])
            path = root / "data/tasks" / fingerprint(ident)[:24] / "source.json"
            archived = load_json(path, {})
            if row.get("sourceType") == 2:
                return archived, {}, None, None
            checked = due_date(archived.get("detail_checked_at"))
            if checked is None and archived:
                checked = datetime.fromtimestamp(path.stat().st_mtime, TZ)
            cached = archived.get("detail")
            if not refresh_details and isinstance(cached, dict) and archived.get("list") == row and checked and now < checked + DETAIL_RECHECK:
                return archived, cached, checked, None
            try:
                result = client.get("/api/LearningTask/GetDetail", learningTaskId=row["id"])
                if not isinstance(result, dict):
                    raise SyncError("任务详情格式异常")
                return archived, result, now, None
            except (LoginRequired, RateLimited):
                raise
            except SyncError as exc:
                return archived, cached or {}, None, str(exc)

        with ThreadPoolExecutor(max_workers=4) as pool:
            details = list(pool.map(fetch_detail, rows))
        for row, (archived, detail, checked, detail_error) in zip(rows, details):
            ident = str(row["id"])
            published = due_date(detail.get("publishTime"))
            if published and published < since:
                excluded[ident] = row.get("beginTime")
                continue
            excluded.pop(ident, None)
            task = normalize(row, detail)
            key = fingerprint(ident)[:24]
            folder = root / "data/tasks" / key
            if detail_error:
                warnings.append(f"{task['title']}：详情暂未更新，{detail_error}")
            else:
                source = {"list": row, "detail": detail, "detail_checked_at": checked.isoformat() if checked else None}
                if source != archived:
                    save_json(folder / "source.json", source)
                if row != archived.get("list") or detail != archived.get("detail") or not (folder / "任务全文.txt").exists():
                    atomic_write(folder / "任务全文.txt", f"{task['title']}\n{task['subject']}\n截止：{task['due']}\n\n{task['content']}\n")
            downloads = []
            for attachment in task["attachments"]:
                url = attachment.get("url")
                item = dict(attachment)
                parsed = urllib.parse.urlsplit(url) if url else None
                if attachment["kind"] == "正文链接" or (
                    parsed and (parsed.scheme != "https" or
                                not (parsed.hostname == "schoolis.cn" or parsed.hostname.endswith(".schoolis.cn")))
                ):
                    item["download_status"] = "保留链接"
                    downloads.append(item)
                    continue
                try:
                    if not url:
                        raise SyncError("附件没有下载链接")
                    path = attachment_path(folder, attachment)
                    if not path.exists():
                        path.parent.mkdir(parents=True, exist_ok=True)
                        if downloads_worker is None:
                            client.download(url, path)
                        else:
                            status, reason = downloads_worker.submit(client, url, path)
                            item["download_status"] = status
                            if reason:
                                warnings.append(f"{task['title']} / {attachment['name']}：{reason}。")
                    if path.is_file():
                        item.pop("download_status", None)
                        item["local_path"] = str(path.relative_to(root))
                except (SyncError, *RETRYABLE_READ) as exc:
                    item["download_status"] = "保留链接" if isinstance(exc, AttachmentTooLarge) else "待重试"
                    reason = str(exc) if isinstance(exc, SyncError) else "网络或文件写入失败"
                    warnings.append(f"{task['title']} / {attachment['name']}：{reason}。")
                downloads.append(item)
            if load_json(folder / "attachments.json", None) != downloads:
                save_json(folder / "attachments.json", downloads)
            old = state["tasks"].get(ident)
            digest = fingerprint(task)
            result = dict(task, attachments=downloads, detail_pending=bool(detail_error))
            if not old or old["fingerprint"] != digest:
                changes.append(dict(result, change="新增" if not old else "更新"))
            state["tasks"][ident] = {"fingerprint": digest, "first_seen": old["first_seen"] if old else now.isoformat(), "task": task}
            tasks.append(result)
        report_path = publish_report(root, tasks, changes, state, now, initial, warnings, write_html=write_html)
        state.update(last_success=now.isoformat(), semester_id=semester["id"])
        save_json(state_file, state)
        save_json(root / "data/status.json", {"ok": True, "checked_at": now.isoformat(), "changes": len(changes), "warnings": len(warnings)})
        items = [item for task in tasks for item in task["attachments"]]
        return {"ok": True, "tasks": len(tasks), "changes": len(changes), "initial": initial,
                "grades": sum(task["grade"] is not None for task in tasks),
                "links": sum(bool(item["url"]) for item in items),
                "downloaded": sum(bool(item.get("local_path")) for item in items),
                "warnings": len(warnings), "report": str(report_path)}


def session_stamp():
    try:
        return AUTH.stat().st_mtime_ns
    except FileNotFoundError:
        return None


def store_session(cookies):
    AUTH.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(AUTH.parent, 0o700)
    save_json(AUTH, {"cookies": cookies, "origins": []})
    return session_stamp()


def school_credential(name, password):
    digest = hashlib.md5(password.encode(), usedforsecurity=False).hexdigest().upper()
    length = len(password.encode("utf-16-le")) // 2
    groups = sum(bool(re.search(pattern, password))
                 for pattern in (r"[a-zA-Z]", r"[0-9]", r"[^a-zA-Z0-9_]"))
    weak = length < 8 or length > 20 or groups <= 1 or password.count("_")
    return {"name": name, "digest": digest, "weak": weak}


def new_school_session(credential):
    client = Client(fresh=True)
    client.sign_in(credential)
    get_semester(client)
    return client


def configure_auto_login(name, password):
    name = name.strip()
    if not name or len(name) > 50 or not password:
        raise SyncError("请输入有效的学校账号和密码。")
    credential = school_credential(name, password)
    del password
    with lock(ROOT, "login"):
        client = new_school_session(credential)
        try:
            save_credential(credential)
        except KeychainError as exc:
            raise SyncError(str(exc)) from None
        store_session(client.session_cookies())
        save_json(AUTO_LOGIN, {"enabled": True})


def recover_session(failed_stamp):
    with lock(ROOT, "login"):
        if session_stamp() != failed_stamp:
            return Client()
        settings = load_json(AUTO_LOGIN, {})
        if settings.get("enabled") is not True:
            raise LoginRequired("请在作业速览设置中登录学校账号。")
        try:
            credential = read_credential()
        except KeychainError as exc:
            raise LoginRequired(str(exc)) from None
        if credential is None:
            raise LoginRequired("钥匙串中没有学校登录凭据，请重新启用自动登录。")
        try:
            client = new_school_session(credential)
        except CredentialRejected:
            save_json(AUTO_LOGIN, {"enabled": False})
            raise
        client.auth_stamp = store_session(client.session_cookies())
        print("已自动重新登录，继续同步。", file=sys.stderr, flush=True)
        return client


def check_with_login(check, client=None):
    stamp = session_stamp()
    try:
        if client is None:
            client = Client()
        return check(client)
    except LoginRequired:
        return check(recover_session(stamp if client is None else client.auth_stamp))


def accept_browser_session(cookies):
    if not cookies:
        raise LoginRequired("请先在学校登录窗口完成登录。")
    with lock(ROOT, "login"):
        client = Client(fresh=True)
        client.add_cookies(cookies)
        try:
            get_semester(client)
        except LoginRequired:
            raise LoginRequired("学校尚未确认登录，请完成验证后再保存登录。") from None
        store_session(client.session_cookies())


def record_failure(exc):
    message = str(exc) if isinstance(exc, SyncError) else "本地环境或数据异常，请检查安装及文件权限。"
    save_json(ROOT / "data/status.json", {"ok": False, "checked_at": datetime.now(TZ).isoformat(),
              "error": message, "requires_login": isinstance(exc, LoginRequired)})
    print(message, file=sys.stderr, flush=True)
    return 2 if isinstance(exc, LoginRequired) else 1


def check_slot(now):
    if now.weekday() < 5 and (8 <= now.hour < 20 or (now.hour == 20 and now.minute == 0)):
        return now.replace(second=0, microsecond=0)
    return None


class SyncSession:
    """Keep the authenticated client and its cached semester across checks."""

    def __init__(self):
        self.client = None
        self.semester = None
        self.semester_day = None
        self.semester_expiry = 0.0

    def run(self, now, *, downloads_worker, refresh_details=False, write_html=True):
        if self.client and self.client.auth_stamp != session_stamp():
            self.client = None
        started = time.monotonic()

        def check(client):
            if client is not self.client:
                self.client = client
                self.semester = None
            if self.semester is None or self.semester_day != now.date() or started >= self.semester_expiry:
                self.semester = get_semester(client)
                self.semester_day = now.date()
                self.semester_expiry = started + SEMESTER_RECHECK_SECONDS
            return sync(client, now=now, semester=self.semester, downloads_worker=downloads_worker,
                        refresh_details=refresh_details, write_html=write_html)

        try:
            return check_with_login(check, self.client)
        except LoginRequired:
            self.client = None
            raise


def watch():
    with lock(ROOT, "watch"):
        print("实时同步已启动。北京时间周一至周五 08:00–20:00，每分钟检查。按 Ctrl+C 停止。", flush=True)
        worker = AttachmentWorker()
        session = SyncSession()
        auth_stamp = None
        waiting_for_login = False
        next_poll = 0.0
        failures = 0
        first = True

        while True:
            now = datetime.now(TZ)
            if check_slot(now) is None:
                time.sleep(15)
                continue
            started = time.monotonic()
            if started < next_poll:
                time.sleep(min(10, next_poll - started))
                continue
            stamp = session_stamp()
            if waiting_for_login and stamp == auth_stamp:
                time.sleep(10)
                continue
            waiting_for_login = False
            next_poll = started + POLL_SECONDS
            try:
                result = session.run(now, downloads_worker=worker)
            except SyncBusy:
                # A manual check can run while the watcher is open.
                continue
            except LoginRequired as exc:
                waiting_for_login = True
                auth_stamp = session_stamp()
                record_failure(exc)
                print("重新登录后，本窗口会自动继续同步。", flush=True)
            except (SyncError, OSError, ValueError) as exc:
                failures += 1
                delay = min(900, POLL_SECONDS * 2 ** min(failures - 1, 4))
                if isinstance(exc, RateLimited):
                    delay = max(delay, exc.retry_after)
                next_poll = time.monotonic() + delay
                record_failure(exc)
            else:
                failures = 0
                if first or result["changes"]:
                    print(f"{now:%H:%M} 同步成功，{result['changes']} 项新增或更新，已记录 {result['grades']} 项成绩。", flush=True)
                    print(f"最新报告：{result['report']}", flush=True)
                    first = False


def main():
    parser = argparse.ArgumentParser(description="学校任务同步与中文简报")
    parser.add_argument("command", choices=["sync", "watch", "status", "report"])
    args = parser.parse_args()
    os.umask(0o077)
    try:
        if args.command == "watch":
            watch()
        elif args.command == "report":
            print(rebuild_report())
        elif args.command == "status":
            print((ROOT / "data/status.json").read_text() if (ROOT / "data/status.json").exists() else "尚未同步")
        else:
            print(json.dumps(check_with_login(lambda client: sync(client, refresh_details=True)), ensure_ascii=False))
        return 0
    except SyncBusy as exc:
        print(exc, file=sys.stderr)
        return 1
    except (SyncError, OSError, ValueError, ImportError) as exc:
        return record_failure(exc)
    except KeyboardInterrupt:
        print("\n已停止。")
        return 0


if __name__ == "__main__":
    sys.exit(main())
