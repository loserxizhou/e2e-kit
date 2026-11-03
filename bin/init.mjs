// e2e-kit init：体检 → 识别 → 交互 → 生成 → 接入 → 安装 → 冒烟 → 汇报。
// 原则：先识别后写入；只补不覆盖；所有生成文件记录 sha256，便于安全升级。
// payload 清单与 buildFiles 的模板映射保持一致；新增框架文件时同步维护两处。

import { spawnSync } from 'node:child_process';
import { existsSync, readdirSync } from 'node:fs';
import { basename, dirname, join, relative, resolve } from 'node:path';

import { configCandidatesIn, findRepoRoot, locateProject } from './lib/locate.mjs';
import { installClients, SUPPORTED_CLIENTS } from './install.mjs';
import { TEMPLATES_DIR as TEMPLATES, kitVersion } from './lib/kit.mjs';
import { ask, askHidden, isInteractive } from './lib/prompt.mjs';
import {
  dirExists,
  ensureDir,
  fileExists,
  loadTemplate,
  mergeIgnoreList,
  mergeMarker,
  mergeMarkedSection,
  posix,
  readJson,
  readText,
  render,
  sha256,
  writeText,
} from './lib/util.mjs';

const KIT_VERSION = kitVersion();
export const E2E_VERSION = '0.22.0';
export const WEB_VERSION = '0.15.4';

const COLOR = process.stdout.isTTY;
const c = {
  dim: (s) => (COLOR ? `\x1b[2m${s}\x1b[0m` : s),
  green: (s) => (COLOR ? `\x1b[32m${s}\x1b[0m` : s),
  yellow: (s) => (COLOR ? `\x1b[33m${s}\x1b[0m` : s),
  red: (s) => (COLOR ? `\x1b[31m${s}\x1b[0m` : s),
  bold: (s) => (COLOR ? `\x1b[1m${s}\x1b[0m` : s),
};

const KNOWN_FILES = new Set([
  'package.json',
  'package-lock.json',
  'e2e.config.ts',
  'tsconfig.json',
  '.env',
  '.env.example',
  '.gitignore',
  'README.md',
  'docs',
  'templates',
  'tests',
  'helpers',
  'scripts',
  'scratch',
  'knowledge',
  'exports',
  '.e2e',
]);

const IGNORE_LINES = [
  'node_modules/',
  '.env',
  '.env.*',
  '!.env.example',
  '.e2e*/',
  'scratch/',
  'exports/',
  // kit 本体被 clone 进仓库、以及本机的绑定标记，均不入库
  'e2e-kit/',
  '.e2e-kit.json',
];

export function parseArgs(argv) {
  const flags = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith('--')) {
      flags._.push(arg);
      continue;
    }
    const [rawKey, inline] = arg.slice(2).split('=');
    const key = rawKey.replace(/-([a-z])/g, (_, ch) => ch.toUpperCase());
    if (inline !== undefined) {
      flags[key] = inline;
      continue;
    }
    const next = argv[i + 1];
    if (next && !next.startsWith('--')) {
      flags[key] = next;
      i += 1;
    } else {
      flags[key] = true;
    }
  }
  return flags;
}

export function help() {
  return `用法: e2e-kit init [选项]

选项:
  --project <dir>      项目根（默认从当前目录向上找 e2e 配置或 .git）
  --dir <name>         e2e 目录名（默认 e2e）
  --env <name>         环境名（默认 test）
  --url <url>          被测应用根，必须以 / 结尾
  --user <name>        测试账号
  --password <pwd>     测试密码（也可用环境变量 E2E_INIT_PASSWORD，避免出现在进程列表）
  --provider <name>    anthropic | openai-compatible（可选，agent 用）
  --base-url <url>     模型 baseURL（可选）
  --model <name>       模型名（可选）
  --api-key <key>      模型 key（可选）
  --client <name>      目标客户端（claude/codex/cursor/workbuddy/zcode/dsh/auto，逗号分隔）；
                       传了就同时写入该客户端的 MCP 配置与 skill
  --yes                非交互：不提问，缺必填项直接报错
  --no-install         跳过 npm install 与 Chromium 安装
  --no-smoke           跳过冒烟测试
  --dry-run            只打印计划，不写文件
  --json               以 JSON 输出最终结果（脚本用）
  -h, --help           显示本帮助
`;
}

function detectProjectRoot(flags) {
  if (flags.project) return resolve(process.cwd(), flags.project);
  try {
    const located = locateProject({ startDir: process.cwd() });
    return findRepoRoot(located.config);
  } catch {
    // 未初始化：向上找 .git 作为项目根，找不到就用 cwd
  }
  let dir = resolve(process.cwd());
  while (true) {
    if (existsSync(join(dir, '.git'))) return dir;
    const parent = dirname(dir);
    if (parent === dir) return resolve(process.cwd());
    dir = parent;
  }
}

function detectFramework(projectRoot) {
  const markers = ['playwright.config.ts', 'playwright.config.js', 'cypress.config.ts', 'cypress.config.js'];
  const found = markers.filter((name) => fileExists(join(projectRoot, name)));
  if (dirExists(join(projectRoot, 'cypress'))) found.push('cypress/');
  return found;
}

function listDir(dir) {
  try {
    return readdirSync(dir);
  } catch {
    return [];
  }
}

function checkNodeVersion() {
  const [major, minor, patch] = process.versions.node.split('.').map(Number);
  const ok = major > 22 || (major === 22 && (minor > 22 || (minor === 22 && patch >= 3)));
  return { ok, version: process.versions.node };
}

function normalizeUrl(raw) {
  const value = String(raw ?? '').trim();
  if (!value) return '';
  const withSlash = value.endsWith('/') ? value : `${value}/`;
  try {
    const url = new URL(withSlash);
    return url.href;
  } catch {
    return '';
  }
}

function detectClients(projectRoot) {
  const home = process.env.HOME || '';
  const has = (p) => {
    try {
      return existsSync(p);
    } catch {
      return false;
    }
  };
  const found = [];
  if (has(join(home, '.codex')) || has(join(projectRoot, '.codex'))) found.push('codex');
  if (has(join(home, '.claude')) || has(join(projectRoot, '.claude'))) found.push('claude');
  if (has(join(home, '.cursor')) || has(join(projectRoot, '.cursor'))) found.push('cursor');
  return found;
}

function parseEnvFile(file) {
  const out = {};
  const text = readText(file, '');
  for (const line of text.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq <= 0) continue;
    out[trimmed.slice(0, eq).trim()] = trimmed.slice(eq + 1).trim();
  }
  return out;
}

// 框架 payload：模板名 → 生成到项目内的相对路径。
// 与 templates/ 目录一一对应；refresh-from-source 工具维护模板内容，这里维护映射。
const PAYLOAD = [
  ['package.json.tpl', 'package.json'],
  ['package-lock.json.tpl', 'package-lock.json'],
  ['e2e.config.ts.tpl', 'e2e.config.ts'],
  ['tsconfig.json.tpl', 'tsconfig.json'],
  ['env.example.tpl', '.env.example'],
  ['gitignore.txt', '.gitignore'],
  ['readme.md.tpl', 'README.md'],
  ['docs/Excel用例工作流.md.tpl', 'docs/Excel用例工作流.md'],
  ['docs/初稿生成入口.md.tpl', 'docs/初稿生成入口.md'],
  ['docs/怎么指挥AI跑测试.md.tpl', 'docs/怎么指挥AI跑测试.md'],
  ['docs/版本与变更记录.md.tpl', 'docs/版本与变更记录.md'],
  ['docs/维护与提交标准.md.tpl', 'docs/维护与提交标准.md'],
  ['docs/运行与结果管理.md.tpl', 'docs/运行与结果管理.md'],
  ['helpers/assistant-panel.ts.tpl', 'helpers/assistant-panel.ts'],
  ['helpers/auth-session.ts.tpl', 'helpers/auth-session.ts'],
  ['scripts/cases.mjs.tpl', 'scripts/cases.mjs'],
  ['scripts/check-case-doc.py.tpl', 'scripts/check-case-doc.py'],
  ['scripts/check-scope.mjs.tpl', 'scripts/check-scope.mjs'],
  ['scripts/forward-test-env.mjs.tpl', 'scripts/forward-test-env.mjs'],
  ['scripts/generate-case-doc.py.tpl', 'scripts/generate-case-doc.py'],
  ['scripts/lib/case-report.mjs.tpl', 'scripts/lib/case-report.mjs'],
  ['scripts/lib/case-workflow.mjs.tpl', 'scripts/lib/case-workflow.mjs'],
  ['scripts/lib/files.mjs.tpl', 'scripts/lib/files.mjs'],
  ['scripts/lib/run-options.mjs.tpl', 'scripts/lib/run-options.mjs'],
  ['scripts/lib/scope.mjs.tpl', 'scripts/lib/scope.mjs'],
  ['scripts/list-selection.mjs.tpl', 'scripts/list-selection.mjs'],
  ['scripts/mcp.mjs.tpl', 'scripts/mcp.mjs'],
  ['scripts/read-case-doc.py.tpl', 'scripts/read-case-doc.py'],
  ['scripts/reporters/business.mjs.tpl', 'scripts/reporters/business.mjs'],
  ['scripts/run.mjs.tpl', 'scripts/run.mjs'],
  ['scripts/sync-local.mjs.tpl', 'scripts/sync-local.mjs'],
  ['scripts/tests/core.test.mjs.tpl', 'scripts/tests/core.test.mjs'],
  ['scripts/tests/draft.test.mjs.tpl', 'scripts/tests/draft.test.mjs'],
  ['scripts/tests/report-index.py.tpl', 'scripts/tests/report-index.py'],
  ['scripts/tests/workbook-fixture.mjs.tpl', 'scripts/tests/workbook-fixture.mjs'],
  ['scripts/tests/workflow.test.mjs.tpl', 'scripts/tests/workflow.test.mjs'],
  ['templates/写测试.md.tpl', 'templates/写测试.md'],
  ['templates/测试用例文档格式.md.tpl', 'templates/测试用例文档格式.md'],
  ['templates/用例初稿示例.json.tpl', 'templates/用例初稿示例.json'],
  ['tests/auth.setup.e2e.ts.tpl', 'tests/auth.setup.e2e.ts'],
  ['tests/login.e2e.ts.tpl', 'tests/login.e2e.ts'],
];

export function buildFiles(ctx) {
  const d = ctx.dirName;
  const vars = {
    PROJECT_NAME: ctx.projectName,
    E2E_VERSION,
    WEB_VERSION,
    DIR: d,
  };
  return PAYLOAD.map(([tpl, rel]) => ({
    rel: `${d}/${rel}`,
    tpl,
    content: render(loadTemplate(TEMPLATES, tpl), vars),
  }));
}

export async function runInit(argv) {
  const flags = parseArgs(argv);
  if (flags.help) {
    console.log(help());
    return 0;
  }

  const json = Boolean(flags.json);
  const say = (...args) => {
    if (!json) console.log(...args);
  };
  const result = {
    ok: false,
    mode: null,
    projectRoot: null,
    dir: null,
    config: null,
    created: [],
    modified: [],
    skipped: [],
    warnings: [],
    manualSteps: [],
    install: 'skipped',
    smoke: 'skipped',
  };

  say(c.bold(`e2e-kit init v${KIT_VERSION}`));

  // ── 阶段 0：环境体检 ────────────────────────────────────────────────
  const node = checkNodeVersion();
  if (!node.ok) {
    console.error(c.red(`Node 版本过低：${node.version}，e2e 需要 >= 22.22.3`));
    return 2;
  }

  const projectRoot = detectProjectRoot(flags);
  result.projectRoot = projectRoot;
  say(`项目根：${c.dim(projectRoot)}`);

  // ── 阶段 1：识别 ────────────────────────────────────────────────────
  const existing = configCandidatesIn(projectRoot);
  const marker = readJson(join(projectRoot, '.e2e-kit.json'), null);
  const markerConfig = marker?.config ? resolve(projectRoot, marker.config) : null;
  const markerValid = markerConfig && fileExists(markerConfig);

  let mode = 'fresh';
  let targetDir;
  if (markerValid) {
    mode = 'existing';
    targetDir = dirname(markerConfig);
  } else if (existing.length === 1) {
    mode = 'existing';
    targetDir = dirname(existing[0]);
  } else if (existing.length > 1) {
    console.error(c.red('发现多个 e2e 配置，无法确定使用哪一个：'));
    for (const file of existing) console.error(`  - ${file}`);
    console.error('请用 --dir 指定，或先整理为单份配置。');
    return 3;
  } else {
    targetDir = resolve(projectRoot, flags.dir || 'e2e');
  }

  const relDir = posix(relative(projectRoot, targetDir)) || '.';
  result.dir = relDir;
  result.config = posix(relative(projectRoot, join(targetDir, 'e2e.config.ts')));

  const framework = detectFramework(projectRoot);
  if (mode === 'fresh' && framework.length) {
    mode = 'coexist';
    result.warnings.push(`检测到其他测试框架：${framework.join('、')}；将并存，不修改其任何文件。`);
  }
  result.mode = mode;
  say(`模式：${c.bold(mode)}${mode === 'existing' ? '（体检/补缺，不重建）' : ''}`);

  if (mode === 'fresh' && dirExists(targetDir)) {
    const entries = listDir(targetDir).filter((name) => !name.startsWith('.'));
    const onlyKnown = entries.every((name) => KNOWN_FILES.has(name));
    if (entries.length && !onlyKnown) {
      console.error(c.red(`目标目录已存在且包含非 e2e 内容：${targetDir}`));
      console.error('请改用 --dir <其他目录名>，或先清理该目录。未写入任何文件。');
      return 4;
    }
  }

  // ── 阶段 2：交互 ────────────────────────────────────────────────────
  const interactive = isInteractive() && !flags.yes;
  // 已存在的 .env 一律沿用：不提问、不读取、不修改。
  // 兼容旧版 kit 的变量名（E2E_USER/E2E_PASSWORD），避免把同一套账号再问一遍。
  const envPath = join(targetDir, '.env');
  const envExists = fileExists(envPath);
  const existingEnv = parseEnvFile(envPath);
  const envUser = existingEnv.EOFFICE_ADMIN_USER || existingEnv.E2E_USER || '';
  const envPassword = existingEnv.EOFFICE_ADMIN_PASSWORD || existingEnv.E2E_PASSWORD || '';
  if (envExists) {
    say(c.dim(`沿用现有配置：${posix(relative(projectRoot, envPath))}（不读取、不修改）`));
  }
  let appUrl = normalizeUrl(flags.url || existingEnv.APP_URL || '');
  if (!appUrl && interactive) {
    appUrl = normalizeUrl(await ask('被测应用根地址（必须以 / 结尾）', { defaultValue: 'http://localhost:4200/' }));
  }
  let user = flags.user || envUser;
  if (!user && interactive && !envExists) user = await ask('测试账号', { defaultValue: 'admin' });
  let password = flags.password || process.env.E2E_INIT_PASSWORD || envPassword;
  if (!password && interactive && !envExists) password = await askHidden('测试密码（输入不回显）');

  if (!appUrl) {
    console.error(c.red('缺少 APP_URL。非交互模式请传 --url（必须以 / 结尾）。'));
    return 5;
  }
  if (!user) {
    console.error(c.red('缺少测试账号。非交互模式请传 --user。'));
    return 5;
  }

  const ctx = {
    projectRoot,
    dirName: relDir === '.' ? 'e2e' : relDir.split('/').pop(),
    projectName: basename(projectRoot) || 'project',
    appUrl,
    user,
    password,
    baseUrl: flags.baseUrl || '',
    model: flags.model || '',
  };

  // ── 阶段 3：生成计划 ────────────────────────────────────────────────
  const files = buildFiles(ctx);
  if (flags.dryRun) {
    say(c.bold('\n将生成以下文件（dry-run，不写入）：'));
    for (const file of files) say(`  ${fileExists(join(projectRoot, file.rel)) ? '跳过（已存在）' : '创建'}  ${file.rel}`);
    say(`  ${fileExists(join(projectRoot, ctx.dirName, '.env')) ? '跳过（已存在）' : '创建'}  ${ctx.dirName}/.env`);
    return 0;
  }

  // ── 阶段 4：写入（只补不覆盖）──────────────────────────────────────
  ensureDir(targetDir);
  const generated = { ...(marker?.generated ?? {}) };
  const preserve = (marker?.dir && marker.dir !== relDir) ? marker.dir : null;
  if (preserve) {
    result.warnings.push(`已存在旧标记指向 ${preserve}，本次改为 ${relDir}，旧配置未改动。`);
  }

  for (const file of files) {
    const abs = join(projectRoot, file.rel);
    const hash = sha256(file.content);
    const relPosix = posix(file.rel);

    if (fileExists(abs)) {
      const current = sha256(readText(abs));
      const recorded = generated[relPosix];
      if (recorded && recorded !== current) {
        result.skipped.push({ path: relPosix, reason: '用户已修改，跳过' });
      } else {
        result.skipped.push({ path: relPosix, reason: '已存在' });
      }
      continue;
    }
    writeText(abs, file.content);
    generated[relPosix] = hash;
    result.created.push(relPosix);
  }

  // .env：已存在永不覆盖
  if (fileExists(envPath)) {
    result.skipped.push({ path: posix(relative(projectRoot, envPath)), reason: '已存在（永不覆盖）' });
  } else {
    const envContent = [
      '# e2e 本地配置（gitignored）；由 e2e-kit 生成，请勿提交',
      `APP_URL=${ctx.appUrl}`,
      `EOFFICE_ADMIN_USER=${ctx.user}`,
      `EOFFICE_ADMIN_PASSWORD=${password}`,
      '',
      '# 本机测试人员姓名（选填）：AI 生成 Excel 用例文档时的默认「创建人」署名',
      'EOFFICE_TESTER_NAME=',
      '',
      '# agent 步骤模型（可选）；不填 AI_API_KEY 则 agent 用例自动跳过',
      `AI_PROVIDER=${flags.provider || 'openai-compatible'}`,
      `AI_BASE_URL=${flags.baseUrl || 'https://api.deepseek.com'}`,
      `AI_MODEL=${flags.model || 'deepseek-chat'}`,
      `AI_API_KEY=${flags.apiKey || ''}`,
      '',
    ].join('\n');
    writeText(envPath, envContent, { mode: 0o600 });
    generated[posix(relative(projectRoot, envPath))] = sha256(envContent);
    result.created.push(posix(relative(projectRoot, envPath)));
  }

  // ── 阶段 5：接入（gitignore / AGENTS.md）────────────────────────────
  const gitignorePath = join(projectRoot, '.gitignore');
  const mergedIgnore = mergeIgnoreList(readText(gitignorePath, ''), IGNORE_LINES);
  if (mergedIgnore.added.length) {
    writeText(gitignorePath, mergedIgnore.content);
    result.modified.push('.gitignore');
  } else {
    result.skipped.push({ path: '.gitignore', reason: '规则已存在' });
  }

  const agentsPath = join(projectRoot, 'AGENTS.md');
  const routeBody = loadTemplate(TEMPLATES, 'agents-route.md').replaceAll('{{DIR}}', ctx.dirName);
  const mergedAgents = mergeMarkedSection(readText(agentsPath, ''), routeBody);
  if (mergedAgents.added) {
    writeText(agentsPath, mergedAgents.content);
    result.modified.push('AGENTS.md');
  } else {
    result.skipped.push({ path: 'AGENTS.md', reason: '路由条款已存在' });
  }

  const clients = flags.client
    ? String(flags.client)
        .split(',')
        .map((s) => s.trim())
        .filter(Boolean)
    : (marker?.clients ?? []);
  const unknownClients = clients.filter((c) => c !== 'auto' && !SUPPORTED_CLIENTS.includes(c));
  if (unknownClients.length) {
    console.error(c.red(`不支持的客户端：${unknownClients.join('、')}。可选：${SUPPORTED_CLIENTS.join(' / ')} / auto`));
    return 6;
  }
  const nextMarker = mergeMarker(marker, {
    version: 1,
    dir: relDir,
    config: result.config,
    e2eVersion: E2E_VERSION,
    env: flags.env || 'test',
    clients,
    generated,
  });
  const markerFile = join(projectRoot, '.e2e-kit.json');
  const markerText = `${JSON.stringify(nextMarker, null, 2)}\n`;
  if (readText(markerFile, '') === markerText) {
    result.skipped.push({ path: '.e2e-kit.json', reason: '无变化' });
  } else {
    writeText(markerFile, markerText);
    result.modified.push('.e2e-kit.json');
  }

  // 客户端接入与项目初始化合成一步：传了 --client 就顺手写 MCP 配置 + skill。
  if (clients.length) {
    const targets = clients.includes('auto') ? detectClients(projectRoot) : clients;
    if (targets.length) {
      const installed = installClients(targets, projectRoot);
      result.clientInstall = installed.clients.map((item) => ({
        client: item.client,
        files: item.files,
        skipped: item.skipped,
        error: item.error,
        snippet: Boolean(item.snippet),
      }));
      for (const item of installed.clients) {
        if (item.error) result.warnings.push(`客户端 ${item.client} 接入失败：${item.error}`);
      }
    } else {
      result.warnings.push('--client auto 未检测到可用客户端（claude/codex/cursor），已跳过接入。');
    }
  }

  // ── 阶段 6：安装 + 冒烟 ────────────────────────────────────────────
  if (!flags.noInstall) {
    say(c.dim('\n安装依赖（npm ci，失败时回落 npm install）…'));
    let installed = spawnSync('npm', ['ci', '--no-audit', '--no-fund'], {
      cwd: targetDir,
      stdio: 'inherit',
      shell: process.platform === 'win32',
    });
    if (installed.status !== 0) {
      say(c.dim('npm ci 未成功（package.json 与锁文件可能不一致），回落 npm install…'));
      installed = spawnSync('npm', ['install', '--no-audit', '--no-fund'], {
        cwd: targetDir,
        stdio: 'inherit',
        shell: process.platform === 'win32',
      });
    }
    result.install = installed.status === 0 ? 'ok' : 'failed';
    if (installed.status === 0) {
      const chromium = spawnSync(
        process.execPath,
        ['node_modules/playwright-core/cli.js', 'install', 'chromium'],
        { cwd: targetDir, stdio: 'inherit' },
      );
      if (chromium.status !== 0) {
        result.warnings.push(
          'Chromium 安装失败；有头模式需要它。可重试：' +
            'PLAYWRIGHT_DOWNLOAD_HOST=https://cdn.npmmirror.com/binaries/playwright node node_modules/playwright-core/cli.js install chromium',
        );
      }
    } else {
      result.warnings.push('npm install 失败；修好后运行 npm run test:e2e 继续。');
    }
  }

  if (!flags.noSmoke && result.install !== 'failed') {
    say(c.dim('\n冒烟：npx e2e run tests/login.e2e.ts'));
    const smoke = spawnSync('npx', ['e2e', 'run', 'tests/login.e2e.ts'], {
      cwd: targetDir,
      encoding: 'utf8',
      shell: process.platform === 'win32',
    });
    if (smoke.stdout) process.stdout.write(smoke.stdout);
    if (smoke.stderr) process.stderr.write(smoke.stderr);
    result.smoke = smoke.status === 0 ? 'ok' : 'failed';
    if (smoke.status !== 0) {
      const output = `${smoke.stdout ?? ''}\n${smoke.stderr ?? ''}`;
      if (output.includes('INVALID_APP_URL')) {
        result.warnings.push(
          '冒烟失败：APP_URL 是非 loopback 的明文 HTTP（框架只放行 127.x/localhost）。' +
            '启动本地端口转发后重试（cd ' + relDir + ' && npm run forward -- 8010 <测试机IP> 8010，目标 IP 必填）；转发未启动时直连内网明文地址会被拒绝，属预期。',
        );
      } else {
        result.warnings.push('冒烟失败：先看 .e2e/ 下的 report/trace，再核对 APP_URL 与 .env 凭据。');
      }
    }
  }

  // ── 阶段 7：汇报 ────────────────────────────────────────────────────
  result.ok = result.smoke !== 'failed' && result.install !== 'failed';
  const aiConfigured = Boolean(flags.apiKey || existingEnv.AI_API_KEY);
  result.manualSteps = [
    ...(result.manualSteps ?? []),
    clients.includes('workbuddy')
      ? 'WorkBuddy：在「自定义连接器」里粘贴连接器 JSON 并点信任（首次必做）'
      : null,
    `登录冒烟失败先核对 ${relDir}/.env 的 APP_URL 与凭据；登录流程适配在 ${relDir}/helpers/auth-session.ts（框架文件，手改后 upgrade 会跳过）`,
    aiConfigured
      ? `AI 模型已配置（${relDir}/.env 的 AI_*），agent 用例可用；实探/MCP 按需运行 init --client 接入`
      : `AI 模型未配置（AI_API_KEY 为空）：带 AI 步骤的用例将自动跳过，纯定位器用例不受影响；要启用，在 ${relDir}/.env 填 AI_* 四项（AI_PROVIDER/AI_BASE_URL/AI_MODEL/AI_API_KEY）`,
  ].filter(Boolean);

  if (json) {
    console.log(JSON.stringify(result, null, 2));
  } else {
    say(c.bold('\n完成'));
    if (result.created.length) say(c.green(`创建 ${result.created.length} 个文件：`));
    for (const f of result.created) say(`  + ${f}`);
    if (result.modified.length) say(`更新：${result.modified.join('、')}`);
    for (const s of result.skipped) say(c.dim(`  = ${s.path}（${s.reason}）`));
    for (const w of result.warnings) say(c.yellow(`! ${w}`));
    if (result.clientInstall?.length) {
      const parts = result.clientInstall.map(
        (item) => `${item.client}${item.files.length ? `（${item.files.length} 个文件）` : '（已存在）'}`,
      );
      say(`客户端接入：${parts.join('、')}`);
    }
    if (result.install !== 'skipped') say(`依赖安装：${result.install}`);
    if (result.smoke !== 'skipped') say(`冒烟：${result.smoke}`);
    say(`\n下一步：\n  cd ${relDir} && npm run test:run -- tests/login.e2e.ts   # 冒烟\n  cd ${relDir} && npm run test:run -- tests/              # 全量回归`);
    if (result.manualSteps.length) {
      say('\n仍需人工：');
      for (const step of result.manualSteps) say(`  - ${step}`);
    }
  }
  return result.ok ? 0 : 1;
}
