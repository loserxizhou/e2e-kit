"""维护者维护的初稿生成器；输入纯 JSON，不执行输入中的脚本或公式，不覆盖工作簿。"""
import json
import math
import os
from pathlib import Path
import re
import runpy
import sys
from tempfile import TemporaryDirectory
from time import perf_counter
from datetime import datetime, timezone, timedelta

from openpyxl import Workbook, load_workbook
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.formatting.rule import CellIsRule, FormulaRule
from openpyxl.utils import get_column_letter

HOME = Path(__file__).resolve().parent
FORMAT = runpy.run_path(str(HOME / "check-case-doc.py"))
COLUMNS, SUPPORT = FORMAT["COLUMNS"], FORMAT["SUPPORT_COLUMNS"]
CASE_FIELDS = {"id", "module", "type", "priority", "scenario", "accounts", "data", "preconditions", "steps", "expected", "remarks", "author", "createdAt"}


def obj(value, allowed, where):
    if not isinstance(value, dict) or set(value) - set(allowed):
        raise ValueError(f"{where} 结构或字段不合法，请对照初稿输入说明")
    return value


def text(value, where):
    if not isinstance(value, str) or not value.strip() or len(value) > 4000 or "\0" in value:
        raise ValueError(f"{where} 须填写非空文本（最多 4000 字符）")
    return value.strip()


def lines(value, where):
    if not isinstance(value, list) or not 1 <= len(value) <= 30:
        raise ValueError(f"{where} 须为 1～30 项文本数组")
    return [text(v, where) for v in value]


def ids(value, pattern, where):
    values = lines(value, where)
    if len(set(values)) != len(values) or any(not re.fullmatch(pattern, v) for v in values):
        raise ValueError(f"{where} 编号格式不合法或重复")
    return values


def timestamp(value):
    result = text(value, "创建时间")
    try:
        if datetime.strptime(result, "%Y-%m-%d %H:%M").strftime("%Y-%m-%d %H:%M") != result:
            raise ValueError()
    except ValueError:
        raise ValueError("创建时间须为 yyyy-mm-dd HH:MM 的有效时间") from None
    return result


def numbered(values):
    return "\n".join(f"{i}. {v}" for i, v in enumerate(values, 1))


def validate(model):
    obj(model, {"schemaVersion", "title", "author", "createdAt", "scope", "entry", "environment", "dataBatch", "constraints", "permissionTesting", "sheets", "accounts", "data", "checks", "permissions"}, "初稿")
    if model.get("schemaVersion") != "eoffice-case-draft-1":
        raise ValueError("初稿 schemaVersion 须为 eoffice-case-draft-1")
    for field in ("title", "author", "scope", "entry", "environment", "dataBatch", "constraints"):
        model[field] = text(model.get(field), field)
    model["createdAt"] = timestamp(model.get("createdAt", datetime.now(timezone(timedelta(hours=8))).strftime("%Y-%m-%d %H:%M")))
    permission = obj(model.get("permissionTesting"), {"enabled", "reason"}, "权限适用性")
    if not isinstance(permission.get("enabled"), bool):
        raise ValueError("权限适用性 enabled 须为布尔值")
    text(permission.get("reason"), "权限适用原因/依据")
    for field in ("sheets", "accounts", "data", "checks"):
        if not isinstance(model.get(field), list) or not 1 <= len(model[field]) <= (12 if field == "sheets" else 1000):
            raise ValueError(f"{field} 须为非空数组，场景页最多12个，准备记录最多1000条")
    seen, names = set(), {n.casefold() for n in ["说明", *SUPPORT]}
    records = []
    for sheet in model["sheets"]:
        obj(sheet, {"name", "cases"}, "场景工作表")
        name = text(sheet.get("name"), "工作表名")
        if len(name) > 31 or re.search(r"[\\/*?:\[\]]", name) or name.startswith("'") or name.endswith("'") or name.casefold() in names:
            raise ValueError("工作表名无效、重复或占用了固定辅助页名称")
        names.add(name.casefold())
        sheet["name"] = name
        if not isinstance(sheet.get("cases"), list) or not sheet["cases"]:
            raise ValueError("每张场景页至少需要一条用例")
        for case in sheet["cases"]:
            obj(case, CASE_FIELDS, "用例")
            key = text(case.get("id"), "用例编号")
            if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{1,79}", key) or key in seen:
                raise ValueError("用例编号格式不合法或重复")
            seen.add(key)
            case["id"] = key
            for field in ("module", "type", "priority", "scenario"):
                case[field] = text(case.get(field), f"用例 {field}")
            if case["priority"] not in {"P0", "P1", "P2"} or case["type"] not in {"功能测试", "异常测试", "界面测试", "兼容性测试", "性能测试", "安全测试"}:
                raise ValueError("用例类型或优先级不符合模板")
            case["accounts"] = ids(case.get("accounts"), r"A\d{2,}", "账号引用")
            case["data"] = ids(case.get("data"), r"D\d{2,}", "数据引用")
            for field in ("preconditions", "steps", "expected"):
                case[field] = lines(case.get(field), f"用例 {field}")
            if len(case["steps"]) != len(case["expected"]):
                raise ValueError("用例步骤与预期结果条数必须一致")
            for field in ("remarks", "author"):
                if field in case:
                    text(case[field], field)
            if "createdAt" in case:
                timestamp(case["createdAt"])
            records.append(case)
    if len(records) > 1000:
        raise ValueError("一份初稿最多1000条用例，请按验收范围拆分")
    tables = {}
    fields = {
        "accounts": {"id", "username", "department", "role", "scope", "purpose", "credential", "checks"},
        "data": {"id", "source", "method", "initialState", "mutates", "checks"},
        "checks": {"id", "items", "expected", "notApplicableReason"},
        "permissions": {"id", "capability", "condition", "expected", "basis", "cases"},
    }
    prefixes = {"accounts": "A", "data": "D", "checks": "V", "permissions": "P"}
    for field, keys in fields.items():
        entries = model.get(field, [])
        if not isinstance(entries, list) or len(entries) > 1000:
            raise ValueError("辅助页结构无效或超过1000条")
        table = {}
        for entry in entries:
            obj(entry, keys, field)
            key = text(entry.get("id"), "辅助编号")
            if not re.fullmatch(prefixes[field] + r"\d{2,}", key) or key in table:
                raise ValueError("辅助编号格式无效或重复")
            for k in keys - {"checks", "cases", "notApplicableReason"}:
                entry[k] = text(entry.get(k), f"{field}.{k}")
            if "checks" in keys:
                ids(entry.get("checks"), r"V\d{2,}", "核验引用")
            if "cases" in keys:
                ids(entry.get("cases"), r"[A-Za-z][A-Za-z0-9_-]{1,79}", "权限用例引用")
            if "notApplicableReason" in entry:
                text(entry["notApplicableReason"], "不适用原因")
            table[key] = entry
        tables[field] = table
    for case in records:
        for field in ("accounts", "data"):
            if any(key not in tables[field] for key in case[field]):
                raise ValueError("用例引用了不存在的账号或数据编号")
    for field in ("accounts", "data"):
        for entry in tables[field].values():
            if any(key not in tables["checks"] for key in entry["checks"]):
                raise ValueError("准备记录引用了不存在的核验编号")
    for entry in tables["data"].values():
        if entry["source"] not in {"待准备", "不适用"} or entry["mutates"] not in {"是", "否", "待确认", "不适用"}:
            raise ValueError("初稿数据来源仅允许待准备/不适用，数据变化标记须符合模板")
    for entry in tables["permissions"].values():
        if any(key not in seen for key in entry["cases"]):
            raise ValueError("权限矩阵引用了不存在的用例")
    if permission["enabled"] != bool(tables["permissions"]):
        raise ValueError("权限测试适用性与权限矩阵不一致")
    return records, tables


FONT = Font(name="Microsoft YaHei", size=10, color="20252B")
LINE = Side(style="thin", color="C9CFD6")
BORDER = Border(left=LINE, right=LINE, top=LINE, bottom=LINE)


def write(ws, row, values):
    for col, value in enumerate(values, 1):
        cell = ws.cell(row, col, value)
        if isinstance(value, str):
            cell.data_type = "s"  # =、+、@ 等业务输入保持纯文本，不作为 Excel 公式。
        cell.font, cell.border = FONT, BORDER
        cell.alignment = Alignment(vertical="top", wrap_text=True)
    height = 30
    for col, value in enumerate(values, 1):
        width = ws.column_dimensions[get_column_letter(col)].width
        count = sum(max(1, math.ceil(sum(2 if ord(c) > 255 else 1 for c in line) / max(1, width - 2))) for line in str(value).split("\n"))
        height = max(height, count * 14 + 10)
    if height > 409:
        raise ValueError("用例或说明文字过长，请精简表述或拆分用例，避免 Excel 行高截断")
    ws.row_dimensions[row].height = height


def header(ws, row, labels):
    write(ws, row, labels)
    for cell in ws[row][:len(labels)]:
        cell.fill = PatternFill("solid", fgColor="334A62")
        cell.font = Font(name="Microsoft YaHei", size=10, bold=True, color="FFFFFF")
        cell.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)


def table(wb, name, labels, rows, widths, metadata=()):
    ws = wb.create_sheet(name)
    ws.sheet_view.showGridLines = False
    for i, width in enumerate(widths, 1):
        ws.column_dimensions[get_column_letter(i)].width = width
    ws.cell(1, 1, name).font = Font(name="Microsoft YaHei", size=14, bold=True)
    for i, values in enumerate(metadata, 2):
        write(ws, i, values)
    h = 5 if metadata else 4
    header(ws, h, labels)
    for i, values in enumerate(rows, h + 1):
        write(ws, i, values)
    ws.freeze_panes = f"C{h+1}" if len(labels) == 16 else f"B{h+1}"
    ws.auto_filter.ref = f"A{h}:{get_column_letter(len(labels))}{h+len(rows)}"
    return ws


def build(model, records, tables):
    wb = Workbook()
    desc = wb.active
    desc.title = "说明"
    desc.sheet_view.showGridLines = False
    for i, width in enumerate([30, 75, 75, 14, 14, 14, 14, 26], 1):
        desc.column_dimensions[get_column_letter(i)].width = width
    desc.cell(1, 1, model["title"] + "_测试用例初稿").font = Font(name="Microsoft YaHei", size=14, bold=True)
    desc.cell(2, 1, f"生成日期：{model['createdAt']}　测试人：{model['author']}").font = FONT
    sections = [
        ("一、被测对象", model["scope"]), ("二、测试入口", model["entry"]),
        ("三、能力清单", "\n".join(f"{s['name']}：{len(s['cases'])}条" for s in model["sheets"])),
        ("四、账号准备", "\n".join(f"{a['id']}：{a['purpose']}；凭据配置项：{a['credential']}" for a in model["accounts"])),
        ("五、数据准备", f"环境：{model['environment']}\n数据批次：{model['dataBatch']}\n数据编号：{'、'.join(tables['data'])}；准备方法、状态及核验引用见测试数据页。默认保留，不自动清理。"),
        ("六、权限模型", f"权限测试：{'是' if model['permissionTesting']['enabled'] else '否'}；依据/原因：{model['permissionTesting']['reason']}"),
        ("七、操作约束", model["constraints"]),
        ("八、执行说明", "设计初稿，尚未实施正式验收，所有业务用例未执行；不生成审核回执或执行通过。人工审查后由 AI 按最新 Excel 实现脚本、核验数据、执行并依据本批次证据回填。"),
    ]
    header(desc, 4, ["项目", "说明"])
    for row, pair in enumerate(sections, 5):
        write(desc, row, pair)
    total = len(records)
    write(desc, 14, ["九、执行统计"])
    header(desc, 15, ["状态", "用例数", "占比"])
    for row, values in enumerate([["通过", 0, 0], ["未通过", 0, 0], ["未执行", total, 1], ["合计", total, 1]], 16):
        write(desc, row, values)
        desc.cell(row, 3).number_format = "0%"
    write(desc, 23, ["十、各能力用例数量"])
    header(desc, 24, ["能力（工作表）", "用例数"])
    for row, sheet in enumerate(model["sheets"], 25):
        write(desc, row, [sheet["name"], len(sheet["cases"])])
    last = 25 + len(model["sheets"])
    write(desc, last, ["合计", total])
    write(desc, last+2, ["十一、脚本与用例对应统计"])
    header(desc, last+3, ["TS 文件路径", "对应模块", "覆盖用例编号", "用例数", "通过", "未通过", "未执行", "最近执行时间"])
    for row, sheet in enumerate(model["sheets"], last+4):
        write(desc, row, ["—（待编写 e2e）", sheet["name"], "、".join(c["id"] for c in sheet["cases"]), len(sheet["cases"]), 0, 0, len(sheet["cases"]), "—"])
    write(desc, last+4+len(model["sheets"]), ["合计", "—", "—", total, 0, 0, total, "—"])
    desc.freeze_panes = "B5"
    for sheet in model["sheets"]:
        rows = []
        for c in sheet["cases"]:
            pre = c["preconditions"]
            declared = set(re.findall(r"(?<![A-Za-z0-9_])[AD]\d{2,}(?![A-Za-z0-9_])", "\n".join(pre)))
            missing = set(c["accounts"] + c["data"]) - declared
            if missing:
                pre = ["账号/数据准备引用：" + "、".join(sorted(missing)), *pre]
            rows.append([c["id"], c["module"], c["type"], c["priority"], c["scenario"], numbered(pre), numbered(c["steps"]), numbered(c["expected"]), "—", "未执行", c.get("remarks", "—"), "—", "—", "—", c.get("author", model["author"]), c.get("createdAt", model["createdAt"])])
        ws = table(wb, sheet["name"], COLUMNS, rows, [17, 25, 13, 10, 45, 55, 66, 72, 45, 24, 48, 28, 24, 22, 16, 24])
        for row in ws.iter_rows(min_row=5, min_col=10, max_col=10):
            row[0].font = Font(name="Microsoft YaHei", size=10, color="000000")
        ws.conditional_formatting.add(f"J5:J{4+len(rows)}", CellIsRule(operator="equal", formula=['"通过"'], font=Font(color="217346")))
        ws.conditional_formatting.add(f"J5:J{4+len(rows)}", FormulaRule(formula=['ISNUMBER(SEARCH("未通过",J5))'], font=Font(color="B42318")))
    accounts = [[a["id"], a["username"], a["department"], a["role"], a["scope"], a["purpose"], a["credential"], "、".join(a["checks"])] for a in model["accounts"]]
    data = [[d["id"], "、".join(c["id"] for c in records if d["id"] in c["data"]), d["source"], d["method"], "—", d["initialState"], d["mutates"], "、".join(d["checks"])] for d in model["data"]]
    checks = [[v["id"], "、".join(e["id"] for field in ("accounts", "data") for e in model[field] if v["id"] in e["checks"]), v["items"], v["expected"], v.get("notApplicableReason", "—"), "不适用" if "notApplicableReason" in v else "未执行", "—", "—"] for v in model["checks"]]
    permissions = [[p["id"], p["capability"], p["condition"], p["expected"], p["basis"], "、".join(p["cases"]), "未执行"] for p in model.get("permissions", [])]
    table(wb, "账号矩阵", SUPPORT["账号矩阵"], accounts, [14, 30, 22, 25, 60, 45, 50, 22])
    table(wb, "测试数据", SUPPORT["测试数据"], data, [14, 72, 15, 98, 30, 80, 22, 22], [("被测环境", model["environment"]), ("数据批次", model["dataBatch"])])
    table(wb, "造数核验", SUPPORT["造数核验"], checks, [14, 35, 58, 80, 40, 16, 24, 40])
    if permissions:
        table(wb, "能力权限矩阵", SUPPORT["能力权限矩阵"], permissions, [14, 30, 70, 75, 65, 85, 20])
    rep = FORMAT["Report"]()
    FORMAT["check_workbook"](wb, {}, rep)
    if rep.errors:
        raise ValueError("初稿内容校验失败：\n" + "\n".join(rep.errors[:20]))
    return wb, rep


def inside(root, path):
    absolute = Path(os.path.abspath(path))
    try:
        parts = absolute.relative_to(root).parts
    except ValueError:
        raise ValueError("初稿路径超出项目") from None
    current = root
    for part in parts:
        current /= part
        if current.is_symlink():
            raise ValueError("初稿路径不能经过软链接")
    return absolute


def generate(root, source, output):
    start = perf_counter()
    root = Path(os.path.abspath(root))
    source, output = inside(root, source), inside(root, output)
    if source.suffix.lower() != ".json" or source.stat().st_size > 2 * 1024 * 1024:
        raise ValueError("初稿输入须为不超过2 MB的 JSON")
    if output.suffix.lower() != ".xlsx" or output.relative_to(root).parts[0] not in {"exports", "scratch"}:
        raise ValueError("初稿仅生成到 exports 或 scratch 内的 xlsx")
    if output.exists():
        raise ValueError("初稿目标已存在，拒绝覆盖；请局部维护原 Excel，保留人工内容")
    raw = source.read_bytes()
    if len(raw) > 2 * 1024 * 1024:
        raise ValueError("初稿输入超过2 MB")
    model = json.loads(raw)
    records, tables = validate(model)
    workbook, rep = build(model, records, tables)
    output.parent.mkdir(parents=True, exist_ok=True)
    reader = runpy.run_path(str(HOME / "read-case-doc.py"))["read_document"]
    with TemporaryDirectory(prefix=".case-draft-", dir=output.parent) as temp:
        candidate = Path(temp) / "candidate.xlsx"
        workbook.save(candidate)
        os.chmod(candidate, 0o600)
        saved = load_workbook(candidate, data_only=True)
        try:
            check = FORMAT["Report"]()
            FORMAT["check_workbook"](saved, {}, check)
            if check.errors:
                raise ValueError("初稿保存后的校验失败，未交付文件")
        finally:
            saved.close()
        model_view = reader(candidate)
        # 原子创建且不替换已有文件；并发生成也不能覆盖人工文件。
        try:
            os.link(candidate, output)
        except FileExistsError:
            raise ValueError("初稿目标已存在，拒绝覆盖") from None
    return {"output": str(output.relative_to(root)), "cases": len(records), "state": "draft", "errors": 0,
            "warnings": rep.warnings, "designHash": model_view["designHash"], "durationMs": round((perf_counter()-start)*1000)}


if __name__ == "__main__":
    try:
        if len(sys.argv) != 4:
            raise ValueError("初稿生成器由 test:cases draft <json> --output <xlsx> 调用")
        print(json.dumps(generate(*sys.argv[1:]), ensure_ascii=False))
    except Exception as error:
        message = str(error) if isinstance(error, ValueError) and not isinstance(error, json.JSONDecodeError) else "初稿生成失败，请检查文件、输入结构及 Python/openpyxl 依赖"
        print(message, file=sys.stderr)
        sys.exit(2)
