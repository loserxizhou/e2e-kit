# eoffice-e2e

e-office e2e 测试一键接入工具包：**一条命令完成项目初始化 + 客户端 MCP/Skill 配置**，之后全部用自然语言让 agent 干活；框架升级不覆盖手改文件。

基于 [tester-army/e2e](https://github.com/tester-army/e2e)（自然语言测试目标 + AI agent 驱动页面操作 + 传统定位器断言兜底）。当前分发的工作流版本 `0.5.0`（e2e `0.22.0` / Web `0.15.4`）。

## 快速开始

```bash
# 1. 克隆本仓库（任意位置）
git clone https://github.com/loserxizhou/e2e-kit.git

# 2. 进入你的项目根目录，初始化（交互式；--client 省略时自动探测本机客户端）
cd <你的项目>
bash <克隆目录>/run.sh

# 远程一行（首次试用，不先克隆）
bash <(curl -fsSL https://raw.githubusercontent.com/loserxizhou/e2e-kit/main/run.sh)
```

初始化会自动：

1. 检查 Node ≥ 22.22.3；
2. 生成 `e2e/` 目录（config、`.env`、运行脚本、模板、docs、冒烟用例，共 42 个框架文件）；
3. 写该客户端的项目级 MCP 配置与 skill；
4. `npm ci` 安装依赖、装 Chromium、跑冒烟；
5. 打印结果与下一步。

重复执行是幂等的：已有文件一律跳过，只补缺。也可以初始化到任意空目录单独体验（不依赖具体项目）：`mkdir demo && cd demo && bash <克隆目录>/run.sh`。

## 环境前提

- Node 22.22.3+（22.x）或 24.8.0+（推荐 Node 24）；
- 一个可访问的 e-office 被测环境（`APP_URL`，局域网明文 HTTP 需先起本地转发，见生成后 README「配置」节）；
- 测试账号；使用 `agent.*` 步骤时另需 AI 模型 key（不配则 agent 用例自动跳过，纯定位器用例不受影响）。

## 初始化之后

对 agent 说人话即可：`跑一下 e2e 回归`、`给登录页加条用例：……`、`这条为什么红了`。

```bash
cd e2e && npm run test:run -- tests/login.e2e.ts   # 冒烟
cd e2e && npm run test:run -- tests/               # 全量回归（批次入口）
```

完整工作流（Excel 用例初稿 → 人工审核 → 实现 → 执行 → 回填 → 定稿）见生成项目内的 `e2e/docs/`。

## 升级已有 e2e

```bash
cd <本仓库克隆目录> && git pull
node bin/e2e-kit.mjs upgrade --project <你的项目>
# 随后：
cd <你的项目>/e2e && npm ci && npm run sync -- --client <客户端>
```

升级时会先询问迁移模式：

* `safe`（默认）：只刷新有生成记录且未被手改的框架文件；来源不明或手改文件跳过并列出。
* `adopt`：明确接管旧版框架文件，刷新来源不明或手改的框架文件；`.env`、业务用例、`scratch/`、`knowledge/`、`exports/` 等用户资产仍不会触碰。

非交互场景显式指定模式：

```bash
node bin/e2e-kit.mjs upgrade --project <你的项目> --migration safe --yes
node bin/e2e-kit.mjs upgrade --project <你的项目> --migration adopt --yes
```

升级同时按同一迁移模式刷新项目内的 `e2e-kit` Skill；Skill 被手改或来源不明时，`safe` 会保留并提示，`adopt` 才会接管。若项目使用 DSH，请显式传 `--client dsh`，因为它与 Codex 共用 `.agents/skills/e2e-kit/` 路径。

## 常用命令

```bash
bash run.sh                                   # 初始化/补缺（客户端自动探测）
bash run.sh --client workbuddy,zcode          # 显式指定客户端（探测不到的），逗号分隔多选
bash run.sh --update                          # 强制更新 ~/.e2e-kit 里的 kit 副本
  node bin/e2e-kit.mjs upgrade --project .      # 交互选择 safe/adopt 后升级框架与 Skill
node bin/e2e-kit.mjs doctor --project .       # 体检（只读，不改文件）
node bin/e2e-kit.mjs init --help              # 所有初始化参数
```

非交互（CI / 脚本）：

```bash
E2E_INIT_PASSWORD='***' bash run.sh --client codex --yes \
  --url http://192.0.2.10:8010/app/ --user admin
```

密码不要写在命令行里（会进 shell 历史），用 `E2E_INIT_PASSWORD`。

## 客户端支持

| 客户端 | `--client` | 写入内容 |
| --- | --- | --- |
| Codex | `codex` | `.codex/config.toml`（`[mcp_servers.e2e]`）+ `.agents/skills/e2e-kit/` |
| Claude Code | `claude` | `.mcp.json` + `.claude/skills/e2e-kit/` |
| Cursor | `cursor` | `.cursor/mcp.json` + `.cursor/skills/e2e-kit/` |
| DSH | `dsh` | `.agents/skills/e2e-kit/` + profile 补丁片段 |
| WorkBuddy | `workbuddy` | 连接器 JSON 片段（首次需在「自定义连接器」点信任） |
| ZCode | `zcode` | MCP servers 片段 |

省略 `--client` 或传 `--client auto` 均自动探测本机的 Codex / Claude Code / Cursor；WorkBuddy / ZCode / DSH 探测不到，需按上表显式指定。

## 目录

```
├── run.sh              # 一键引导（本地克隆 / 远程一行）
├── bin/
│   ├── e2e-kit.mjs     # CLI：init / upgrade / doctor / mcp
│   ├── init.mjs        # 识别、交互、生成、接入、安装、冒烟（payload 清单在此）
│   ├── upgrade.mjs     # 框架文件升级（sha256 记录比对）
│   ├── doctor.mjs      # 只读体检
│   ├── install.mjs     # 客户端配置写入（由 init 调用）
│   ├── e2e-mcp.mjs     # MCP 包装器（定位项目后启动 e2e mcp）
│   └── lib/            # locate / prompt / util / kit
├── skills/e2e-kit/     # 随包 skill
├── templates/          # 项目框架模板（42 个 payload + AGENTS 路由块）
├── tools/              # 维护工具：refresh-from-source.mjs（从源仓库刷新模板）
├── test/               # node:test 行为测试
└── MAINTENANCE.md      # 维护者手册：模板刷新流程与脱敏清单
```

## 自测与已知边界

```bash
npm test    # node --test test/*.test.mjs（无需外部环境）
```

覆盖：全新初始化、二次幂等、已有配置、Playwright 共存、目录冲突、定位歧义、`--client codex/claude` 接入、doctor、upgrade 刷新/跳过语义。

已知边界：

- `APP_URL` 是非 loopback 的明文 HTTP 时，框架只放行 127.x/localhost，需要先起本地转发（`npm run forward -- 8010 <测试机IP> 8010`，目标 IP 必填；冒烟失败会直接给出提示）；
- 登录流程适配在生成项目的 `helpers/auth-session.ts`（框架文件，手改后 upgrade 会跳过该文件）；
- MCP 进程在客户端启动时加载：首次配置完需要重启客户端；只跑测试不需要 MCP。
