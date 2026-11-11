# {{PROJECT_NAME}} e2e 测试

**项目工作流版本：`0.4.0`** · **底层 e2e：`{{E2E_VERSION}}` / Web `{{WEB_VERSION}}`**
AI 开始任何测试任务前，先读取[版本与变更记录](docs/版本与变更记录.md)，再读取[维护与提交标准](docs/维护与提交标准.md)和[Excel 用例工作流](docs/Excel用例工作流.md)。项目工作流版本和底层框架版本分别管理，不能把其中一个当成另一个。

基于 [tester-army/e2e](https://github.com/tester-army/e2e)：自然语言描述测试目标 + AI agent 驱动页面操作 + 传统定位器断言兜底；不含 agent 步骤的测试完全不需要模型。

本目录由 `e2e-kit` 初始化生成：初始化只补缺、不覆盖已有文件；框架文件（配置、脚本、模板、docs）通过 `e2e-kit upgrade` 统一升级，手改过的文件会被跳过并列出，业务用例与知识记录不受影响。

## 快速开始

```bash
# 1. Node 22.22.3+（22.x）或 24.8.0+（推荐 Node 24）
# 2. 配置（不进 Git）：填 APP_URL、测试账号；agent 用例另填 AI_* 四项
cp .env.example .env

# 3. 依赖与浏览器内核（内核是有头模式跑用例必需；官方源下载失败时用国内镜像：
#    PLAYWRIGHT_DOWNLOAD_HOST=https://cdn.npmmirror.com/binaries/playwright）
npm ci
npm run sync -- --client codex    # 换成实际客户端 claude / cursor，多选用逗号分隔

# 4. 冒烟自检
npm run test:run -- tests/login.e2e.ts
```

`sync` 安装匹配的 Chromium、刷新官方 e2e Skill，并配置项目级 MCP；其他客户端按同步命令输出的接入片段配置。完成后重启客户端。内网明文 HTTP 环境先按下方「配置」节启动 `npm run forward`，再冒烟。

## 测试人员的工作流

找模块已有用例 → AI 探索并生成 Excel 初稿 → 测试人员审查/对话调整 → 确认这个业务版本（`test:cases confirm`）→ AI 实现、准备和执行 → 按本批次回填/复测 → 明确确认后定稿。详见 [Excel 用例工作流](docs/Excel用例工作流.md)，AI 入口见 [写测试模板](templates/写测试.md)，指挥示例见[怎么指挥 AI 跑测试](docs/怎么指挥AI跑测试.md)。

Excel 是业务标准的审核入口，脚本承载执行；业务变化须重新确认，技术定位修正无需改业务标准。`test:cases` 提供固定初稿生成、模块查找、读取、审核记录、结果索引和归档检查；首次生成统一使用 `npm run test:cases -- draft <json> --output <xlsx>`（输入见[初稿生成入口](docs/初稿生成入口.md)），已有 Excel 按编号局部维护。

运行统一入口：`npm run test:run -- <tests或scratch具体范围> --case-doc <已审核xlsx>`（多份文档重复参数）。测试人员说「跑一下/跑一遍」时，AI 会先展示执行意图：`experience` 体验流程、`smoke` 冒烟验证、`formal` 正式执行、`resume` 继续上次批次；`scratch` 或绑定 Excel 时缺少 `--intent` 入口会拒绝启动。执行、回填与定稿口径见[运行与结果管理](docs/运行与结果管理.md)。

## 配置（全部在 `.env`）

| 变量 | 必填 | 说明 |
| --- | --- | --- |
| `APP_URL` | ✅ | 被测前端「应用根」地址，**必须以 `/` 结尾** |
| `EOFFICE_ADMIN_USER` / `EOFFICE_ADMIN_PASSWORD` | ✅ | 测试账号（auth.setup 用它登录并保存 session 'admin'） |
| `EOFFICE_E2E_LOGIN_MODE` | 否 | 默认通过同源接口准备 admin 会话；需走原登录页时设为 `ui` |
| `EOFFICE_TESTER_NAME` | 否 | 本机测试人员姓名，AI 生成 Excel 时的默认「创建人」署名 |
| `AI_PROVIDER` / `AI_BASE_URL` / `AI_MODEL` / `AI_API_KEY` | 否 | agent 步骤用；不配则 agent 用例自动跳过，回归库照常运行 |

`.env` 已 gitignore；不要提交、不要贴进聊天、不要写进代码。局域网测试机是明文 HTTP 时，框架只放行 127.x/localhost，需先启动本地转发：`npm run forward -- 8010 <测试机IP> 8010`（参数见 `scripts/forward-test-env.mjs` 头注释），配置会自动改经 127.0.0.1 接入。

## 目录

| 路径 | 说明 |
| --- | --- |
| `tests/` | 回归库（入库）；根部只放 `login`、`auth.setup` 等基础设施，业务用例按模块建子目录 |
| `scratch/` | 探索草稿（gitignore），定稿后按同构路径挪入 `tests/` |
| `templates/` | `写测试.md`（AI 写用例流程入口）、`测试用例文档格式.md`（Excel 格式唯一标准）、`用例初稿示例.json` |
| `docs/` | 工作流规范：Excel 工作流、维护与提交标准、运行与结果管理、版本与变更记录等 |
| `helpers/` | 公共操作封装（登录、智能办公面板），用例统一 import，测试任务不修改 |
| `scripts/` | 批次运行、用例文档工作流、环境转发等框架脚本 |
| `knowledge/` | 测试沉淀的避坑/经验/机制文档（有证据才收录，目录名用英文） |
| `exports/` | 生成的用例文档（Excel）输出目录（gitignore） |
| `.e2e/` | 运行产物（报告、trace、截图、缓存），gitignore |

## 维护边界

业务用例、场景 helper、用例 Excel/审核回执和有证据的知识记录由测试侧维护；`e2e.config.ts`、`package.json`、`scripts/**`、`templates/**`、`docs/**`、公共 helper 等框架文件由 e2e-kit 统一分发，测试任务不手改，遇到框架缺陷保留证据交接维护者。完整边界见 [维护与提交标准](docs/维护与提交标准.md)。

框架升级：运行 `e2e-kit upgrade`，先选择迁移模式。`safe` 只刷新有生成记录且未手改的框架文件；`adopt` 接管来源不明或手改的旧框架文件。两种模式都会按同一规则处理项目内的 e2e-kit Skill，`.env`、业务用例、草稿、知识和导出文件不会触碰。随后执行 `npm ci && npm run sync -- --client <客户端>`，重启客户端。升级与执行意图说明见[怎么指挥 AI 跑测试](docs/怎么指挥AI跑测试.md)。

## 常用命令

```bash
npm run test:run -- tests/                                   # 全量回归（批次入口）
npm run test:run -- tests/login.e2e.ts                      # 冒烟
npm run test:run -- scratch/<模块>/... --intent smoke        # 草稿冒烟（必须带意图）
npm run test:cases -- list --module <模块>                   # 查模块已有用例文档
npm run test:cases -- draft <json> --output <xlsx>           # 生成 Excel 初稿
npm run test:scope                                           # 改动归属检查（只读）
npm run check:core                                           # 框架自检（不开浏览器）
```

## 已知坑

- 非 loopback 主机只允许 HTTPS（框架策略）：内网明文 HTTP 先起本地转发（`npm run forward`，目标 IP 必填）；
- SPA 启动慢：先等关键元素可见，再交给断言或 agent；
- `browser` 是精简 API：没有 `getByRole`（在 `screen` 上），不支持链式 `.locator()`；
- 失败先看 `.e2e/` 下的 report/trace；agent 步骤跑绿后会被重放缓存，重跑不调模型。
