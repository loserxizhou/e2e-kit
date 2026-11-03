#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""校验 AI 生成的 e2e 用例 Excel 是否符合模板，并与 report.json 交叉核对。

用法：
    python3 e2e/scripts/check-case-doc.py <用例文档.xlsx> [report.json]
    python3 e2e/scripts/check-case-doc.py <用例文档.xlsx> --draft

report.json 默认取 e2e/.e2e/report.json（最近一次执行）。校验项：
  1. 第一个工作表是「说明」页，且 11 个区块齐全；
  2. 明细页 16 列列名、列序与模板一致；
  3. 每行「测试步骤」条数 = 「预期结果」条数；
  4. 已执行的用例必须能关联到 e2e report.json；
  5. 「验证结果」格式合法，未通过步骤必须括注失败点；
  6. 未执行不得预填实测结果，已执行须记录实际结果；
  7. 与 report.json 状态一致（passed/failed/skipped ↔ 验证结果）；
  8. 说明页第九/十/十一节统计与明细页计数一致；
  9. 账号矩阵、测试数据、造数核验必备，权限测试须有能力权限矩阵；
 10. 数据/账号/核验/用例编号互相可追溯，核验状态、时间、证据完整；
 11. 附件仅允许 PNG/JPG/JPEG/WebP 截图链接或 —（不验证截图真实性）。
 12. 提醒各页表格缺失边框（warning，不阻断交付；使用者可调整样式）。

退出码：0 = 通过（可能有 warning），1 = 有 error，2 = 环境/文件问题。
依赖：openpyxl（pip install openpyxl）。
"""

import json
import re
import sys
from pathlib import Path

try:
    import openpyxl
except ImportError:  # pragma: no cover
    print("缺少 openpyxl：请先执行 pip install openpyxl", file=sys.stderr)
    sys.exit(2)

COLUMNS = [
    "用例编号", "所属模块", "用例类型", "优先级", "测试场景", "前置条件",
    "测试步骤", "预期结果", "实测结果", "验证结果", "备注",
    "附件", "测试日期时间", "反馈号", "创建人", "创建时间",
]
BLOCKS = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十", "十一"]
NUM_MARK = re.compile(r"(?:^|(?<=[\s；;，,]))\s*(\d{1,2})\s*[.、．)）]")
RESULT_ITEM = re.compile(r"(\d{1,2})\s*[：:]\s*(通过|未通过|未执行)")
DATETIME = re.compile(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$")
EMPTY_MARKS = {"", "—", "-", "/", "无"}
SUPPORT_COLUMNS = {
    "账号矩阵": ["账号代号", "用户名 / 用户ID", "部门", "角色", "菜单及数据范围", "用途", "凭据配置项", "关联核验编号"],
    "测试数据": ["数据编号", "关联用例编号", "来源方式", "准备方法 / 脚本位置", "实际ID / 业务编码", "初始状态及权限", "是否被用例改变", "关联核验编号"],
    "造数核验": ["核验编号", "核验对象", "检查项", "预期条件", "实际读回结果", "核验状态", "核验时间", "证据位置"],
    "能力权限矩阵": ["权限编号", "能力", "权限条件", "预期行为", "规则依据", "关联用例编号", "验收汇总"],
}
SUPPORT_PREFIXES = {"账号矩阵": "A", "测试数据": "D", "造数核验": "V", "能力权限矩阵": "P"}
PERMISSION_HINTS = re.compile(r"权限|越权|隔离|本人.*他人|他人.*本人")


class Report:
    def __init__(self):
        self.errors = []
        self.warnings = []

    def error(self, where, msg):
        self.errors.append(f"[error] {where}: {msg}")

    def warn(self, where, msg):
        self.warnings.append(f"[warn ] {where}: {msg}")


def text(value):
    if value is None:
        return ""
    return str(value).strip()


def references(value):
    """编号逐个列出，不展开范围，也不从自然语言中猜测编号。"""
    if text(value) in EMPTY_MARKS:
        return []
    return [s for s in re.split(r"[\s,，、;；]+", text(value)) if s]


def check_table_borders(ws, rep):
    """只读检查实际表格的边线，兼容合并区域与相邻格共享边线。"""
    first_header = "项目" if ws.title == "说明" else SUPPORT_COLUMNS.get(ws.title, COLUMNS)[0]
    start_row = next((row[0].row for row in ws.iter_rows(max_row=min(ws.max_row, 10))
                      if text(row[0].value) == first_header), None)
    if start_row is None:
        return  # 表格结构问题由对应工作表校验处理，不把标题当表格。

    merged = {(area.min_row, area.min_col): area for area in ws.merged_cells.ranges}
    sides = {"left": "左", "right": "右", "top": "上", "bottom": "下"}
    neighbours = {"left": (0, -1, "right"), "right": (0, 1, "left"),
                  "top": (-1, 0, "bottom"), "bottom": (1, 0, "top")}

    def has_line(row, col, side):
        line = getattr(ws.cell(row, col).border, side)
        if line is not None and line.style:
            return True
        dr, dc, opposite = neighbours[side]
        if 1 <= row + dr <= ws.max_row and 1 <= col + dc <= ws.max_column:
            line = getattr(ws.cell(row + dr, col + dc).border, opposite)
            return line is not None and bool(line.style)
        return False

    missing_count, samples = 0, []
    for row in ws.iter_rows(min_row=start_row):
        for cell in row:
            if not text(cell.value):
                continue
            area = merged.get((cell.row, cell.column))
            r1, r2 = (area.min_row, area.max_row) if area else (cell.row, cell.row)
            c1, c2 = (area.min_col, area.max_col) if area else (cell.column, cell.column)
            edges = {
                "left": ((r, c1) for r in range(r1, r2 + 1)),
                "right": ((r, c2) for r in range(r1, r2 + 1)),
                "top": ((r1, c) for c in range(c1, c2 + 1)),
                "bottom": ((r2, c) for c in range(c1, c2 + 1)),
            }
            missing = [sides[side] for side, points in edges.items()
                       if not all(has_line(r, c, side) for r, c in points)]
            if missing:
                missing_count += 1
                if len(samples) < 8:
                    samples.append(f"{area if area else cell.coordinate}（{'、'.join(missing)}）")
    if missing_count:
        rep.warn(ws.title, f"表格共 {missing_count} 个单元格或合并区域缺少边框：{'、'.join(samples)}；"
                 "请确认是否遗漏样式；若为使用者指定的排版可保留，不影响校验通过")


def check_attachment(cell, where, rep):
    """只校验链接形式及后缀，不打开文件、访问链接或推断截图真实性。"""
    if cell.hyperlink:
        targets = [text(cell.hyperlink.target)]
    else:
        value = text(cell.value)
        if value == "—":
            return
        targets = value.splitlines() or [""]
    for target in targets:
        target = target.strip()
        if not target:
            rep.error(where, "附件无截图时填 —；有截图时填写图片链接")
            continue
        markdown = re.fullmatch(r"\[[^\]]*\]\(([^()\r\n]+)\)", target)
        if markdown:
            target = markdown[1].strip()
        elif target.startswith("["):
            rep.error(where, "附件 Markdown 链接格式有误；多个截图链接须换行填写")
            continue
        path = re.split(r"[?#]", target, maxsplit=1)[0].lower()
        if not path.endswith((".png", ".jpg", ".jpeg", ".webp")):
            rep.error(where, "附件仅允许 PNG/JPG/JPEG/WebP 实际截图链接；trace、录像和报告不得填入附件列")


def support_rows(ws, rep):
    columns = SUPPORT_COLUMNS[ws.title]
    header_row = None
    for row in ws.iter_rows(min_row=1, max_row=min(ws.max_row, 10)):
        if text(row[0].value) == columns[0]:
            names = [text(c.value) for c in row]
            while names and not names[-1]:
                names.pop()
            if names != columns:
                rep.error(ws.title, "表头列名或列序应为：" + " | ".join(columns))
                return {}
            header_row = row[0].row
            break
    if header_row is None:
        rep.error(ws.title, "前 10 行找不到标准表头")
        return {}
    records = {}
    for row in ws.iter_rows(min_row=header_row + 1):
        values = [text(c.value) for c in row[:len(columns)]]
        if not any(values):
            continue
        item = dict(zip(columns, values))
        key = item[columns[0]]
        where = f"{ws.title} 第{row[0].row}行"
        if not re.fullmatch(SUPPORT_PREFIXES[ws.title] + r"\d{2,}", key):
            rep.error(where, f"编号应为 {SUPPORT_PREFIXES[ws.title]} 加至少两位数字")
        if key in records:
            rep.error(where, f"编号重复：{key}")
        for col in columns:
            if not item.get(col):
                rep.error(where, f"「{col}」不可留空，无内容填 —")
        records[key] = item
    if not records:
        rep.error(ws.title, "至少需要一条记录；不适用也须按模板登记原因")
    return records


def check_support_sheets(wb, cases, rep):
    tables = {}
    for name in SUPPORT_COLUMNS:
        if name not in wb.sheetnames:
            if name != "能力权限矩阵":
                rep.error("工作簿", f"缺少必备工作表「{name}」")
            tables[name] = {}
        else:
            tables[name] = support_rows(wb[name], rep)
    accounts, data, checks, permissions = (tables[n] for n in SUPPORT_COLUMNS)

    # 环境与批次属于这份数据清单，不读取或执行表格中的链接、SQL 或脚本。
    if "测试数据" in wb.sheetnames:
        meta = {}
        for row in wb["测试数据"].iter_rows(max_row=10, max_col=2):
            meta[text(row[0].value)] = text(row[1].value)
        for name in ("被测环境", "数据批次"):
            if meta.get(name, "") in EMPTY_MARKS:
                rep.error("测试数据", f"前 10 行须登记「{name}」及实际值（设计阶段可写待确认）")

    def linked(value, known, where, column):
        ids = references(value)
        if not ids:
            rep.error(where, f"「{column}」须填写关联编号")
        for key in ids:
            if key not in known:
                rep.error(where, f"「{column}」引用不存在的编号：{key}")
        return ids

    objects = accounts.keys() | data.keys()
    has_evidence = False
    for key, item in checks.items():
        where = f"造数核验 {key}"
        linked(item["核验对象"], objects, where, "核验对象")
        state = item["核验状态"]
        if state not in {"通过", "未通过", "未执行", "不适用"}:
            rep.error(where, "核验状态仅允许 通过 / 未通过 / 未执行 / 不适用")
        if state in {"通过", "未通过"}:
            for col in ("检查项", "预期条件", "实际读回结果", "证据位置"):
                if item[col] in EMPTY_MARKS:
                    rep.error(where, f"已核验时「{col}」须有实际内容")
            if not DATETIME.fullmatch(item["核验时间"]):
                rep.error(where, "已核验时须填写 yyyy-mm-dd HH:MM 核验时间")
            has_evidence = True
        else:
            for col in ("核验时间", "证据位置"):
                if item[col] not in EMPTY_MARKS:
                    rep.error(where, f"未执行/不适用时「{col}」应填 —")
            if state == "未执行" and item["实际读回结果"] not in EMPTY_MARKS:
                rep.error(where, "未执行不能填写实际读回结果")
            if state == "不适用" and item["实际读回结果"] in EMPTY_MARKS:
                rep.error(where, "不适用须在实际读回结果中说明原因")
    if has_evidence:
        rep.warn("造数核验", "仅检查证据位置已填写；交付须附证据文件或可访问链接，脚本不验证其内容真实性")

    for name, items in (("账号矩阵", accounts), ("测试数据", data)):
        for key, item in items.items():
            where = f"{name} {key}"
            ids = linked(item["关联核验编号"], checks, where, "关联核验编号")
            for check_id in ids:
                if check_id in checks and key not in references(checks[check_id]["核验对象"]):
                    rep.error(where, f"核验 {check_id} 未包含本对象 {key}")
            if name == "账号矩阵":
                for col in ("用户名 / 用户ID", "菜单及数据范围", "用途", "凭据配置项"):
                    if item[col] in EMPTY_MARKS:
                        rep.error(where, f"「{col}」须填写，匿名场景写不适用并在用途中解释")
                continue
            source = item["来源方式"]
            if source not in {"新建", "复用", "待准备", "不适用"}:
                rep.error(where, "来源方式仅允许 新建 / 复用 / 待准备 / 不适用")
            if item["是否被用例改变"] not in {"是", "否", "待确认", "不适用"}:
                rep.error(where, "是否被用例改变仅允许 是 / 否 / 待确认 / 不适用")
            if item["准备方法 / 脚本位置"] in EMPTY_MARKS:
                rep.error(where, "须写明准备/复用方法；不适用须解释原因")
            if source in {"新建", "复用"} and item["实际ID / 业务编码"] in EMPTY_MARKS:
                rep.error(where, "新建/复用须记录实际 ID 或业务编码，尚未取得时填待准备")
            if source in {"待准备", "不适用"} and item["实际ID / 业务编码"] not in EMPTY_MARKS:
                rep.error(where, "待准备/不适用时实际 ID 或业务编码应填 —")
            if source != "不适用" and item["初始状态及权限"] in EMPTY_MARKS:
                rep.error(where, "须写明初始状态及权限条件")
            expected = {"待准备": "未执行", "不适用": "不适用"}.get(source)
            if expected and any(checks[i]["核验状态"] != expected for i in ids if i in checks):
                rep.error(where, f"{source}数据的关联核验状态须为{expected}")

    covered_cases = set()
    for key, item in data.items():
        covered_cases.update(linked(item["关联用例编号"], cases, f"测试数据 {key}", "关联用例编号"))
    for key, item in cases.items():
        where = f"用例 {key}"
        if key not in covered_cases:
            rep.error(where, "测试数据页未关联此用例；无业务数据也须登记不适用记录")
        for prefix, known in (("A", accounts), ("D", data)):
            ids = re.findall(r"(?<![A-Za-z0-9_])" + prefix + r"\d{2,}(?![A-Za-z0-9_])", item["前置条件"])
            if not ids:
                rep.error(where, f"前置条件须引用 {prefix} 编号（账号/数据）")
            for ref in ids:
                if ref not in known:
                    rep.error(where, f"前置条件引用不存在的编号：{ref}")
                    continue
                if prefix == "D" and key not in references(known[ref]["关联用例编号"]):
                    rep.error(where, f"数据 {ref} 的关联用例编号未包含 {key}")
                if item["status"] == "passed":
                    for check_id in references(known[ref]["关联核验编号"]):
                        if check_id in checks and checks[check_id]["核验状态"] not in {"通过", "不适用"}:
                            rep.error(where, f"前置核验 {check_id} 未通过，不能将用例判为通过")

    rule = ""
    for row in wb.worksheets[0].iter_rows(max_row=80, max_col=2):
        if text(row[0].value).startswith("六、权限模型"):
            rule = text(row[1].value)
            break
    match = re.search(r"权限测试[：:]\s*(是|否)(?=[；;\s]|$)", rule)
    if not match:
        rep.error("说明", "六、权限模型须明确填写「权限测试：是」或「权限测试：否」并说明原因")
    elif not re.sub(r"权限测试[：:]\s*(是|否)[；;\s]*", "", rule).strip():
        rep.error("说明", "权限测试适用性须说明原因或依据")
    permission_cases = {key for key, item in cases.items() if PERMISSION_HINTS.search(item["测试场景"])}
    required = bool(permission_cases) or bool(match and match[1] == "是")
    if match and match[1] == "否" and permission_cases:
        rep.error("说明", "用例标题涉及权限/越权/隔离，不能将权限测试标为否")
    if required and not permissions:
        rep.error("工作簿", "涉及权限测试，须提供非空的「能力权限矩阵」")
    covered_permissions = set()
    for key, item in permissions.items():
        where = f"能力权限矩阵 {key}"
        ids = linked(item["关联用例编号"], cases, where, "关联用例编号")
        covered_permissions.update(ids)
        for col in ("能力", "权限条件", "预期行为", "规则依据"):
            if item[col] in EMPTY_MARKS:
                rep.error(where, f"「{col}」须填写；规则未知填待确认，不得编造")
        states = [cases[i]["status"] for i in ids if i in cases]
        expected = ("未通过" if "failed" in states else "通过" if states and all(s == "passed" for s in states)
                    else "未执行" if states and all(s == "not_run" for s in states) else "部分未执行")
        if item["验收汇总"] != expected:
            rep.error(where, f"验收汇总须按关联用例结果填写：{expected}")
    for key in sorted(permission_cases - covered_permissions):
        rep.error("能力权限矩阵", f"未覆盖权限用例 {key}")


def numbered_count(value):
    """按 1. / 1、/ 1) 编号统计条数；无编号但有内容按 1 条算。"""
    t = text(value)
    if not t:
        return 0
    nums = [int(n) for n in NUM_MARK.findall(t)]
    if not nums:
        return 1
    # 只认从 1 开始连续递增的编号，避免把正文里的数字算进去
    expected = list(range(1, len(nums) + 1))
    return len(nums) if nums == expected else len(set(nums))


def split_items(value):
    """把「1. xxx；2. yyy」拆成 {1: xxx, 2: yyy}；无编号返回 {1: 全文}。"""
    t = text(value)
    if not t:
        return {}
    marks = list(NUM_MARK.finditer(t))
    if not marks:
        return {1: t}
    items = {}
    for i, m in enumerate(marks):
        start = m.end()
        end = marks[i + 1].start() if i + 1 < len(marks) else len(t)
        items[int(m.group(1))] = t[start:end].strip(" \t\r\n；;，,。")
    return items


def parse_result(value):
    """返回 (kind, steps, reasons)。

    kind: all_pass / all_none / per_step / invalid
    """
    t = text(value)
    if t == "通过":
        return "all_pass", {}, {}
    if t == "未执行":
        return "all_none", {}, {}
    pairs = {}
    reasons = {}
    for m in RESULT_ITEM.finditer(t):
        num = int(m.group(1))
        status = m.group(2)
        if num in pairs and pairs[num] != status:
            return "invalid", pairs, reasons
        pairs[num] = status
        if status == "未通过":
            tail = t[m.end():]
            cut = [p for p in (tail.find("；"), tail.find(";"), tail.find("。")) if p >= 0]
            seg = tail[: min(cut)] if cut else tail
            reasons[num] = seg.strip(" \t（()）")
    if not pairs:
        return "invalid", {}, {}
    return "per_step", pairs, reasons


def result_status(kind, pairs):
    """把验证结果归为 passed / failed / not_run / invalid。"""
    if kind == "all_pass":
        return "passed"
    if kind == "all_none":
        return "not_run"
    if kind != "per_step":
        return "invalid"
    values = set(pairs.values())
    if "未通过" in values:
        return "failed"
    if "未执行" in values:
        return "not_run"
    return "passed" if values == {"通过"} else "invalid"


def find_section_row(ws, keyword, max_row=200):
    for row in ws.iter_rows(min_row=1, max_row=min(ws.max_row, max_row)):
        for cell in row:
            if keyword in text(cell.value):
                return cell.row
    return None


def row_numbers(ws, row):
    vals = []
    for cell in ws[row]:
        if isinstance(cell.value, (int, float)):
            vals.append(int(cell.value))
        else:
            m = re.fullmatch(r"\s*(\d+)\s*", text(cell.value))
            if m:
                vals.append(int(m.group(1)))
    return vals


def check_description_sheet(ws, summary, sheet_counts, rep):
    where = f"说明页 {ws.title}"
    found = set()
    for row in ws.iter_rows(min_row=1, max_row=min(ws.max_row, 80)):
        for cell in row:
            t = text(cell.value)
            m = re.match(r"^(" + "|".join(BLOCKS) + r")、", t)
            if m:
                found.add(m.group(1))
    missing = [b for b in BLOCKS if b not in found]
    if missing:
        rep.error(where, "缺少区块：" + "、".join(f"{b}、" for b in missing))

    # 第九节：执行统计
    sec = find_section_row(ws, "执行统计")
    stats = {}
    if sec is None:
        rep.error(where, "找不到「执行统计」区块")
    else:
        for r in range(sec + 1, min(sec + 12, ws.max_row) + 1):
            cells = list(ws[r])
            label = None
            label_idx = None
            for i, cell in enumerate(cells[:3]):
                t = text(cell.value)
                if t in ("通过", "未通过", "未执行", "合计"):
                    label, label_idx = t, i
                    break
            if label:
                nums = []
                for cell in cells[label_idx + 1:]:
                    if isinstance(cell.value, (int, float)):
                        nums.append(int(cell.value))
                    elif re.fullmatch(r"\s*\d+\s*", text(cell.value)):
                        nums.append(int(text(cell.value)))
                if nums:
                    stats[label] = nums[0]
        if stats:
            expect = {
                "通过": summary["passed"],
                "未通过": summary["failed"],
                "未执行": summary["not_run"],
                "合计": summary["total"],
            }
            for label, want in expect.items():
                if label not in stats:
                    rep.error(where, f"执行统计缺少“{label}”行")
                elif stats[label] != want:
                    rep.error(where, f"执行统计“{label}”={stats[label]}，明细页实际={want}")
        else:
            rep.error(where, "执行统计表里读不到数字")

    # 第十节：各能力用例数量
    sec = find_section_row(ws, "各能力用例数量")
    if sec is None:
        rep.error(where, "找不到「各能力用例数量」区块")
    else:
        counts = {}
        for r in range(sec + 1, min(sec + 20, ws.max_row) + 1):
            cells = list(ws[r])
            name = text(cells[0].value) if cells else ""
            if re.match(r"^(十|十一|十二)、", name) or "脚本与用例对应统计" in name:
                break
            if not name or name in ("能力（工作表）", "能力", "合计"):
                continue
            nums = row_numbers(ws, r)
            if nums:
                counts[name] = nums[-1]
        if not counts:
            rep.warn(where, "各能力用例数量表未读到数据（若尚未生成可忽略）")
        else:
            for name, expected in sheet_counts.items():
                if name not in counts:
                    rep.error(where, f"各能力用例数量表缺少工作表「{name}」")
                elif counts[name] != expected:
                    rep.error(where, f"能力「{name}」用例数={counts[name]}，明细页实际={expected}")
            for name in counts:
                if name not in sheet_counts:
                    rep.warn(where, f"各能力用例数量表里的「{name}」没有对应明细工作表")

    # 第十一节：脚本与用例对应统计
    header_row = None
    count_col = None
    for row in ws.iter_rows(min_row=1, max_row=min(ws.max_row, 200)):
        for i, cell in enumerate(row):
            if "TS 文件路径" in text(cell.value):
                header_row = cell.row
                break
        if header_row:
            for i, cell in enumerate(ws[header_row]):
                if text(cell.value) == "用例数":
                    count_col = i
                    break
            break
    if header_row is None:
        rep.error(where, "找不到「脚本与用例对应统计」表头（TS 文件路径）")
    elif count_col is None:
        rep.error(where, "脚本统计表缺少「用例数」列")
    else:
        total = 0
        seen_total = None
        for r in range(header_row + 1, min(header_row + 100, ws.max_row) + 1):
            cells = list(ws[r])
            first = text(cells[0].value) if cells else ""
            if not first and not any(text(c.value) for c in cells):
                break
            if first == "合计":
                cell = cells[count_col] if count_col < len(cells) else None
                v = text(cell.value) if cell else ""
                if re.fullmatch(r"\d+", v):
                    seen_total = int(v)
                break
            cell = cells[count_col] if count_col < len(cells) else None
            v = text(cell.value) if cell else ""
            if re.fullmatch(r"\d+", v):
                total += int(v)
        if seen_total is not None and seen_total != total:
            rep.error(where, f"脚本统计合计={seen_total}，各行相加={total}")
        if total != summary["total"]:
            rep.error(where, f"脚本统计用例数合计={total}，明细页实际={summary['total']}")


def load_report(path, rep):
    if path is None:
        return {}
    if not path.exists():
        rep.warn("report.json", f"未找到 {path}，跳过与执行记录的一致性校验")
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001
        rep.error("report.json", f"读取失败：{exc}")
        return {}
    if not isinstance(data, dict) or data.get("schemaVersion") != "report-1" or not isinstance(data.get("run"), dict) or not isinstance(data["run"].get("results"), list):
        rep.error("report.json", "仅支持原生 report-1 报告，不猜测未知结构中的执行结果")
        return {}
    index = {}
    for result in data["run"]["results"]:
        if not isinstance(result, dict):
            rep.error("report.json", "结果记录结构不合法")
            continue
        if result.get("selected") is False or result.get("kind") == "setup":
            continue
        ids = [tag[5:] for tag in result.get("tags", []) if isinstance(tag, str) and tag.startswith("case:")]
        if len(ids) > 1 or (ids and not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{1,79}", ids[0])):
            rep.error("report.json", "用例的 case: 编号标签不合法或超过一个")
            continue
        if ids:
            index.setdefault("case:" + ids[0], []).append(result)
            continue
        # 未编号旧用例仍按精确标题兼容；已有编号时绝不退回标题猜测。
        title_path = result.get("titlePath") or []
        title = title_path[-1] if title_path else ""
        if title:
            index.setdefault("title:" + text(title), []).append(result)
    return index


def report_matches(index, case_id, title):
    return index.get("case:" + case_id, index.get("title:" + title, []))


def check_detail_sheet(ws, report_index, rep, summary, sheet_counts, cases):
    where = f"明细页 {ws.title}"
    header_row = None
    header = {}
    for row in ws.iter_rows(min_row=1, max_row=min(ws.max_row, 10)):
        names = [text(c.value) for c in row]
        if "用例编号" in names and "验证结果" in names:
            while names and not names[-1]:
                names.pop()
            header_row = row[0].row
            header = {name: i for i, name in enumerate(names) if name}
            break
    if header_row is None:
        rep.error(where, "前 10 行找不到表头（需含「用例编号」「验证结果」）")
        return

    missing = [c for c in COLUMNS if c not in header]
    if missing:
        rep.error(where, "缺少列：" + "、".join(missing))
        return
    if names != COLUMNS:
        rep.error(where, "明细页固定为 16 列，列名与列序应为：" + " | ".join(COLUMNS))
        return

    idx = {name: header[name] for name in COLUMNS}
    empty_streak = 0
    for r in range(header_row + 1, ws.max_row + 1):
        cells = list(ws[r])

        def val(name):
            i = idx[name]
            return cells[i].value if i < len(cells) else None

        case_id = text(val("用例编号"))
        if not case_id:
            empty_streak += 1
            if empty_streak >= 5:
                break
            continue
        empty_streak = 0
        loc = f"{where} 第{r}行 {case_id}"

        title = text(val("测试场景"))
        matches = report_matches(report_index, case_id, title)
        steps = split_items(val("测试步骤"))
        expects = split_items(val("预期结果"))
        actual = text(val("实测结果"))
        result_raw = val("验证结果")
        kind, pairs, reasons = parse_result(result_raw)
        when = text(val("测试日期时间"))

        status = result_status(kind, pairs)
        if case_id in cases:
            rep.error(loc, f"用例编号重复：{case_id}")
        cases[case_id] = {
            "测试场景": title, "前置条件": text(val("前置条件")), "status": status,
        }
        summary["total"] += 1
        sheet_counts[ws.title] = sheet_counts.get(ws.title, 0) + 1

        if not title:
            rep.error(loc, "测试场景为空")
        if not steps:
            rep.error(loc, "测试步骤为空")
        if len(steps) != len(expects):
            rep.error(loc, f"步骤 {len(steps)} 条，预期 {len(expects)} 条，必须相等")
        check_attachment(cells[idx["附件"]], loc, rep)

        # 业务用例统一经 e2e 执行，证据由报告关联，不再填写执行来源。
        if kind == "all_none":
            if actual not in EMPTY_MARKS:
                rep.error(loc, "验证结果=未执行，实测结果应填 —")
        elif kind in {"all_pass", "per_step"}:
            if actual in EMPTY_MARKS:
                rep.error(loc, "已执行或部分执行的用例须填写实测结果")
            if not matches:
                rep.error(loc, f"e2e report.json 找不到编号 {case_id} 的已执行用例（旧用例兼容精确标题「{title}」），请提供本批次对应报告")

        # 验证结果格式
        if kind == "invalid":
            rep.error(loc, f"验证结果格式不合法：{text(result_raw)[:60]}")
        elif kind == "per_step":
            if status == "passed":
                rep.error(loc, "全部步骤通过时验证结果只写「通过」，不要逐条罗列")
            nums = sorted(pairs)
            if nums != list(range(1, len(steps) + 1)):
                rep.error(loc, f"验证结果步骤号 {nums} 与步骤条数 {len(steps)} 不匹配")
            for num, step_status in pairs.items():
                if step_status == "未通过" and not reasons.get(num):
                    rep.error(loc, f"第 {num} 步未通过，必须括注失败点，如「2：未通过（未出现确认卡片）」")
        elif kind == "all_pass" and not steps:
            rep.error(loc, "没有步骤却填「通过」")

        # 分类计数
        if status == "passed":
            summary["passed"] += 1
        elif status == "failed":
            summary["failed"] += 1
        elif status == "not_run":
            summary["not_run"] += 1

        # 时间
        if status == "not_run":
            if when not in EMPTY_MARKS:
                rep.warn(loc, "验证结果=未执行，测试日期时间应为 —")
        else:
            if not DATETIME.match(when):
                rep.error(loc, f"测试日期时间格式应为 yyyy-mm-dd HH:MM，当前「{when}」")

        # 与 report.json 状态核对
        if matches:
            if len(matches) > 1:
                rep.error(loc, f"report.json 中有 {len(matches)} 条对应执行实例，无法唯一关联，请限定目标、agent 或重复范围后提供报告")
            else:
                report_status = text(matches[0].get("status"))
                if report_status == "passed":
                    if kind != "all_pass":
                        rep.error(loc, "report.json 为 passed，验证结果却不是整条「通过」")
                elif report_status == "flaky":
                    if kind != "all_pass" or not re.search(r"重试|不稳定", text(val("备注"))):
                        rep.error(loc, "report.json 为 flaky，须记录通过并在备注明确「重试后通过」或不稳定情况，不隐藏首次失败")
                elif report_status == "failed":
                    if status != "failed":
                        rep.error(loc, "report.json 为 failed，验证结果必须标出未通过步骤")
                elif report_status == "skipped":
                    if kind != "all_none":
                        rep.error(loc, f"report.json 为 {report_status}，验证结果必须写「未执行」")
                elif report_status in ("timed-out", "interrupted"):
                    if kind == "all_pass":
                        rep.error(loc, f"report.json 为 {report_status}，不能填写整条通过；保留实际失败和未完成步骤")
                elif report_status == "blocked":
                    if "未执行" not in text(result_raw) and "未通过" not in text(result_raw):
                        rep.error(loc, "report.json 为 blocked，验证结果应为「未执行」或标未通过点")
                else:
                    rep.error(loc, f"report.json 包含未知状态 {report_status}，不可推断验收结论")


def check_workbook(wb, report_index, rep):
    """辅助页独立校验，不参与业务用例数量和执行结果统计。"""
    for ws in wb.worksheets:
        check_table_borders(ws, rep)
    first = wb.worksheets[0]
    if first.title != "说明":
        rep.error("工作簿", f"第一个工作表应为「说明」，当前是「{first.title}」")
    summary = {"total": 0, "passed": 0, "failed": 0, "not_run": 0}
    detail_sheets = [ws for ws in wb.worksheets[1:] if ws.title not in SUPPORT_COLUMNS]
    if not detail_sheets:
        rep.error("工作簿", "没有明细工作表")
    sheet_counts, cases = {}, {}
    for ws in detail_sheets:
        check_detail_sheet(ws, report_index, rep, summary, sheet_counts, cases)
    check_description_sheet(first, summary, sheet_counts, rep)
    check_support_sheets(wb, cases, rep)
    return summary


def main(argv):
    if len(argv) < 2 or len(argv) > 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    xlsx = Path(argv[1]).expanduser()
    if not xlsx.exists():
        print(f"找不到文件：{xlsx}", file=sys.stderr)
        return 2
    default_report = Path(__file__).resolve().parent.parent / ".e2e" / "report.json"
    draft = len(argv) == 3 and argv[2] == "--draft"
    report_path = Path(argv[2]).expanduser() if len(argv) == 3 and not draft else default_report

    rep = Report()
    try:
        wb = openpyxl.load_workbook(xlsx, data_only=True)
    except Exception as exc:  # noqa: BLE001
        print(f"无法打开 Excel：{exc}", file=sys.stderr)
        return 2

    if not wb.worksheets:
        print("Excel 里没有工作表", file=sys.stderr)
        return 2
    report_index = {} if draft else load_report(report_path, rep)
    summary = check_workbook(wb, report_index, rep)
    if draft and (summary["passed"] or summary["failed"]):
        rep.error("草稿", "设计校验不接受历史执行结果；本轮尚未执行的用例须填未执行，不继承旧结论")
    if draft:
        for ws in wb.worksheets[1:]:
            if ws.title in SUPPORT_COLUMNS:
                continue
            for row in ws.iter_rows(min_row=1, max_row=min(ws.max_row, 10)):
                names = [text(c.value) for c in row]
                if names[:len(COLUMNS)] == COLUMNS:
                    for cells in ws.iter_rows(min_row=row[0].row + 1):
                        if text(cells[0].value) and text(cells[12].value) not in EMPTY_MARKS:
                            rep.error(f"{ws.title} 第{cells[0].row}行", "草稿测试日期时间须填 —")
                    break

    for line in rep.warnings:
        print(line)
    for line in rep.errors:
        print(line)
    print(
        f"\n共 {summary['total']} 条用例：通过 {summary['passed']} / 未通过 {summary['failed']}"
        f" / 未执行 {summary['not_run']}；error {len(rep.errors)}，warning {len(rep.warnings)}"
    )
    return 0 if not rep.errors else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
