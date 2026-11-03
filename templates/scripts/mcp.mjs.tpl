// 所有客户端共用项目安装的 e2e，避免 npx 或本机 kit 固定到另一个版本。
import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const dir = resolve(dirname(fileURLToPath(import.meta.url)), '..');

try {
  const project = JSON.parse(readFileSync(resolve(dir, 'package.json'), 'utf8'));
  for (const name of ['e2e', '@e2e-dev/web']) {
    const installed = JSON.parse(readFileSync(resolve(dir, 'node_modules', name, 'package.json'), 'utf8'));
    if (installed.version !== project.devDependencies[name]) {
      throw new Error(`${name} 的安装版本与项目不一致`);
    }
  }
  const pkg = JSON.parse(readFileSync(resolve(dir, 'node_modules/e2e/package.json'), 'utf8'));
  const bin = typeof pkg.bin === 'string' ? pkg.bin : pkg.bin.e2e;
  const extra = process.argv.slice(2);
  if (extra.some((arg) => arg === '--config' || arg.startsWith('--config='))) {
    throw new Error('项目 MCP 的配置固定为 e2e/e2e.config.ts');
  }
  const args = extra.length === 1 && extra[0] === '--version'
    ? ['--version']
    : ['mcp', '--config', resolve(dir, 'e2e.config.ts'), ...extra];
  const child = spawn(process.execPath, [resolve(dir, 'node_modules/e2e', bin), ...args], {
    cwd: dir,
    stdio: 'inherit',
  });
  for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => child.kill(signal));
  child.on('error', () => {
    console.error('[e2e] MCP 启动失败，请在 e2e 目录执行 npm ci && npm run sync');
    process.exitCode = 1;
  });
  child.on('exit', (code, signal) => {
    process.exitCode = code ?? (signal === 'SIGINT' ? 130 : signal === 'SIGTERM' ? 143 : 1);
  });
} catch (error) {
  console.error(`[e2e] ${error.code === 'ENOENT' ? '项目依赖未安装完整' : error.message}；请在 e2e 目录执行 npm ci && npm run sync`);
  process.exitCode = 1;
}
