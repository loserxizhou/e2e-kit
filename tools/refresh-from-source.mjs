#!/usr/bin/env node
// 从主仓库 e2e/ 导出框架文件 → 裁剪内部内容 → 脱敏 → 转成 templates/*.tpl。
// 用法：node tools/refresh-from-source.mjs [源仓库根目录]
//   源仓库自动识别：参数 > E2E_SOURCE_REPO > kit 所在目录父级（kit 放在源仓库内）> 同级 eoffice10_dev。
// 手工维护模板（存在即跳过，不覆盖）：readme.md.tpl、env.example.tpl、agents-route.md。
// 每条替换规则带命中数校验：脱敏类规则 0 命中直接报错，防止源文件演变后静默漏脱敏。

import { execSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const KIT_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const TEMPLATES_DIR = join(KIT_ROOT, 'templates');

// 手工维护的模板：脚本永不覆盖（内容见各自文件头注释与 MAINTENANCE.md）。
const HAND_MAINTAINED = new Set(['readme.md.tpl', 'env.example.tpl', 'agents-route.md']);

// 不随 kit 分发的内部内容（相对源仓库 e2e/ 目录）。
const PRUNE = ['tests/办公用品', 'knowledge', 'docs/办公用品接管清单.md'];

// 源文件 → 模板名。未列出的文件一律 `<相对路径>.tpl`。
const RENAME = new Map([
  ['.gitignore', 'gitignore.txt'],
]);

/** 递归列出目录下全部文件（相对路径）。 */
function listFiles(dir) {
  const out = [];
  const walk = (current) => {
    for (const name of readdirSync(current)) {
      const abs = join(current, name);
      if (statSync(abs).isDirectory()) walk(abs);
      else out.push(relative(dir, abs));
    }
  };
  walk(dir);
  return out.sort();
}

/** 全局替换：作用于所有导出文件。critical 为 true 时 0 命中报错。 */
const GLOBAL_TRANSFORMS = [
  { find: '192.168.30.197', replace: '192.0.2.10', critical: true },
  { find: '办公用品', replace: '示例模块', critical: true },
  { find: 'TASK-AI-', replace: 'DEMO-AI-', critical: true },
  { find: '已提 BP 填 DT 编号，否则 —', replace: '已反馈填缺陷编号，否则 —', critical: true },
  { find: '已知缺陷已提 BP 填 DT 编号；否则 —', replace: '已知缺陷已反馈填缺陷编号；否则 —', critical: true },
  { find: '「DT2026xxxx 修好了', replace: '「那个缺陷单修好了', critical: true },
  { find: 'Codex、ZCode、Claude Code 等', replace: 'Codex、Claude Code 等', critical: true },
  { find: 'Codex / ZCode / Claude Code 等', replace: 'Codex / Claude Code 等', critical: true },
  { find: '上海时间', replace: '东八区时间', critical: true },
  { find: '本地 ng serve + MAMP + AI 后端都是单实例', replace: '本地 dev server 与 AI 后端都是单实例' },
];

/** 按源文件（相对 e2e/）追加的精准改写。 */
const FILE_TRANSFORMS = {
  'scripts/forward-test-env.mjs': [
    {
      find: "// 用法：node scripts/forward-test-env.mjs [本机端口 目标IP 目标端口]\n// 默认：8010 192.0.2.10 8010（跑测试期间保持运行，Ctrl+C 停止并清除登记）",
      replace: "// 用法：node scripts/forward-test-env.mjs [本机端口] <目标IP> [目标端口]；目标 IP 必填\n// 示例：node scripts/forward-test-env.mjs 8010 192.0.2.10 8010（跑测试期间保持运行，Ctrl+C 停止并清除登记）",
      critical: true,
    },
    {
      find: "const [listenPortArg, targetHost, targetPortArg] = process.argv.slice(2);\nconst listenPort = Number(listenPortArg ?? 8010);\nconst targetPort = Number(targetPortArg ?? 8010);\nconst host = targetHost ?? '192.0.2.10';",
      replace: "const [listenPortArg, targetHost, targetPortArg] = process.argv.slice(2);\nif (!targetHost) {\n  console.error('用法：node scripts/forward-test-env.mjs [本机端口] <目标IP> [目标端口]；目标 IP 必填');\n  process.exit(1);\n}\nconst listenPort = Number(listenPortArg ?? 8010);\nconst targetPort = Number(targetPortArg ?? 8010);\nconst host = targetHost;",
      critical: true,
    },
  ],
  'package.json': [
    { find: '"e2e": "0.22.0"', replace: '"e2e": "{{E2E_VERSION}}"', critical: true },
    { find: '"@e2e-dev/web": "0.15.4"', replace: '"@e2e-dev/web": "{{WEB_VERSION}}"', critical: true },
  ],
  'docs/运行与结果管理.md': [
    { find: '当前 `tests/` 已有示例模块存量模块，仍需按接管清单迁移；', replace: '', critical: true },
    {
      find: '2026-11-02 核对 npm 官方 registry 与 GitHub releases 后升级为 e2e 0.22.0 / Web 0.15.4；框架已内含修复后的 Zod 4.6.7，无需保留临时 override。填密后模型截图规则随版本变化，参见 README；现有接口登录保持原样。新增类型检查依赖随锁文件分发，新机器执行 `npm ci`。项目规范仍通过 Git 更新，现有 kit/Skill 已能读取 README，无需重发 kit 或修改本机 Skill；本轮未重发分发包。',
      replace: '框架与依赖版本由锁文件固定，新机器在 e2e 目录执行 `npm ci`；填密后模型截图规则随版本变化，参见 README。',
    },
    {
      find: '已补充 Excel 审核指纹、批次快照、结果索引和归档检查；后续基于真实试点补业务步骤映射、确定性 Excel 导出、共享归档和 CI。',
      replace: '已提供 Excel 审核指纹、批次快照、结果索引和归档检查。',
    },
  ],
  'docs/维护与提交标准.md': [
    { find: '测试任务也不得修改被测系统的 `client/`、`server/` 等代码来让用例通过。', replace: '测试任务也不得修改被测系统自身的源代码来让用例通过。' },
    { find: '- 项目规则通过 Git 同步。现有 kit/Skill 已能引导读取项目 README 和 AGENTS.md，本次规则更新不要求重新安装 kit 或分发压缩包。\n', replace: '' },
  ],
  'docs/Excel用例工作流.md': [
    { find: '项目规范通过 Git 更新，现有 kit 读取 README/AGENTS 的入口继续有效，无需重发安装包。', replace: '' },
  ],
  'docs/初稿生成入口.md': [
    { find: '项目规范随 Git 更新，现有 kit/Skill 读取 README/AGENTS 的入口继续有效，本轮不修改已安装副本或重发分发包。', replace: '' },
  ],
  'templates/写测试.md': [
    { find: '造数/筛选先读多语言字段知识。', replace: '' },
    {
      find: '维护本模板、校验器或流程时读取 e2e-kit Skill。现有入口能读取项目 README/AGENTS 时，日常规范通过 Git 更新，不改已安装副本或重发分发包。',
      replace: '本模板与配套脚本属于框架文件，由 e2e-kit 统一升级（e2e-kit upgrade）；发现框架缺陷保留证据交接维护者，不手改框架文件绕过。',
    },
  ],
  'templates/测试用例文档格式.md': [
    {
      find: '**配套 kit 按需维护**：修改本模板、生成入口或校验脚本时，读取项目的 e2e-kit Skill 并检查现有入口能否继续读取项目规范。日常用例、文档格式和执行细则在本仓库维护，通过 Git 同步；现有 Skill 已能引导读取时，不修改 Skill、已安装副本或分发包。仅初始化/运行入口、安装兼容性、依赖或 kit 自身缺陷确需调整时再维护 kit，并集中发布；Skill 保持简洁，不复制项目细则。初始化只补缺，不代替已有项目的规范更新，不覆盖其他项目定制。',
      replace: '**配套 kit 按需维护**：本模板、生成入口和校验脚本属于框架文件，由 e2e-kit 统一升级；日常用例、结果回填和执行细则在项目内维护。初始化只补缺，升级不覆盖项目内手改过的文件。',
    },
  ],
  'docs/怎么指挥AI跑测试.md': [
    {
      find: '**收到升级通知时**：先结束正在运行的测试并关闭活跃 MCP 会话，拉取最新 Git 代码，然后在 `e2e` 目录执行 `npm ci`、`npm run sync`，最后重启客户端。可直接对 AI 说：「按 README 的已安装电脑升级流程同步本机，保留我的环境配置和草稿。」已有 e2e-kit Skill 不需要重装；官方 e2e Skill 由同步命令更新。WorkBuddy / ZCode / DSH 等客户端按同步命令输出的 MCP 片段更新接入，详细说明见 [README](../README.md#已安装电脑升级团队通过-git-分发)。',
      replace: '**收到升级通知时**：先结束正在运行的测试并关闭活跃 MCP 会话，运行 `e2e-kit upgrade` 刷新框架文件（手改过的文件会被跳过并列出），然后在 e2e 目录执行 `npm ci`、`npm run sync`，最后重启客户端。可直接对 AI 说：「按 e2e-kit 升级流程同步本机，保留我的环境配置和草稿。」',
      critical: true,
    },
  ],
  'docs/版本与变更记录.md': [
    {
      find: /### 迁移提示\n\n[\s\S]*?(?=\n## AI 使用口径)/,
      replace: '',
      regex: true,
      critical: true,
    },
  ],
};

// docs/ 与 templates/ 里的项目内路径统一模板化：e2e/<子路径> → {{DIR}}/<子路径>，以及 cd e2e &&。
const DIR_SCOPE = /^(docs|templates)\//;
const DIR_PATH_RE = /(^|[^\w.{}\/-])e2e\/(docs|helpers|templates|scratch|tests|scripts|knowledge|exports|\.env|\.gitignore|README|package\.json|package-lock\.json|tsconfig\.json|e2e\.config\.ts)/g;
const DIR_CD_RE = /cd e2e &&/g;

function applyTextTransforms(rel, text, rules, report) {
  let out = text;
  for (const rule of rules) {
    const before = out;
    if (rule.regex) out = out.replace(rule.find, rule.replace);
    else out = out.split(rule.find).join(rule.replace);
    const hits = rule.regex
      ? (before.match(new RegExp(rule.find.source, rule.find.flags.includes('g') ? rule.find.flags : rule.find.flags + 'g')) ?? []).length
      : (before.split(rule.find).length - 1);
    const label = `${rel} :: ${rule.regex ? rule.find.source : rule.find.slice(0, 40)}`;
    report.push({ label, hits, critical: rule.critical });
  }
  return out;
}

// 最终门禁：脱敏后的模板不允许再出现内部信息。client id 仅允许出现在代码类模板里。
const GATE_FORBIDDEN = ['办公用品', 'BGS-', 'PERM-', 'JBZL', '192.168.', 'bigmodel', 'BP 填 DT', 'DT2026', 'MAMP', '密码库', 'eoffice10_dev', '上海时间', 'WorkBuddy', 'ZCode', 'DSH'];
const GATE_CODE_ALLOWED = /^scripts\//; // 代码模板（运行时打印接入片段）允许出现 client id

function gate(rel, content, failures) {
  for (const pattern of GATE_FORBIDDEN) {
    if (!content.includes(pattern)) continue;
    if (['WorkBuddy', 'ZCode', 'DSH'].includes(pattern) && GATE_CODE_ALLOWED.test(rel)) continue;
    failures.push(`${rel} 含未脱敏内容：${pattern}`);
  }
}

function main() {
  const candidates = [
    process.argv[2],
    process.env.E2E_SOURCE_REPO,
    join(KIT_ROOT, '..'), // kit 放在源仓库内（如 eoffice10_dev/e2e-kit）
    join(KIT_ROOT, '..', 'eoffice10_dev'), // kit 单独克隆时的同级源仓库
  ];
  const sourceRepo = candidates
    .filter(Boolean)
    .map((p) => resolve(p))
    .find((p) => existsSync(join(p, 'e2e', 'package.json')));
  if (!sourceRepo) {
    console.error(`未找到源仓库（需含 e2e/package.json）。尝试过：\n${candidates.filter(Boolean).map((p) => `  - ${resolve(p)}`).join('\n')}\n请用参数或 E2E_SOURCE_REPO 指定。`);
    process.exit(1);
  }

  const tmp = mkdtempSync(join(tmpdir(), 'e2e-kit-refresh-'));
  try {
    execSync(`git -C ${JSON.stringify(sourceRepo)} archive HEAD e2e | tar -x -C ${JSON.stringify(tmp)}`, { shell: '/bin/bash' });
    const srcDir = join(tmp, 'e2e');
    for (const rel of PRUNE) {
      rmSync(join(srcDir, rel), { recursive: true, force: true });
    }

    const report = [];
    const written = [];
    const skipped = [];
    const gateFailures = [];
    for (const rel of listFiles(srcDir)) {
      let tplName = RENAME.get(rel) ?? `${rel}.tpl`;
      if (rel === '.env.example' || rel === 'README.md') {
        tplName = rel === '.env.example' ? 'env.example.tpl' : 'readme.md.tpl';
      }
      if (HAND_MAINTAINED.has(tplName) && existsSync(join(TEMPLATES_DIR, tplName))) {
        skipped.push(`${rel} → ${tplName}（手工维护，保留现版）`);
        continue;
      }
      let content = readFileSync(join(srcDir, rel), 'utf8');
      const globalHits = {};
      for (const rule of GLOBAL_TRANSFORMS) {
        const hits = content.split(rule.find).length - 1;
        globalHits[rule.find] = (globalHits[rule.find] ?? 0) + hits;
        content = content.split(rule.find).join(rule.replace);
      }
      for (const [pattern, hits] of Object.entries(globalHits)) {
        if (hits > 0) report.push({ label: `全局 :: ${pattern}`, hits });
      }
      if (FILE_TRANSFORMS[rel]) content = applyTextTransforms(rel, content, FILE_TRANSFORMS[rel], report);
      if (DIR_SCOPE.test(rel)) {
        const hitsDir = (content.match(DIR_PATH_RE) ?? []).length + (content.match(DIR_CD_RE) ?? []).length;
        content = content.replace(DIR_PATH_RE, '$1{{DIR}}/$2').replace(DIR_CD_RE, 'cd {{DIR}} &&');
        report.push({ label: `${rel} :: {{DIR}} 路径模板化`, hits: hitsDir });
      }
      gate(rel, content, gateFailures);
      const dest = join(TEMPLATES_DIR, tplName);
      mkdirSync(dirname(dest), { recursive: true });
      writeFileSync(dest, content);
      written.push(tplName);
    }

    // 清理本轮没有产出的陈旧模板（手工维护的除外），避免旧结构残留。
    const keep = new Set([...written, ...[...HAND_MAINTAINED].filter((name) => existsSync(join(TEMPLATES_DIR, name)))]);
    for (const rel of listFiles(TEMPLATES_DIR)) {
      if (keep.has(rel)) continue;
      rmSync(join(TEMPLATES_DIR, rel));
      console.log(`  - 已删除陈旧模板：${rel}`);
    }

    console.log(`已生成 ${written.length} 个模板，跳过 ${skipped.length} 个手工维护模板：`);
    for (const line of skipped) console.log(`  = ${line}`);

    const missed = report.filter((item) => item.critical && item.hits === 0);
    if (missed.length) {
      console.error('\n以下关键改写规则 0 命中（源文件可能已变化，请先更新本脚本再重跑）：');
      for (const item of missed) console.error(`  ✗ ${item.label}`);
    }
    if (gateFailures.length) {
      console.error('\n脱敏门禁未通过：');
      for (const line of gateFailures) console.error(`  ✗ ${line}`);
    }
    if (missed.length || gateFailures.length) process.exit(1);
    console.log('\n校验通过：模板生成完毕，脱敏门禁无命中。');
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}

main();
