# 固定生成 Excel 初稿

测试人员继续用自然语言指挥 AI。AI 探索并设计用例后只填写结构化内容，调用维护者维护的生成器；列、辅助页、样式、统计和关联校验不再逐次编写。业务格式仍以 [测试用例文档格式](../templates/测试用例文档格式.md) 为准。

## 使用

在 `e2e/` 执行：

```bash
npm run test:cases -- draft exports/模块/初稿内容.json --output exports/模块/用例初稿.xlsx
```

输入推荐放在 `exports/<模块>/` 或 `scratch/<模块>/<场景>/`。输出只允许这两个忽略目录内的 `.xlsx`，拒绝路径越界及软链接。Python 沿用已有 `openpyxl` 依赖，默认 `python3`；用 `E2E_PYTHON` 指定其他解释器（Windows 可设为本机 Python 的完整路径）。

工具自动生成固定说明、16列明细、账号矩阵、测试数据、造数核验；权限测试生成权限矩阵。它补齐账号/数据前置引用，按用例引用生成数据关联编号，按准备记录生成核验对象，并汇总各能力与总数。所有业务结果强制未执行，不编造实际ID、核验事实或证据，不创建审核回执。

先校验输入和工作簿，再保存并复核格式和业务读取能力，最后原子创建目标。错误编号、缺少引用、步骤/预期不等长、权限适用性矛盾等不会交付半成品。返回文件路径、条数、校验结果、指纹和内部耗时；耗时不含 Python 启动、AI 设计和视觉检查。不连接业务环境或自动造数。

## 输入字段

可用示例：[用例初稿示例.json](../templates/用例初稿示例.json)。实际使用须替换业务内容和署名。

| 顶层字段 | 要求 |
| --- | --- |
| `schemaVersion` | 固定 `eoffice-case-draft-1` |
| `title`、`author` | 功能名、实际创建人，不使用固定人名冒充署名 |
| `createdAt` | 可省略，工具取东八区时间；指定时为 `yyyy-mm-dd HH:MM` |
| `scope`、`entry` | 业务范围、实探入口及依据，写明菜单/权限适用范围 |
| `environment`、`dataBatch` | 环境和数据批次，未知写待确认 |
| `constraints` | 确认机制、数据消耗、复跑与保留等业务约束 |
| `permissionTesting` | `{ "enabled": true或false, "reason": "依据或不适用原因" }` |
| `sheets` | 1～12个场景页，每项 `{ "name": "场景名", "cases": [...] }`，总用例最多1000条 |
| `accounts`、`data`、`checks` | 必备准备记录；权限测试另填 `permissions` |

每条用例：

| 字段 | 要求 |
| --- | --- |
| `id`、`module`、`type`、`priority`、`scenario` | 稳定编号、模块、模板规定类型、P0/P1/P2、明确验收结论 |
| `accounts`、`data` | A、D编号数组；不适用也引用相应记录 |
| `preconditions`、`steps`、`expected` | 非空文本数组，工具自动编号，不重复填编号前缀；步骤/预期条数相等 |
| `remarks` | 可选的实际补充或待确认点 |
| `author`、`createdAt` | 可选的本条创建信息，默认继承顶层实际署名和时间 |

辅助记录：

| 数组 | 字段 |
| --- | --- |
| `accounts` | `id`（A编号）、`username`、`department`、`role`、`scope`、`purpose`、`credential`、`checks`（V编号数组） |
| `data` | `id`（D编号）、`source`（待准备/不适用）、`method`、`initialState`、`mutates`（是/否/待确认/不适用）、`checks`（V编号数组） |
| `checks` | `id`（V编号）、`items`、`expected`；确实不适用时增加 `notApplicableReason`，否则为未执行 |
| `permissions` | `id`（P编号）、`capability`、`condition`、`expected`、`basis`、`cases`（关联业务编号数组） |

`credential` 仅写环境变量/Secret名称，不填密码、token。输入不接受 `result` 或实测通过等执行字段；以 `=` 等字符开头的业务文本也只作为字符串保存。

JSON最大2 MB，单文本字段最大4000字符，数组最多30项，辅助记录各最多1000条；超过 Excel 可显示行高会要求精简或拆分，避免静默截断。

## 首次生成以后

JSON只是一份首次生成输入，不成为第二份持续维护的业务标准。交付后以测试人员审查的最新 Excel 为准，按编号局部维护，保留文件名、原路径、备注、反馈号和样式。

生成器没有覆盖开关，重复生成同一路径也会失败；不得删除原表绕过保护。统计在初次生成时按输入计算；后续执行结果及统计由 AI 在原 Excel 局部更新，并用明确批次报告校验。本入口不自动同步 JSON、回填结果或归档。

先通过结构校验再进行视觉检查，避免错误版本重复预览。人工审查确认后继续 [审核、执行与定稿流程](Excel用例工作流.md)。

生成器及示例、规范、校验器由核心维护者维护；测试侧只填写业务输入并调用。
