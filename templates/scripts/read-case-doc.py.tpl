"""只读提取 Excel 业务定义；不修改工作簿、不执行公式或表内命令。"""
import hashlib
from io import BytesIO
import json
from pathlib import Path
from types import SimpleNamespace
import re
import sys
from zipfile import ZipFile

import openpyxl

EMPTY_CELL = SimpleNamespace(value=None, data_type="n")


COLUMNS = ["用例编号", "所属模块", "用例类型", "优先级", "测试场景", "前置条件", "测试步骤", "预期结果",
           "实测结果", "验证结果", "备注", "附件", "测试日期时间", "反馈号", "创建人", "创建时间"]
SUPPORT = {"说明", "账号矩阵", "测试数据", "造数核验", "能力权限矩阵"}
DESIGN_SUPPORT = {
    "账号矩阵": ["账号代号", "用户名 / 用户ID", "部门", "角色", "菜单及数据范围", "用途", "凭据配置项", "关联核验编号"],
    "测试数据": ["数据编号", "关联用例编号", "准备方法 / 脚本位置", "初始状态及权限", "是否被用例改变", "关联核验编号"],
    "造数核验": ["核验编号", "核验对象", "检查项", "预期条件"],
    "能力权限矩阵": ["权限编号", "能力", "权限条件", "预期行为", "规则依据", "关联用例编号"],
}


def value(cell):
    if cell.data_type == "f":
        raise ValueError("业务定义不能使用公式，请将业务字段填写为明确文本")
    return str(cell.value).strip() if cell.value is not None else ""


def bounded_rows(sheet):
    # dimension 可缺省，也可能少报；按实际流式数据检查，不能信任声明的范围。
    sheet.reset_dimensions()
    for index, row in enumerate(sheet.iter_rows(), 1):
        if index > 10000 or len(row) > 64:
            raise ValueError("工作表实际规模超过限制（10000 行 / 64 列）")
        yield tuple(row) + (EMPTY_CELL,) * max(0, 16 - len(row))


def read_document(path):
    if path.suffix.lower() != ".xlsx" or path.stat().st_size > 20 * 1024 * 1024:
        raise ValueError("用例文档须为不超过 20 MB 的 xlsx")
    data = path.read_bytes()
    if len(data) > 20 * 1024 * 1024:
        raise ValueError("用例文档须为不超过 20 MB 的 xlsx")
    with ZipFile(BytesIO(data)) as archive:
        if sum(item.file_size for item in archive.infolist()) > 100 * 1024 * 1024:
            raise ValueError("用例文档解压大小超过限制")
    workbook = openpyxl.load_workbook(BytesIO(data), read_only=True, data_only=False, keep_links=False)
    try:
        if not workbook.worksheets or workbook.worksheets[0].title != "说明":
            raise ValueError("第一个工作表须为说明")
        cases, identities = [], set()
        for sheet in workbook:
            if sheet.title in SUPPORT:
                continue
            header = None
            for row_number, row in enumerate(bounded_rows(sheet), 1):
                if header is None:
                    names = [str(c.value).strip() if c.value is not None else "" for c in row]
                    if "用例编号" in names and "测试场景" in names:
                        while names and not names[-1]:
                            names.pop()
                        if names != COLUMNS:
                            raise ValueError("明细页须使用模板规定的 16 列与列序")
                        header = row_number
                    elif row_number >= 10:
                        raise ValueError("明细页前 10 行未找到表头")
                    continue
                identity = value(row[0])
                if not identity:
                    if any(value(cell) for cell in row[1:8]):
                        raise ValueError("业务行缺少用例编号")
                    continue
                if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{1,79}", identity) or identity in identities:
                    raise ValueError("用例编号不合法或重复")
                identities.add(identity)
                design = {key: value(row[i]) for i, key in enumerate(COLUMNS[:8])}
                if any(not design[key] for key in COLUMNS[:8]):
                    raise ValueError("业务定义的前 8 列须填写完整")
                cases.append({"id": identity, "sheet": sheet.title, "row": row_number, "design": design})
        if not cases:
            raise ValueError("没有找到业务用例")
        # 行/页顺序、样式、执行结果、备注、反馈号不改变业务审核版本。
        definitions = sorted((c["design"] for c in cases), key=lambda c: c["用例编号"])
        description, section = {}, None
        for row in bounded_rows(workbook.worksheets[0]):
            label = value(row[0])
            match = re.match(r"^([一二三四五六七八九十]+)、", label)
            if match:
                section = match[1] if match[1] in "一二三四五六七" else None
            if section:
                content = [value(cell) for cell in row]
                while content and not content[-1]:
                    content.pop()
                if any(content):
                    description.setdefault(section, []).append(content)
        support = {}
        for name, fields in DESIGN_SUPPORT.items():
            if name not in workbook.sheetnames:
                if name != "能力权限矩阵":
                    raise ValueError("缺少账号矩阵或测试数据工作表")
                continue
            sheet = workbook[name]
            indexes, records = None, []
            for row_number, row in enumerate(bounded_rows(sheet), 1):
                if indexes is None:
                    names = [str(c.value).strip() if c.value is not None else "" for c in row]
                    if fields[0] in names:
                        if not all(field in names for field in fields):
                            raise ValueError("准备工作表缺少业务字段")
                        indexes = {field: names.index(field) for field in fields}
                    elif row_number >= 10:
                        raise ValueError("准备工作表前 10 行未找到表头")
                elif value(row[indexes[fields[0]]]):
                    record = {field: value(row[indexes[field]]) for field in fields}
                    for field in ("关联用例编号", "关联核验编号", "核验对象"):
                        if field in record:
                            record[field] = "、".join(sorted(set(re.split(r"[\s,，、;；]+", record[field]))))
                    records.append(record)
            if indexes is None or not records:
                raise ValueError("准备工作表缺少表头或业务记录")
            if len({record[fields[0]] for record in records}) != len(records):
                raise ValueError("准备工作表编号重复")
            support[name] = sorted(records, key=lambda record: record[fields[0]])
        payload = json.dumps({"cases": definitions, "support": support, "description": description}, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        return {"schemaVersion": "eoffice-case-doc-1", "designHash": hashlib.sha256(payload.encode()).hexdigest(),
                "fileHash": hashlib.sha256(data).hexdigest(), "cases": cases, "supportDesign": support, "descriptionDesign": description}
    finally:
        workbook.close()


if __name__ == "__main__":
    try:
        print(json.dumps(read_document(Path(sys.argv[1])), ensure_ascii=False))
    except Exception as error:
        # 不输出可能包含业务定义或凭据的原始解析异常。
        message = str(error) if isinstance(error, ValueError) else "无法读取 xlsx，请检查文件及 Python/openpyxl 依赖"
        print(message, file=sys.stderr)
        sys.exit(2)
