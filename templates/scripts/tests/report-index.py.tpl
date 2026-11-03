"""维护者的报告索引回归；只读工具代码，临时 JSON 不包含业务数据。"""
import json
from pathlib import Path
import runpy
from tempfile import TemporaryDirectory

module = runpy.run_path(str(Path(__file__).resolve().parents[1] / "check-case-doc.py"))
Report, load, matches = module["Report"], module["load_report"], module["report_matches"]

with TemporaryDirectory(prefix="eoffice-report-index-") as temp:
    path = Path(temp) / "report.json"
    original = {"kind": "test", "tags": ["case:DOC-001"], "titlePath": ["标题已变"], "status": "passed"}
    path.write_text(json.dumps({"schemaVersion": "report-1", "run": {"results": [
        original,
        {**original, "selected": False, "status": "failed"},
        {**original, "kind": "setup"},
        {"tags": [], "titlePath": ["旧场景"], "status": "passed"},
    ]}}))
    rep = Report()
    index = load(path, rep)
    assert not rep.errors, rep.errors
    assert matches(index, "DOC-001", "旧标题") == [original]
    assert not matches(index, "OTHER-001", "标题已变"), "已有编号不能按标题误关联另一个业务编号"
    assert len(matches(index, "LEGACY-001", "旧场景")) == 1
    path.write_text(json.dumps({"schemaVersion": "report-2", "run": {"results": []}}))
    rep = Report()
    assert load(path, rep) == {} and rep.errors
print("PASS：按编号关联、旧标题兼容、setup/未选中排除及未知 schema 拒绝")
