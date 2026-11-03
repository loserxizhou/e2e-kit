import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { inspectScope } from './lib/scope.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
try {
  const args = process.argv.slice(2);
  let staged = false;
  let base = null;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--staged') staged = true;
    else if (args[i] === '--base' && args[i + 1]) base = args[++i];
    else throw new Error('用法：npm run test:scope -- [--staged | --base 提交或分支]');
  }
  const entries = inspectScope(root, { staged, base });
  for (const entry of entries) console.log(`${entry.allowed ? '可提交测试资产' : '维护者处理'} · ${entry.status} · ${entry.path}`);
  const blocked = entries.filter((entry) => !entry.allowed);
  console.log(`[e2e] 检查 ${entries.length} 个路径，核心/越界路径 ${blocked.length} 个。只读检查，不暂存、不回退、不修改文件。`);
  if (blocked.length) console.log('[e2e] 测试任务不得提交上述核心变更。已有维护者改动不等于本次测试越界；请按维护与提交标准核对归属。');
  process.exitCode = blocked.length ? 1 : 0;
} catch {
  console.error('[e2e] 范围检查未完成，请检查参数和 Git 基准。无法检查时不能声称改动范围已通过。');
  process.exitCode = 2;
}
