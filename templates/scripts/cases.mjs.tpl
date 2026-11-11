import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { projectPath } from './lib/files.mjs';
import { baselineOf, checkArchive, confirmCaseDoc, readCaseDoc } from './lib/case-workflow.mjs';
import { inspectReport } from './lib/case-report.mjs';

export function runCases(root, args) {
  const portablePath = (value) => value.replaceAll('\\', '/');
  const python = process.env.E2E_PYTHON || (process.platform === 'win32' ? 'python' : 'python3');
  const [action, ...rest] = args;
  const option = (name) => { const i = rest.indexOf(name); return i < 0 ? null : rest[i + 1]; };
  if (!action || action === '--help') {
    console.log('用法：test:cases -- draft <json> --output <xlsx> | list --module 模块 | inspect <xlsx> | confirm <xlsx> --reviewer 实际审核人 | results --run 批次 | archive-check --run 批次');
    console.log('draft 首次生成未执行初稿并校验，拒绝覆盖已有 Excel；输入规范见 docs/初稿生成入口.md。');
    console.log('confirm 仅在测试人员明确确认该份 Excel 后由 AI 调用，不代表自动审查业务正确性。命令不修改原 xlsx。');
    return;
  }
  const valid = action === 'list' ? rest.length === 2 && rest[0] === '--module'
    : action === 'draft' ? rest.length === 3 && rest[1] === '--output' && !rest[0].startsWith('--')
    : action === 'inspect' ? rest.length === 1 && !rest[0].startsWith('--')
    : action === 'confirm' ? rest.length === 3 && rest[1] === '--reviewer' && !rest[0].startsWith('--')
    : ['results', 'archive-check'].includes(action) ? rest.length === 2 && rest[0] === '--run' : false;
  if (!valid || rest.some((value) => !value || /[\r\n\0]/.test(value))) throw new Error('请按 --help 填写完整参数，不接受额外选项');
  if (action === 'draft') {
    const input = projectPath(root, portablePath(rest[0]));
    const output = projectPath(root, portablePath(rest[2]));
    const generate = join(dirname(fileURLToPath(import.meta.url)), 'generate-case-doc.py');
    const result = spawnSync(python, ['-B', generate, root, input, output], { encoding: 'utf8', timeout: 60_000, maxBuffer: 2 * 1024 * 1024 });
    if (result.error || result.status !== 0) throw new Error(`初稿生成未完成：${result.stderr?.trim().slice(0, 2500) || '请检查 Python/openpyxl 依赖和文件权限'}`);
    console.log(JSON.stringify(JSON.parse(result.stdout), null, 2));
  } else if (action === 'list') {
    const module = portablePath(option('--module') ?? '');
    if (!module || !module.split('/').every((p) => p && !p.startsWith('_') && !p.includes('.') && !p.includes('\\'))) throw new Error('请填写有效模块目录');
    const found = [];
    const walk = (file) => {
      const path = projectPath(root, file);
      if (!existsSync(path)) return;
      for (const entry of readdirSync(path, { withFileTypes: true })) {
        if (entry.name.startsWith('_') || entry.name.startsWith('.')) continue;
        const child = join(file, entry.name);
        projectPath(root, child);
        if (entry.isDirectory()) walk(child);
        else if (entry.name.endsWith('.xlsx')) {
          try { const model = readCaseDoc(root, child); found.push({ source: model.source, cases: model.cases.length, state: model.state }); }
          catch { found.push({ source: relative(root, projectPath(root, child)), state: 'invalid', reason: '文档格式或读取依赖异常，请单独 inspect' }); }
        }
      }
    };
    for (const base of ['tests', 'scratch', 'exports']) walk(`${base}/${module}`);
    console.log(JSON.stringify({ module, documents: found }, null, 2));
  } else if (action === 'inspect' || action === 'confirm') {
    const file = portablePath(rest[0]);
    const model = action === 'confirm' ? confirmCaseDoc(root, file, option('--reviewer')) : readCaseDoc(root, file);
    console.log(JSON.stringify(model, null, 2));
  } else if (action === 'archive-check') {
    const result = checkArchive(root, option('--run'));
    console.log(JSON.stringify(result, null, 2));
    if (!result.eligible) process.exitCode = 1;
  } else if (action === 'results') {
    const { output, baseline } = baselineOf(root, option('--run'));
    const report = JSON.parse(readFileSync(projectPath(root, output, 'report.json'), 'utf8'));
    const metadata = JSON.parse(readFileSync(projectPath(root, output, 'metadata.json'), 'utf8'));
    if (metadata.currentReport !== true || metadata.nativeRunId !== report.run?.id) throw new Error('本批次没有可确认的新报告');
    const view = inspectReport(report, { requireCaseIds: true });
    const records = view.records.filter((r) => !r.infrastructure);
    console.log(JSON.stringify({ batch: option('--run'), nativeRunId: report.run.id,
      instruction: '仅按本批次实际步骤/证据回填。未选中项不继承旧通过；不得由整条 passed 推测逐业务步骤实测。保留人工备注、反馈号和样式。',
      cases: baseline.documents.flatMap((d) => d.cases.map((c) => ({ id: c.id, source: d.source, sheet: c.sheet, row: c.row,
        design: c.design, executions: records.filter((r) => r.id === c.id).map((r) => ({ resultId: r.result.id, status: r.result.status,
          target: r.result.targetId, agent: r.result.agent, repeat: r.result.repeat, attempts: r.attempts })) }))) }, null, 2));
  } else throw new Error('未知用例工作流命令，请查看 --help');
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  try { runCases(dirname(dirname(fileURLToPath(import.meta.url))), process.argv.slice(2)); }
  catch (error) {
    console.error(`[e2e] ${/^(初稿|用例|正式|本批次|请|业务|批次)/.test(error.message) ? error.message : '用例工作流未完成，请检查参数、文件路径及 Python/openpyxl 依赖'}`);
    process.exitCode = 2;
  }
}
