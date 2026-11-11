---
name: e2e-kit
description: 稳定的 e2e 项目路由入口。用于初始化、体检、显式框架迁移，以及指导 AI 使用项目内的 e2e 测试。
---

# e2e-kit：稳定路由入口

这个 Skill 只负责把请求路由到项目自己的 e2e 工程。项目内的 `e2e/README.md`、`e2e/docs/`、`e2e/templates/` 和根目录 `AGENTS.md` 是当前项目的规范来源；开始测试前先读取它们。Skill 本身不复制项目业务规则，也不因为新增业务用例而更新。

`<dir>` 读取项目根 `.e2e-kit.json` 的 `dir` 字段，默认是 `e2e`。`<kit>` 只在需要初始化、体检或显式迁移时使用。

| 用户请求 | 操作 |
| --- | --- |
| 初始化 e2e | `bash <kit>/run.sh`，向用户确认 APP_URL、账号和客户端；密码用 `E2E_INIT_PASSWORD` 传入 |
| 体检环境 | `node <kit>/bin/e2e-kit.mjs doctor --project .` |
| 明确升级框架 | `node <kit>/bin/e2e-kit.mjs upgrade --project .`；默认只迁移项目框架文件，不刷新已安装 Skill |
| 明确刷新 Skill/MCP | 在升级命令中加入 `--refresh-skill --client <客户端>`，然后重启客户端 |
| 跑回归 | `cd <dir> && npm run test:run -- --list` 预览，再按项目规范选择执行意图并运行 |
| 页面探查或定位器诊断 | 使用 e2e MCP 的 `open_session → observe → locate` |

日常写用例和跑测试不需要运行 `e2e-kit upgrade`。业务用例、断言、步骤证据和项目公共 helper 按项目 Git 维护；只有框架缺陷、依赖升级或初始化兼容性变化才做显式框架迁移。迁移前先看项目工作流版本和变更记录，选择 `safe` 或 `adopt`；默认使用 `safe`。

测试规则保持在项目中：先确认模块、流程、通过/失败标准和数据前提；先实探页面，再写定位器；新用例放 `scratch/`，确认后才进入 `tests/`。不要把外部 AI 通过 MCP 临时点击页面当作正式回归，也不要为了跑绿放宽断言。

框架迁移完成后，按项目 README 的说明执行依赖安装和必要的 `npm run sync`。`.env`、业务用例、草稿、知识库和导出文件属于项目资产，迁移工具不会主动覆盖。
