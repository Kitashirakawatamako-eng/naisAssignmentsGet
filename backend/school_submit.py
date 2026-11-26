"""Upload staged files and submit a task the same way the student site does."""
from pathlib import Path

import school_tasks as school

MAX_FILES = 10
MAX_BYTES = 300 * 1024 * 1024


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


def submit(client, task_id, files, remark=""):
    """Upload every file, then call Save with the same payload the web page sends."""
    files = [Path(path) for path in files]
    check(task_id, files)
    documents = []
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
