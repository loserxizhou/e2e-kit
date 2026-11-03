// 原生 list CLI 不接受 --output；复跑使用公开 SDK 的 output/lastFailed。
// 与 CLI 隔离进程，配置中的定时器、输出和环境不污染批次启动器。
import { readFileSync } from 'node:fs';
import { list } from 'e2e/runner';

try {
  const input = JSON.parse(readFileSync(0, 'utf8'));
  const options = { cwd: input.root, config: input.config, files: input.files, output: input.output, lastFailed: true };
  const arrays = { '--tag': 'tags', '--exclude-tag': 'excludeTags', '--target': 'targets' };
  for (let i = 0; i < input.selection.length; i += 2) {
    const key = input.selection[i];
    const value = input.selection[i + 1];
    if (Object.hasOwn(arrays, key)) {
      const name = arrays[key];
      options[name] = [...(options[name] ?? []), ...value.split(',').map((part) => part.trim()).filter(Boolean)];
    } else if (key === '--tag-mode') options.tagMode = value;
    else if (key === '--changed-since') options.changedSince = value;
    else if (key === '--shard') {
      if (!/^[1-9]\d*\/[1-9]\d*$/.test(value)) throw new Error('INVALID_SHARD');
      const [index, total] = value.split('/').map(Number);
      options.shard = { index, total };
    } else if (key === '--grep' || key === '--grep-invert') {
      const match = /^\/(.*)\/([a-z]*)$/su.exec(value);
      if (match && !match[1]) throw new Error('INVALID_PATTERN');
      const pattern = match ? new RegExp(match[1], match[2]) : new RegExp(value);
      const name = key === '--grep' ? 'grep' : 'grepInvert';
      options[name] = [...(options[name] ?? []), pattern];
    } else throw new Error('UNSUPPORTED_SELECTION');
  }
  const plan = await list(options);
  // 只输出可信协议部分；不把配置/注册阶段的 console 文本解析成选择结果。
  process.stdout.write(`\nEOFFICE_SELECTION_JSON:${JSON.stringify(plan)}\n`, () => process.exit(0));
} catch (error) {
  const code = /^[A-Z_]{1,80}$/.test(error?.code ?? '') ? error.code : 'LIST_FAILED';
  process.stderr.write(`[e2e] 原生复跑选择失败：${code}\n`, () => process.exit(2));
}
