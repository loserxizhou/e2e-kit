import { resolve } from 'node:path';

const values = new Set(['--tag', '--tag-mode', '--exclude-tag', '--grep', '--grep-invert', '--target', '--agent', '--workers', '--retries', '--action-timeout', '--assertion-timeout', '--max-failures', '--max-duration', '--repeat-each', '--changed-since', '--shard', '--trace', '--video', '--cache-dir']);
const switches = new Set(['--headed', '--no-cache', '--strict-cache', '--debug', '--ai-trace']);
const listFlags = new Set(['--tag', '--tag-mode', '--exclude-tag', '--grep', '--grep-invert', '--target', '--changed-since', '--shard']);
const contextFlags = new Map([['--tester', 'tester'], ['--env-name', 'environment'], ['--frontend-version', 'frontendVersion'], ['--backend-version', 'backendVersion'], ['--data-batch', 'dataBatch']]);
const intents = new Set(['experience', 'smoke', 'formal', 'resume']);

export function parseRunOptions(args, root) {
  const options = { mode: 'debug', intent: null, list: false, help: false, files: [], native: [], selection: [], context: {}, rerun: null, caseDocs: [] };
  let explicitMode = false;
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    const equals = arg.startsWith('--') ? arg.indexOf('=') : -1;
    const key = equals < 0 ? arg : arg.slice(0, equals);
    const take = () => {
      const value = equals < 0 ? args[++i] : arg.slice(equals + 1);
      if (!value || (equals < 0 && value.startsWith('--'))) throw new Error(`${key} 缺少参数`);
      return value;
    };
    if (key === '--help' || key === '-h') options.help = true;
    else if (key === '--list') options.list = true;
    else if (key === '--mode') { options.mode = take(); explicitMode = true; }
    else if (key === '--intent') options.intent = take();
    else if (key === '--case-doc') options.caseDocs.push(take());
    else if (key === '--rerun') options.rerun = take();
    else if (key === '--module') {
      const module = take();
      if (!module.split('/').every((part) => part && !part.startsWith('_') && !part.includes('.') && !part.includes('\\'))) throw new Error('模块使用业务目录相对路径，不含 .、..、软链接或归档目录');
      options.files.push(`tests/${module}`);
    } else if (key === '--case-id') options.native.push('--tag', `case:${take()}`);
    else if (contextFlags.has(key)) {
      const value = take();
      if (value.length > 200 || /[\r\n\0]/.test(value)) throw new Error('运行说明项最多 200 字符且不可换行');
      options.context[contextFlags.get(key)] = value;
    } else if (values.has(key)) options.native.push(key, take());
    else if (switches.has(key) && equals < 0) options.native.push(key);
    else if (arg.startsWith('-')) throw new Error(`批次入口不支持 ${key}；复跑使用 --rerun，输出目录和配置由项目固定。其他诊断可使用原生 CLI。`);
    else options.files.push(arg);
  }
  if (options.intent && !intents.has(options.intent)) throw new Error('--intent 只支持 experience / smoke / formal / resume');
  if (options.intent === 'formal') options.mode = 'formal';
  if (options.intent === 'experience' || options.intent === 'smoke') options.mode = 'debug';
  if (options.caseDocs.length && !explicitMode && !options.intent) options.mode = 'formal';
  options.modeExplicit = explicitMode;
  if (!['debug', 'formal'].includes(options.mode)) throw new Error('--mode 只支持 debug / formal');
  if (options.rerun && !/^[0-9]{8}T[0-9]{6}Z-[a-f0-9-]{36}$/.test(options.rerun)) throw new Error('--rerun 须填写已有批次编号');
  if (options.intent === 'resume' && !options.rerun) throw new Error('继续上次批次须同时指定 --rerun 批次编号');
  if (options.rerun && options.intent !== 'resume') throw new Error('指定 --rerun 时执行意图必须选择 resume');
  // Windows 下 resolve 返回反斜杠路径，前缀比较前先归一化为正斜杠，避免范围校验误判
  const normSep = (p) => p.replaceAll('\\', '/');
  const scratchDir = normSep(resolve(root, 'scratch'));
  const testsDir = normSep(resolve(root, 'tests'));
  for (const file of options.files) {
    const path = normSep(resolve(root, file.replace(/:\d+$/, '')));
    if (path === scratchDir) throw new Error('用例范围须指定 scratch 中的具体文件或场景，不批量运行整个探索区');
    if (![testsDir, scratchDir].some((base) => path === base || path.startsWith(`${base}/`))) throw new Error('用例范围只能位于 e2e/tests 或 e2e/scratch');
    if (file.replaceAll('\\', '/').split('/').some((part) => part.startsWith('_'))) throw new Error('归档、造数等 _ 前缀目录不属于活动测试');
  }
  if (!options.files.length) options.files.push('tests/');
  const includesScratch = options.files.some((file) => normSep(resolve(root, file)).startsWith(`${scratchDir}/`));
  // 审核后的草稿也可正式执行；定稿入 tests 是后续独立动作。
  options.scratch = includesScratch;
  options.requiresIntent = Boolean(options.caseDocs.length || options.scratch);
  for (let i = 0; i < options.native.length; i++) {
    if (values.has(options.native[i])) {
      const key = options.native[i];
      const value = options.native[++i];
      if (listFlags.has(key)) options.selection.push(key, value);
    }
  }
  return options;
}
