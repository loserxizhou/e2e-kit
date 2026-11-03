// doctor：体检项目里的 e2e 配置是否可跑，不改任何文件。

import { dirname, join, resolve } from 'node:path';

import { findRepoRoot, locateProject, LocateError } from './lib/locate.mjs';
import { kitVersion } from './lib/kit.mjs';
import { dirExists, fileExists, readJson, readText } from './lib/util.mjs';

const KIT_VERSION = kitVersion();

const COLOR = process.stdout.isTTY;
const color = {
  ok: (s) => (COLOR ? `\x1b[32m${s}\x1b[0m` : s),
  warn: (s) => (COLOR ? `\x1b[33m${s}\x1b[0m` : s),
  bad: (s) => (COLOR ? `\x1b[31m${s}\x1b[0m` : s),
  dim: (s) => (COLOR ? `\x1b[2m${s}\x1b[0m` : s),
};

function parseArgs(argv) {
  const flags = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith('--')) continue;
    const key = arg.slice(2).replace(/-([a-z])/g, (_, ch) => ch.toUpperCase());
    const next = argv[i + 1];
    if (next && !next.startsWith('--')) {
      flags[key] = next;
      i += 1;
    } else flags[key] = true;
  }
  return flags;
}

export function runDoctor(argv) {
  const flags = parseArgs(argv);
  const checks = [];
  const add = (level, name, detail) => checks.push({ level, name, detail });

  const [major, minor, patch] = process.versions.node.split('.').map(Number);
  const nodeOk = major > 22 || (major === 22 && (minor > 22 || (minor === 22 && patch >= 3)));
  add(nodeOk ? 'ok' : 'bad', 'Node 版本', `${process.versions.node}（要求 >= 22.22.3）`);

  let located;
  try {
    located = locateProject({ project: flags.project, startDir: process.cwd() });
    add('ok', 'e2e 配置', located.config);
  } catch (err) {
    const level = err instanceof LocateError && err.code === 'NOT_INITIALIZED' ? 'warn' : 'bad';
    add(level, 'e2e 配置', err instanceof Error ? err.message.split('\n')[0] : String(err));
    report(checks, false);
    return 1;
  }

  const projectRoot = findRepoRoot(located.config);
  const dir = dirname(located.config);

  const marker = readJson(join(projectRoot, '.e2e-kit.json'), null);
  if (marker) {
    add('ok', '绑定标记', `.e2e-kit.json（e2e ${marker.e2eVersion ?? '?'}，环境 ${marker.env ?? '?'}）`);
    if (marker.e2eVersion) {
      const pkg = readJson(join(dir, 'package.json'), null);
      const installed = pkg?.devDependencies?.e2e ?? pkg?.dependencies?.e2e ?? null;
      if (installed && !String(installed).includes(marker.e2eVersion)) {
        add('warn', '版本一致性', `项目依赖 e2e=${installed}，标记为 ${marker.e2eVersion}`);
      } else {
        add('ok', '版本一致性', `e2e ${marker.e2eVersion}`);
      }
    }
  } else {
    add('warn', '绑定标记', '缺少 .e2e-kit.json（重跑 init 可补）');
  }

  const envPath = join(dir, '.env');
  if (!fileExists(envPath)) {
    add('bad', '.env', '不存在，复制 .env.example 后填写');
  } else {
    const text = readText(envPath);
    const readValue = (key) => {
      const line = text.split(/\r?\n/).find((l) => l.trim().startsWith(`${key}=`));
      return line ? line.slice(line.indexOf('=') + 1).trim() : '';
    };
    // 兼容旧版 kit 的变量名：新模板用 EOFFICE_ADMIN_*，旧项目可能仍是 E2E_USER/E2E_PASSWORD
    const required = [
      { key: 'APP_URL', alts: ['APP_URL'] },
      { key: 'EOFFICE_ADMIN_USER', alts: ['EOFFICE_ADMIN_USER', 'E2E_USER'] },
      { key: 'EOFFICE_ADMIN_PASSWORD', alts: ['EOFFICE_ADMIN_PASSWORD', 'E2E_PASSWORD'] },
    ];
    const missing = required.filter((item) => item.alts.every((key) => !readValue(key))).map((item) => item.key);
    add(missing.length ? 'warn' : 'ok', '.env', missing.length ? `缺少或为空：${missing.join('、')}` : '必填项齐全');
    const appUrlLine = text.split(/\r?\n/).find((l) => l.trim().startsWith('APP_URL='));
    const appUrl = appUrlLine ? appUrlLine.slice(appUrlLine.indexOf('=') + 1).trim() : '';
    if (appUrl && !appUrl.endsWith('/')) add('warn', 'APP_URL', '必须以 / 结尾');
    const aiKey = readValue('AI_API_KEY');
    add(
      aiKey ? 'ok' : 'warn',
      'AI 模型',
      aiKey
        ? '已配置，agent 用例可用'
        : '未配置：带 AI 步骤的用例将自动跳过（纯定位器用例不受影响）；要启用，在 e2e/.env 填 AI_* 四项',
    );
  }

  if (fileExists(join(dir, 'node_modules', 'e2e', 'package.json'))) {
    const installedVersion = readJson(join(dir, 'node_modules', 'e2e', 'package.json'), {})?.version;
    add('ok', '依赖安装', `e2e ${installedVersion}`);
  } else {
    add('warn', '依赖安装', '未安装：cd ' + dir + ' && npm ci');
  }

  const chromiumDirs = [];
  if (process.env.HOME) {
    chromiumDirs.push(
      join(process.env.HOME, 'Library', 'Caches', 'ms-playwright'),
      join(process.env.HOME, '.cache', 'ms-playwright'),
    );
  }
  if (process.env.LOCALAPPDATA) chromiumDirs.push(join(process.env.LOCALAPPDATA, 'ms-playwright'));
  const hasChromium = chromiumDirs.some((p) => dirExists(p));
  add(hasChromium ? 'ok' : 'warn', 'Chromium 内核', hasChromium ? '已安装' : '未检测到（有头模式需要）：node node_modules/playwright-core/cli.js install chromium');

  const gitignore = readText(join(projectRoot, '.gitignore'), '');
  const missingIgnore = ['.env', '.e2e*/', 'node_modules/'].filter((rule) => !gitignore.split(/\r?\n/).some((l) => l.trim() === rule));
  add(missingIgnore.length ? 'warn' : 'ok', '.gitignore', missingIgnore.length ? `缺少：${missingIgnore.join('、')}` : '规则齐全');

  const agents = readText(join(projectRoot, 'AGENTS.md'), '');
  add(agents.includes('e2e-kit:route:begin') ? 'ok' : 'warn', 'AGENTS.md 路由', agents.includes('e2e-kit:route:begin') ? '已写入' : '缺少测试路由条款（重跑 init 可补）');

  const skillDirs = ['.agents/skills/e2e-kit', '.claude/skills/e2e-kit', '.cursor/skills/e2e-kit'];
  const installedSkill = skillDirs.find((rel) => fileExists(join(projectRoot, rel, 'SKILL.md')));
  add(
    installedSkill ? 'ok' : 'warn',
    '客户端 skill',
    installedSkill ? `已安装：${installedSkill}` : '未安装（运行 init --client <codex|claude|cursor|dsh>）',
  );

  const mcpFiles = ['.mcp.json', '.codex/config.toml', '.cursor/mcp.json'];
  const configuredMcp = mcpFiles.find((rel) => readText(join(projectRoot, rel), '').includes('e2e'));
  add(
    configuredMcp ? 'ok' : 'warn',
    'MCP 配置',
    configuredMcp ? `已配置：${configuredMcp}` : '未配置（运行 init --client <客户端>，或按片段手工添加）',
  );

  const failed = checks.some((c) => c.level === 'bad');
  report(checks, !failed);
  return failed ? 1 : 0;
}

function report(checks, ok) {
  if (process.argv.includes('--json')) {
    console.log(JSON.stringify({ kit: KIT_VERSION, ok, checks }, null, 2));
    return;
  }
  console.log(`e2e-kit doctor v${KIT_VERSION}\n`);
  for (const check of checks) {
    const mark = check.level === 'ok' ? color.ok('✓') : check.level === 'warn' ? color.warn('!') : color.bad('✗');
    console.log(`${mark} ${check.name}：${check.detail}`);
  }
  console.log(ok ? color.ok('\n结论：可以继续') : color.bad('\n结论：有阻塞项，先修 ✗'));
}
