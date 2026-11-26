"""Upload staged files and submit a task the same way the student site does."""
import subprocess
import tempfile
from pathlib import Path

import school_tasks as school

MAX_FILES = 10
MAX_BYTES = 300 * 1024 * 1024
# The student site only previews doc/docx/pdf, and treats jpg/png/zip/ppt/xls/txt as images or files.
SUPPORTED = {".doc", ".docx", ".pdf", ".jpg", ".jpeg", ".png", ".ppt", ".pptx",
             ".xls", ".xlsx", ".txt", ".zip", ".rar", ".mp3", ".m4a", ".mp4", ".mov"}
CONVERT = {".heic": ".jpg", ".heif": ".jpg", ".tiff": ".jpg", ".webp": ".jpg",
           ".bmp": ".jpg", ".gif": ".jpg"}


class SubmitError(school.SyncError):
    pass


def check(task_id, files):
    if not str(task_id).strip():
        raise SubmitError("缺少任务编号，无法提交。")
    if not files:
        raise SubmitError("请先添加附件，或在说明里写点内容。")
    if len(files) > MAX_FILES:
        raise SubmitError("学校最多接受 10 个附件。")
    for path in files:
        path = Path(path)
        if not path.is_file():
            raise SubmitError(f"找不到文件：{path.name}")
        if path.stat().st_size > MAX_BYTES:
            raise SubmitError(f"{path.name} 超过 300 MB，学校不接受。")


def convert(path, folder):
    """HEIC and other photo formats are not on the school's list, so send JPEG instead."""
    target = CONVERT.get(path.suffix.lower())
    if target is None:
        return path
    output = Path(folder) / (path.stem + target)
    result = subprocess.run(["/usr/bin/sips", "-s", "format", "jpeg", str(path), "--out", str(output)],
                            capture_output=True, check=False)
    if result.returncode != 0 or not output.is_file():
        raise SubmitError(f"无法把 {path.name} 转成 JPEG，请先导出为 PDF 再提交。")
    return output


def prepare(files, folder):
    prepared = []
    for path in files:
        path = Path(path)
        suffix = path.suffix.lower()
        if suffix not in SUPPORTED and suffix not in CONVERT:
            raise SubmitError(f"学校不接受 {suffix or '无扩展名'} 文件，请转成 PDF 或图片。")
        prepared.append(convert(path, folder))
    return prepared


def submit(client, task_id, files, remark=""):
    """Upload every file, then call Save with the same payload the web page sends."""
    files = [Path(path) for path in files]
    check(task_id, files)
    documents = []
    with tempfile.TemporaryDirectory(prefix="sp-submit-") as folder:
        files = prepare(files, folder)
        for path in files:
            uploaded = client.upload("/api/LearningTask/UploadDocument", path)
            documents.append({
                "id": 0,
                "type": path.suffix.lower(),
                "size": path.stat().st_size,
                "name": path.name,
                "url": uploaded.get("url") or "",
                "pdfUrl": uploaded.get("pdfUrl") or "",
            })
    payload = {"learningTaskId": task_id, "remark": remark,
               "learningTaskStudentDocuments": documents}
    return school.unwrap(client._json_request("/api/LearningTask/Save", {}, body=payload))
