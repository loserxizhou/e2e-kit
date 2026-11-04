// e2e-kit upgrade：把项目内「未被手改」的框架文件刷新为当前 kit 版本。
// 语义（与 init 的「只补不覆盖」配套）：
//   - 文件缺失 → 创建；
//   - 文件 hash 与 .e2e-kit.json generated 记录一致（kit 生成后未动）→ 刷新为新版；
//   - 文件 hash 与记录不一致（用户手改）或无记录（来源不明）→ 跳过并列出；
//   - .env、业务用例、scratch/、knowledge/、exports/、.e2e/ 等用户资产不在 payload，永不触碰。

import { existsSync } from 'node:fs';
import { basename, dirname, join, relative, resolve } from 'node:path';

import { buildFiles, parseArgs, E2E_VERSION } from './init.mjs';
import { ask, isInteractive } from './lib/prompt.mjs';
import { detectInstalledClients, installClients, SUPPORTED_CLIENTS } from './install.mjs';
import { configCandidatesIn, findRepoRoot, locateProject } from './lib/locate.mjs';
import { fileExists, mergeMarker, posix, readJson, readText, sha256, writeText } from './lib/util.mjs';

const COLOR = process.stdout.isTTY;
const c = {
  dim: (s) => (COLOR ? `\x1b[2m${s}\x1b[0m` : s),
  green: (s) => (COLOR ? `\x1b[32m${s}\x1b[0m` : s),
  yellow: (s) => (COLOR ? `\x1b[33m${s}\x1b[0m` : s),
  red: (s) => (COLOR ? `\x1b[31m${s}\x1b[0m` : s),
  bold: (s) => (COLOR ? `\x1b[1m${s}\x1b[0m` : s),
};

export function help() {
  return `用法: e2e-kit upgrade [选项]

刷新项目内未被手改的 e2e 框架文件（配置、脚本、模板、docs）。
手改过的文件与全部用户资产（.env、业务用例、scratch/、knowledge/、exports/）不会触碰。

选项:
  --project <dir>      项目根（默认从当前目录向上定位）
  --migration <mode>   safe（默认，保护来源不明文件）| adopt（接管并刷新旧框架文件）
  --client <name>      升级指定客户端的 e2e-kit Skill（逗号分隔）
  --dry-run            只打印计划，不写文件
  --json               以 JSON 输出结果（脚本用）
  -h, --help           显示本帮助
`;
}

function detectProjectRoot(flags) {
  if (flags.project) return resolve(process.cwd(), flags.project);
  try {
    const located = locateProject({ startDir: process.cwd() });
    return findRepoRoot(located.config);
  } catch {
    let dir = resolve(process.cwd());
    while (true) {
      if (existsSync(join(dir, '.git'))) return dir;
      const parent = dirname(dir);
      if (parent === dir) return resolve(process.cwd());
      dir = parent;
    }
  }
}

function migrationMode(flags) {
  const value = flags.migration;
  if (value && !['safe', 'adopt'].includes(value)) throw new Error('--migration 只支持 safe 或 adopt');
  if (value) return Promise.resolve(value);
  if (flags.yes || !isInteractive()) return Promise.resolve('safe');
  return ask(
    '选择迁移模式：safe=保护来源不明/手改文件，adopt=接管并刷新旧框架文件（默认 safe）',
    { defaultValue: 'safe' },
  ).then((answer) => {
    const mode = answer.trim().toLowerCase() || 'safe';
    if (!['safe', 'adopt'].includes(mode)) throw new Error('迁移模式只支持 safe 或 adopt');
    return mode;
  });
}

function requestedClients(flags, marker, projectRoot) {
  const raw = flags.client ? String(flags.client).split(',').map((s) => s.trim()).filter(Boolean)
    : [...new Set([...(Array.isArray(marker?.clients) ? marker.clients : []), ...detectInstalledClients(projectRoot)])];
  const invalid = raw.filter((client) => !SUPPORTED_CLIENTS.includes(client));
  if (invalid.length) throw new Error(`不支持的客户端：${invalid.join('、')}`);
  return raw.filter((client) => ['claude', 'codex', 'cursor', 'dsh'].includes(client));
}

export async function runUpgrade(argv) {
  const flags = parseArgs(argv);
  if (flags.help) {
    console.log(help());
    return 0;
  }
  const json = Boolean(flags.json);
  const dryRun = Boolean(flags.dryRun);
  const say = (...args) => {
    if (!json) console.log(...args);
  };

  const result = {
    ok: false,
    projectRoot: null,
    dir: null,
    created: [],
    updated: [],
    unchanged: [],
    skipped: [],
    warnings: [],
    nextSteps: [],
  };

  const projectRoot = detectProjectRoot(flags);
  result.projectRoot = projectRoot;
  const marker = readJson(join(projectRoot, '.e2e-kit.json'), null);
  const existing = configCandidatesIn(projectRoot);

  let targetDir;
  if (marker?.config && fileExists(resolve(projectRoot, marker.config))) {
    targetDir = dirname(resolve(projectRoot, marker.config));
  } else if (existing.length === 1) {
    targetDir = dirname(existing[0]);
  } else if (existing.length > 1) {
    console.error(c.red(`发现多个 e2e 配置，无法确定使用哪一个：\n${existing.map((f) => `  - ${f}`).join('\n')}\n请用 --project 指定项目根。`));
    return 3;
  } else {
    console.error(c.red('未找到 e2e 配置或 .e2e-kit.json：请先运行 e2e-kit init 初始化项目。'));
    return 4;
  }

  const relDir = posix(relative(projectRoot, targetDir)) || '.';
  result.dir = relDir;
  const dirName = relDir === '.' ? 'e2e' : relDir.split('/').pop();
  const migration = await migrationMode(flags);
  result.migration = migration;
  say(c.bold(`e2e-kit upgrade → ${projectRoot} / ${relDir}`));
  if (dryRun) say(c.dim('（dry-run：不写任何文件）'));

  // 旧版 kit（E2E_* 变量名）升级提示
  const envText = readText(join(targetDir, '.env'), '');
  const hasLegacy = /^\s*E2E_USER=/m.test(envText) && !/^\s*EOFFICE_ADMIN_USER=/m.test(envText);
  if (hasLegacy) {
    result.warnings.push(
      '检测到旧版变量名 E2E_USER/E2E_PASSWORD：请在 .env 中改为 EOFFICE_ADMIN_USER/EOFFICE_ADMIN_PASSWORD（本工具不修改 .env）。',
    );
  }

  const files = buildFiles({ projectRoot, dirName, projectName: basename(projectRoot) || 'project' });
  const generated = { ...(marker?.generated ?? {}) };
  const nextGenerated = { ...generated };

  for (const file of files) {
    const abs = join(projectRoot, file.rel);
    const relPosix = posix(file.rel);
    const newHash = sha256(file.content);

    if (!fileExists(abs)) {
      result.created.push(relPosix);
      nextGenerated[relPosix] = newHash;
      if (!dryRun) writeText(abs, file.content);
      continue;
    }
    const current = sha256(readText(abs));
    const recorded = generated[relPosix];
    if (recorded === undefined && migration !== 'adopt') {
      result.skipped.push({ path: relPosix, reason: '来源不明（无生成记录），请人工比对' });
      continue;
    }
    if (recorded !== current && migration !== 'adopt') {
      result.skipped.push({ path: relPosix, reason: '用户已修改，保留现状' });
      continue;
    }
    if (current === newHash) {
      result.unchanged.push(relPosix);
      continue;
    }
    (recorded === undefined || recorded !== current ? result.adopted ??= [] : result.updated).push(relPosix);
    nextGenerated[relPosix] = newHash;
    if (!dryRun) writeText(abs, file.content);
  }

  // 刷新项目内 e2e-kit Skill。safe 只更新本 kit 生成且未被手改的副本，
  // adopt 接管旧副本；这与框架文件使用同一迁移选择。
  const clients = requestedClients(flags, marker, projectRoot);
  const installed = clients.length && !dryRun
    ? installClients(clients, projectRoot, { migration, skillGenerated: marker?.skillGenerated })
    : { skillGenerated: marker?.skillGenerated ?? {}, clients: [] };
  result.skills = installed.clients;
  for (const item of installed.clients) if (item.error) result.warnings.push(`客户端 ${item.client} Skill/MCP 接入失败：${item.error}`);

  // 刷新标记（记录新 hash 与版本；保留 clients 等用户字段）
  if (!dryRun) {
    const nextMarker = mergeMarker(marker, {
      version: 1,
      dir: relDir,
      config: posix(relative(projectRoot, join(targetDir, 'e2e.config.ts'))),
      e2eVersion: E2E_VERSION,
      generated: nextGenerated,
      skillGenerated: installed.skillGenerated,
    });
    writeText(join(projectRoot, '.e2e-kit.json'), `${JSON.stringify(nextMarker, null, 2)}\n`);
  }

  result.ok = true;
  result.nextSteps = [
    `cd ${relDir} && npm ci`,
    `cd ${relDir} && npm run sync -- --client <客户端>` + (clients.length ? `（本次：${clients.join(',')}）` : ''),
    '重启 AI 客户端使 MCP/Skill 生效',
  ];

  if (json) {
    console.log(JSON.stringify(result, null, 2));
  } else {
    if (result.created.length) {
      say(c.green(`创建 ${result.created.length} 个文件：`));
      for (const p of result.created) say(`  + ${p}`);
    }
    if (result.updated.length) {
      say(c.green(`刷新 ${result.updated.length} 个文件：`));
      for (const p of result.updated) say(`  ↑ ${p}`);
    }
    say(c.dim(`已最新 ${result.unchanged.length} 个`));
    for (const s of result.skipped) say(c.yellow(`  = ${s.path}（${s.reason}）`));
    for (const w of result.warnings) say(c.yellow(`! ${w}`));
    say(c.bold('\n升级后：'));
    for (const step of result.nextSteps) say(`  - ${step}`);
  }
  return 0;
}
