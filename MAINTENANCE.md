# 维护手册（MAINTENANCE）

本仓库是**公开分发仓库**：`templates/` 里的框架模板源自内部源仓库的 `e2e/` 目录，经裁剪与脱敏后发布。本手册记录刷新流程、脱敏边界和与源仓库的已知分叉点。仅维护者使用；日常使用者只需要 `run.sh` / `init` / `upgrade` / `doctor`。

## 模板刷新流程

源仓库演进后，重新生成模板并发布：

```bash
git pull                                  # 更新本仓库
node tools/refresh-from-source.mjs [源仓库根目录]   # 源仓库自动识别：kit 父级（放在源仓库内时）或同级 eoffice10_dev；也可用 E2E_SOURCE_REPO 指定
npm test                                  # 行为测试必须全绿
git add templates && git commit && git push
```

`refresh-from-source.mjs` 做四件事，全部带校验：

1. **导出**：`git archive HEAD e2e` 只取已提交内容（自动排除 `.env`、`scratch/`、`exports/`、`node_modules/`）；
2. **裁剪**：移除不随 kit 分发的内部内容（见下方清单）；
3. **脱敏**：应用替换表（内网 IP → 文档地址、内部模块名 → 示例模块、内部工单口径 → 缺陷编号、内部客户端名 → 通用表述等）；
4. **模板化**：`.tpl` 化并把 docs/templates 里的 `e2e/` 路径改为 `{{DIR}}` 占位符；随后跑**脱敏门禁**——任一禁词残留直接失败。

关键改写规则 0 命中会报错（源文件演变成新表述时，先更新脚本的替换表再重跑，防止静默漏脱敏）。

### 手工维护的模板（脚本永不覆盖）

| 模板 | 说明 |
| --- | --- |
| `templates/readme.md.tpl` | 生成项目的 README，按生成后语境手写（含 {{PROJECT_NAME}}/{{E2E_VERSION}}/{{WEB_VERSION}}） |
| `templates/env.example.tpl` | 环境配置模板，`EOFFICE_*` 变量 + 中性 AI 示例（静态内容，保证 upgrade 渲染可复现） |
| `templates/agents-route.md` | 写入项目 AGENTS.md 的测试路由块（{{DIR}} 化，含 upgrade 语义） |

刷新后需**人工复核**这三个模板是否需要跟进源仓库的语义变化。

### 与源仓库同步的其余锚点

- `bin/init.mjs` 的 `PAYLOAD` 清单（42 项映射）与 `templates/` 一一对应：源仓库新增/删除框架文件时，先跑 refresh，再同步改 PAYLOAD 与 `E2E_VERSION`/`WEB_VERSION` 常量；
- `bin/e2e-mcp.mjs` 的 `DEFAULT_E2E_VERSION`；
- `skills/e2e-kit/SKILL.md` 的入口命令示例。

## 裁剪清单（不随 kit 分发）

- `tests/<业务模块>/`（源仓库的业务回归用例、用例 Excel）——只保留 `tests/auth.setup.e2e.ts`、`tests/login.e2e.ts` 两个基础设施；
- `knowledge/`（内部经验库）；
- `docs/` 中的内部迁移/接管记录；
- `scratch/`、`exports/`、`.env` 天然不入库（源仓库已 gitignore）。

## 脱敏边界（发布红线）

发布前全仓库 grep 必须零命中（豁免 `tools/refresh-from-source.mjs` 的替换表自身与 `bin/`、`run.sh`、`skills/` 中的功能性 client id）：

- 内网地址：`192.168.`（统一替换为文档地址 `192.0.2.10`，forward 脚本已改为目标 IP 必填、无默认值）；
- 内部业务模块名与工单编号：内部模块示例统一改「示例模块」、`DEMO-AI-*`、「缺陷编号」；
- 内部工单/流程口径：BP/DT 工单、内部迁移状态、内部维护日志；
- 内部客户端名：WorkBuddy / ZCode / DSH 在叙述性文档中改通用表述（`bin/install.mjs`、`run.sh`、SKILL.md 中作为功能性标识保留）；
- 团队默认 AI 选型：`.env` 示例统一为中性 DeepSeek 示例。

## 与源仓库的已知分叉点

升级语义以本仓库 `bin/` 实现为准，以下差异是有意的：

1. `scripts/forward-test-env.mjs`：目标 IP 从「默认值」改为**必填参数**（公开版不携带内网默认地址）；
2. `.env.example`：AI 默认从内部选型改为中性示例；
3. `docs/`、`templates/` 中的内部语境（主仓库分发、kit 分发包、内部迁移提示）改写为独立项目口径；
4. `{{DIR}}` 占位符：docs/templates 中的 `e2e/` 路径按初始化目录名渲染；
5. payload `package.json` 的 `e2e`/`@e2e-dev/web` 版本由 `{{E2E_VERSION}}`/`{{WEB_VERSION}}` 渲染，与 init 常量保持一致。

## 版本与发布

- 本 kit 版本：`package.json` 的 `version`（当前 0.3.0），分发的工作流版本见 payload `eofficeWorkflowVersion` 与 `templates/docs/版本与变更记录.md.tpl`；
- 发布 = 提交并推送 main；同事侧通过 `git pull` + `e2e-kit upgrade` 获得更新；
- 发布前检查：`npm test` 全绿、`node tools/refresh-from-source.mjs` 门禁通过、全仓库脱敏 grep 零命中。
