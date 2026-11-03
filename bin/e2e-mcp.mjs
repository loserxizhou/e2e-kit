// MCP 包装器：定位项目 → 起 e2e mcp。
// 所有客户端适配器都指向这个文件，不在各处复制逻辑。


import { spawn } from 'node:child_process';
import { existsSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';

import { findRepoRoot, locateProject, LocateError, NOT_INITIALIZED_MESSAGE } from './lib/locate.mjs';
import { kitVersion } from './lib/kit.mjs';

const KIT_VERSION = kitVersion();
const DEFAULT_E2E_VERSION = '0.22.0';

// 版本守卫：客户端启动 MCP 时继承的 PATH 里 node 可能低于 e2e 要求（缺 module.registerHooks）
{
  const [major, minor, patch] = process.versions.node.split('.').map(Number);
  const ok = major > 22 || (major === 22 && (minor > 22 || (minor === 22 && patch >= 3)));
  if (!ok) {
    fail(
      1,
      `[e2e-kit] 当前 Node ${process.versions.node} 低于 e2e 要求的 22.22.3（缺 module.registerHooks，e2e 无法加载）。\n` +
        '请用高版本 Node 启动本 MCP：重跑 e2e-kit init 会把 command 写成绝对路径；或先 nvm install 24 && nvm use 24 再启动客户端。',
    );
  }
}

function takeFlag(argv, name) {
  const out = [];
  let value;
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === `--${name}`) {
      value = argv[i + 1];
      i += 1;
      continue;
    }
    if (arg.startsWith(`--${name}=`)) {
      value = arg.slice(name.length + 3);
      continue;
    }
    out.push(arg);
  }
  return { value, rest: out };
}

function isFile(p) {
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
}

function fail(code, message) {
  process.stderr.write(`${message}\n`);
  process.exit(code);
}

function main() {
  const args = process.argv.slice(2);
  if (args[0] === 'mcp') args.shift();
  const project = takeFlag(args, 'project');
  const config = takeFlag(args, 'config');
  const rest = config.rest;

  let located;
  try {
    located = locateProject({
      project: project.value,
      config: config.value,
      startDir: process.cwd(),
    });
  } catch (err) {
    if (err instanceof LocateError) {
      if (err.code === 'NOT_INITIALIZED') {
        fail(2, `${NOT_INITIALIZED_MESSAGE}\n\n（e2e-kit ${KIT_VERSION}）`);
      }
      if (err.code === 'CONFIG_AMBIGUOUS') {
        fail(3, err.message);
      }
      fail(2, err.message);
    }
    throw err;
  }

  const projectRoot = findRepoRoot(located.config);
  const localBin = join(projectRoot, 'node_modules', '.bin', process.platform === 'win32' ? 'e2e.cmd' : 'e2e');
  const hasLocal = isFile(localBin);

  const command = hasLocal ? localBin : 'npx';
  const argsForE2e = hasLocal
    ? ['mcp', '--config', located.config, ...rest]
    : ['-y', `e2e@${DEFAULT_E2E_VERSION}`, 'mcp', '--config', located.config, ...rest];

  process.stderr.write(
    `[e2e-kit] 项目：${projectRoot}\n[e2e-kit] 配置：${located.config}\n[e2e-kit] 启动：${command} ${argsForE2e.join(' ')}\n`,
  );

  const child = spawn(command, argsForE2e, {
    cwd: dirname(located.config), // 配置文件所在目录 = 项目根，保证相对路径一致
    stdio: 'inherit',
    shell: process.platform === 'win32',
    env: { ...process.env },
  });

  const forward = (signal) => {
    if (!child.killed) child.kill(signal);
  };
  process.on('SIGINT', () => forward('SIGINT'));
  process.on('SIGTERM', () => forward('SIGTERM'));

  child.on('exit', (code, signal) => {
    if (signal) process.kill(process.pid, signal);
    else process.exit(code ?? 0);
  });
  child.on('error', (err) => {
    fail(1, `[e2e-kit] 无法启动 e2e mcp：${err.message}`);
  });
}

main();
