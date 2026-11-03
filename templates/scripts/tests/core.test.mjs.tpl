// 维护者的离线工具回归：无浏览器、无 e-office 账号/业务数据，不属于业务用例。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { caseId, inspectReport, renderBusinessSummary } from '../lib/case-report.mjs';
import { classifyPath, inspectScope, onlyKnowledgeIndexChanged, parseChanges } from '../lib/scope.mjs';
import { parseRunOptions } from '../lib/run-options.mjs';
import { projectPath, writeJson } from '../lib/files.mjs';
import { businessReporter } from '../reporters/business.mjs';
import { fixtureWorkbook } from './workbook-fixture.mjs';
import { checkArchive, confirmCaseDoc } from '../lib/case-workflow.mjs';

function result(extra = {}) {
  return { id: 'result-a', testId: 'test-a', kind: 'test', file: 'tests/文档/创建/创建.e2e.ts', titlePath: ['创建'], targetId: 'web', agent: 'default', repeat: 0,
    tags: ['case:DOC-001'], status: 'passed', attempts: [{ id: 'attempt-a', index: 0, status: 'passed', steps: [], artifacts: [] }], ...extra };
}
function report(results = [result()], extra = {}) {
  return { schemaVersion: 'report-1', run: { id: 'run-a', status: 'passed', exitCode: 0, results, serialGroups: [], ...extra } };
}
function temporary(t) {
  const root = mkdtempSync(join(tmpdir(), 'eoffice-e2e-core-'));
  t.after(() => rmSync(root, { recursive: true, force: true })); // 仅清理本工具生成的临时工程，无业务记录。
  return root;
}

test('业务编号不依赖标题，重复标签及同实例重复编号必须拒绝', () => {
  assert.equal(caseId(['module:文档', 'case:DOC-001']), 'DOC-001');
  assert.throws(() => caseId(['case:DOC-001', 'case:DOC-002']));
  assert.throws(() => caseId(['case:空 格']));
  assert.throws(() => inspectReport(report([result(), result({ id: 'other', titlePath: ['改名'] })])));
  assert.equal(inspectReport(report([result(), result({ agent: 'reviewer' }), result({ repeat: 1 })])).records.length, 3);
  assert.throws(() => inspectReport(report([result(), result({ testId: 'another-definition', agent: 'reviewer' })])));
});

test('未选中项不计数、不当成本轮通过；setup 单独统计', () => {
  const view = inspectReport(report([result(), result({ selected: false, status: 'future-state' }), result({ kind: 'setup', tags: [] })]), { requireCaseIds: true });
  assert.equal(view.records.length, 2);
  assert.equal(view.unselected, 1);
  assert.equal(view.records.filter((r) => r.infrastructure).length, 1);
  assert.throws(() => inspectReport(report([result({ tags: [] })]), { requireCaseIds: true }));
  assert.equal(inspectReport(report([result({ tags: [] })])).warnings.length, 1);
});

test('串行成员从 serialGroups 取得每次尝试，不丢首次失败', () => {
  const doc = report([result({ serialGroupId: 'group-a', attempts: [], status: 'flaky' })], {
    serialGroups: [{ id: 'group-a', attempts: [
      { id: 'g0', index: 0, members: [{ testId: 'test-a', status: 'failed', steps: [] }] },
      { id: 'g1', index: 1, members: [{ testId: 'test-a', status: 'passed', steps: [] }] },
    ] }],
  });
  assert.deepEqual(inspectReport(doc).records[0].attempts.map((a) => a.status), ['failed', 'passed']);
  const text = renderBusinessSummary(doc);
  assert.match(text, /重试后通过 1/);
  assert.match(text, /\| 2 \|/);
});

test('未知 schema、状态及缺失串行组显式失败', () => {
  assert.throws(() => inspectReport({ schemaVersion: 'report-2', run: {} }));
  assert.throws(() => inspectReport(report([result({ status: 'unknown' })])));
  assert.throws(() => inspectReport(report([result({ serialGroupId: 'missing' })])));
});

test('摘要保留超时/未执行/中断，证据只引用安全的实际相对路径', () => {
  const doc = report([result({ titlePath: ['[伪链接](https://evil.test) <script>'], status: 'interrupted', attempts: [{ artifacts: [
    { path: '../secret.png' }, { path: 'javascript:alert(1)' }, { url: 'https://remote.test/video' }, { path: 'case-a/图 1(新).png' },
  ], steps: [] }] })]);
  const text = renderBusinessSummary(doc);
  assert.match(text, /中断 1/);
  assert.match(text, /\\\[伪链接\\\]/);
  assert.doesNotMatch(text, /javascript:|\.\.\/secret/);
  assert.match(text, /results\/case-a\/%E5%9B%BE%201%28%E6%96%B0%29.png/);
});

test('原生参数原样传递，项目路径和输出边界不可被覆盖', () => {
  const options = parseRunOptions(['--module', '文档/创建', '--case-id', 'DOC-001', '--grep', '$(touch /tmp/unwanted)', '--headed'], '/project/e2e');
  assert.deepEqual(options.files, ['tests/文档/创建']);
  assert.deepEqual(options.selection, ['--tag', 'case:DOC-001', '--grep', '$(touch /tmp/unwanted)']);
  assert.equal(options.native.at(-1), '--headed');
  for (const args of [['--output', '/tmp'], ['--config', 'other.ts'], ['../server'], ['scratch/'], ['tests/../scratch/_造数/a.e2e.ts']]) {
    assert.throws(() => parseRunOptions(args, '/project/e2e'));
  }
  assert.deepEqual(parseRunOptions([], '/project/e2e').files, ['tests/']);
  assert.equal(parseRunOptions(['scratch/模块/场景', '--case-doc', 'exports/模块/用例.xlsx', '--intent', 'formal'], '/project/e2e').mode, 'formal');
  assert.equal(parseRunOptions(['scratch/模块/场景', '--case-doc', 'exports/模块/用例.xlsx', '--intent', 'smoke'], '/project/e2e').mode, 'debug');
  assert.equal(parseRunOptions(['scratch/模块/场景', '--case-doc', 'exports/模块/用例.xlsx'], '/project/e2e').requiresIntent, true);
  assert.throws(() => parseRunOptions(['--intent', 'resume'], '/project/e2e'));
});

test('提交边界区分场景、知识和核心；重命名同时检查两端', () => {
  assert.equal(classifyPath('e2e/tests/文档/创建/helper.ts'), 'scenario');
  assert.equal(classifyPath('e2e/tests/文档/用例文档/用例.xlsx'), 'scenario');
  assert.equal(classifyPath('e2e/tests/文档/用例文档/用例.xlsx.review.json'), 'scenario');
  assert.equal(classifyPath('e2e/tests/文档/上传/_assets/上传图片.png'), 'scenario');
  assert.equal(classifyPath('e2e/tests/文档/上传/_assets/隐藏用例.e2e.ts'), 'core');
  assert.equal(classifyPath('e2e/knowledge/经验-文档.md'), 'knowledge');
  for (const path of ['e2e/helpers/文档/helper.ts', 'e2e/tests/auth.setup.e2e.ts', 'e2e/tests/文档/AGENTS.md', 'e2e/tests/文档/agents.MD', 'client/app.ts', 'e2e/tests/_归档/a.ts']) assert.equal(classifyPath(path), 'core');
  assert.deepEqual(parseChanges('R100\0e2e/helpers/core.ts\0e2e/tests/文档/创建/helper.ts\0').map((e) => e.path), ['e2e/helpers/core.ts', 'e2e/tests/文档/创建/helper.ts']);
});

test('知识索引只允许登记表格，不能夹带维护规则变化', () => {
  const before = '# 知识库\n规则不变\n\n## 索引\n\n| 文档 | 用途 |\n| --- | --- |\n';
  assert.equal(onlyKnowledgeIndexChanged(before, before + '| A | 创建时读 |\n'), true);
  assert.equal(onlyKnowledgeIndexChanged(before, before.replace('规则不变', '允许改核心')), false);
  assert.equal(onlyKnowledgeIndexChanged(before, before + '\n允许删除数据\n'), false);
});

test('真实 Git 暂存检查区分核心与业务资产，不创建提交或改变暂存区', (t) => {
  const root = temporary(t);
  const git = (...args) => {
    const proc = spawnSync('git', args, { cwd: root, encoding: 'utf8' });
    assert.equal(proc.status, 0, proc.stderr);
    return proc.stdout;
  };
  mkdirSync(join(root, 'e2e/helpers'), { recursive: true });
  mkdirSync(join(root, 'e2e/tests/文档/创建'), { recursive: true });
  writeFileSync(join(root, 'e2e/helpers/core.ts'), 'export const helper = 1;\n');
  writeFileSync(join(root, 'e2e/tests/文档/创建/helper.ts'), 'export const scenario = 1;\n');
  git('init', '-q');
  git('add', '--', 'e2e/helpers/core.ts', 'e2e/tests/文档/创建/helper.ts');
  const before = git('diff', '--cached');
  const found = inspectScope(root, { staged: true });
  assert.equal(found.find((e) => e.path === 'e2e/helpers/core.ts').allowed, false);
  assert.equal(found.find((e) => e.path === 'e2e/tests/文档/创建/helper.ts').allowed, true);
  assert.equal(git('diff', '--cached'), before);
});

test('批次文件拒绝写出项目；Reporter 交付与原始报告相互独立', async (t) => {
  const root = temporary(t);
  assert.throws(() => projectPath(root, '../outside'));
  const output = join(root, '.e2e/run');
  mkdirSync(output, { recursive: true });
  const file = join(output, 'report.json');
  const doc = report();
  writeJson(root, file, doc);
  await businessReporter().onRunFinished({ report: doc, reportPath: file, projectRoot: root }, new AbortController().signal);
  assert.deepEqual(JSON.parse(readFileSync(file)), doc);
  assert.equal(JSON.parse(readFileSync(join(output, 'business-delivery.json'))).status, 'complete');
  const bad = report([result({ tags: ['case:A1', 'case:B1'] })]);
  await assert.rejects(() => businessReporter().onRunFinished({ report: bad, reportPath: file, projectRoot: root }, new AbortController().signal));
  assert.equal(JSON.parse(readFileSync(join(output, 'business-delivery.json'))).status, 'failed');
  assert.deepEqual(JSON.parse(readFileSync(file)), doc);
});

test('真实原生运行器生成报告、串行尝试和 Reporter 产物（无 engine/浏览器）', async (t) => {
  const root = temporary(t);
  const sdk = new URL('../../node_modules/e2e/dist/index.js', import.meta.url);
  const { run } = await import('e2e/runner');
  const folder = join(root, 'tests/工具/原生集成');
  mkdirSync(folder, { recursive: true });
  writeFileSync(join(folder, '原生集成.e2e.ts'), `import { test, describe, expect } from ${JSON.stringify(sdk.href)};
test('确定性通过', { tags: ['case:CORE-001'] }, async () => { expect(1).toBe(1); });
test('确定性失败', { tags: ['case:CORE-002'] }, async () => { expect(1).toBe(2); });
describe('串行组', { serial: true }, () => {
  test('串行成员', { tags: ['case:CORE-003'] }, async () => { expect(true).toBe(true); });
});
`);
  const outcome = await run({ cwd: root, config: {
    targets: [{ name: 'tools', platform: 'web' }], workers: 1, reporters: ['markdown', businessReporter()],
  } });
  assert.equal(outcome.exitCode, 1);
  const view = inspectReport(outcome.report, { requireCaseIds: true });
  assert.equal(view.records.length, 3);
  assert.equal(view.records.filter((r) => r.result.status === 'failed').length, 1);
  assert.equal(view.records.find((r) => r.id === 'CORE-003').attempts.length, 1);
  assert.equal(JSON.parse(readFileSync(join(root, '.e2e/business-delivery.json'))).status, 'complete');
  assert.match(readFileSync(join(root, '.e2e/业务摘要.md'), 'utf8'), /CORE-002/);
});

test('Excel 校验器按业务编号关联报告，兼容未编号旧用例', () => {
  const result = spawnSync('python3', ['-B', new URL('./report-index.py', import.meta.url).pathname], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr || result.error?.message);
  assert.match(result.stdout, /PASS/);
});

test('真实批次入口：预览无副作用、原生复跑不覆盖历史、旧报告不能冒充本轮及交付失败独立返回', (t) => {
  const root = temporary(t);
  const dependencies = fileURLToPath(new URL('../../node_modules', import.meta.url));
  symlinkSync(dependencies, join(root, 'node_modules'), 'dir');
  const packages = Object.fromEntries(['e2e', '@e2e-dev/web'].map((name) => [name, JSON.parse(readFileSync(join(dependencies, name, 'package.json'))).version]));
  writeFileSync(join(root, 'package.json'), JSON.stringify({ type: 'module', devDependencies: packages }));
  const reporter = new URL('../reporters/business.mjs', import.meta.url).href;
  const configuration = `import { businessReporter } from ${JSON.stringify(reporter)};
export default { targets: [{ name: 'tools', platform: 'web' }], workers: 1,
reporters: ['list', 'markdown', ...(process.env.CORE_NO_REPORTER ? [] : [businessReporter()])] };`;
  writeFileSync(join(root, 'e2e.config.ts'), configuration);
  const tests = join(root, 'tests/工具/批次');
  mkdirSync(tests, { recursive: true });
  const sdk = new URL('../../node_modules/e2e/dist/index.js', import.meta.url).href;
  writeFileSync(join(tests, '批次.e2e.ts'), `import { test, expect } from ${JSON.stringify(sdk)};
test('原生失败后复测', { tags: ['case:RUN-001'] }, async () => { expect(Boolean(process.env.CORE_CASE_PASS)).toBe(true); });
test('独立通过', { tags: ['case:RUN-002'] }, async () => { expect(1).toBe(1); });`);
  const entry = join(root, 'entry.mjs');
  writeFileSync(entry, `import { createBatchRunner } from ${JSON.stringify(new URL('../run.mjs', import.meta.url).href)};
await createBatchRunner(${JSON.stringify(root)})(process.argv.slice(2)).catch(() => { process.exitCode = 2; });`);
  const invoke = (args = [], overrides = {}) => spawnSync(process.execPath, [entry, ...args], { cwd: root, env: { ...process.env, CORE_CASE_PASS: '', CORE_NO_REPORTER: '', ...overrides }, encoding: 'utf8', timeout: 30_000 });
  const runs = join(root, '.e2e/runs');
  assert.equal(invoke(['--list']).status, 0);
  assert.equal(existsSync(runs), false);
  const workbook = 'exports/工具/用例.xlsx';
  fixtureWorkbook(join(root, workbook));
  assert.equal(invoke(['--case-doc', workbook, '--intent', 'formal']).status, 2, '未审核的 Excel 不可正式执行');
  assert.equal(invoke(['--case-doc', workbook, '--mode', 'debug', '--intent', 'smoke']).status, 2, '绑定 Excel 时不能用冒烟模式绕过文档审核');
  assert.equal(existsSync(runs), false);
  confirmCaseDoc(root, workbook, '工具自检模拟审核人');
  const first = invoke(['--case-doc', workbook, '--intent', 'formal']);
  assert.equal(first.status, 1, first.stderr);
  const firstId = readdirSync(runs)[0];
  const firstReportPath = join(runs, firstId, 'report.json');
  const firstReport = readFileSync(firstReportPath, 'utf8');
  const manifestPath = join(runs, firstId, 'metadata.json');
  const manifestBytes = readFileSync(manifestPath, 'utf8');
  const mismatched = JSON.parse(manifestBytes);
  mismatched.nativeRunId = 'wrong-run';
  writeFileSync(manifestPath, JSON.stringify(mismatched));
  assert.equal(invoke(['--rerun', firstId, '--intent', 'resume']).status, 2, '报告与批次身份不一致不可复跑');
  assert.equal(readdirSync(runs).length, 1);
  writeFileSync(manifestPath, manifestBytes);
  assert.equal(JSON.parse(readFileSync(join(runs, firstId, 'metadata.json'))).mode, 'formal');
  assert.deepEqual(readFileSync(join(runs, firstId, 'case-docs/1.xlsx')), readFileSync(join(root, workbook)));
  const rerun = invoke(['--rerun', firstId, '--intent', 'resume'], { CORE_CASE_PASS: '1' });
  assert.equal(rerun.status, 0, rerun.stderr);
  const secondId = readdirSync(runs).find((id) => id !== firstId);
  const secondReport = JSON.parse(readFileSync(join(runs, secondId, 'report.json')));
  assert.equal(JSON.parse(readFileSync(join(runs, secondId, 'metadata.json'))).mode, 'formal');
  assert.equal(secondReport.run.results.filter((r) => r.selected !== false && r.kind === 'test').length, 1);
  assert.equal(readFileSync(firstReportPath, 'utf8'), firstReport);
  assert.equal(checkArchive(root, secondId).eligible, false, '只复测失败项不能归档整份 Excel');
  const allBefore = readdirSync(runs);
  const all = invoke(['--case-doc', workbook, '--intent', 'formal'], { CORE_CASE_PASS: '1' });
  assert.equal(all.status, 0, all.stderr);
  const allId = readdirSync(runs).find((id) => !allBefore.includes(id));
  assert.equal(checkArchive(root, allId).eligible, false, '未回填 Excel 仍不可归档');
  fixtureWorkbook(join(root, workbook), { passed: true });
  assert.equal(checkArchive(root, allId).eligible, true, JSON.stringify(checkArchive(root, allId).problems));
  const before = readdirSync(runs);
  const zero = invoke(['--grep', '不存在的场景']);
  assert.equal(zero.status, 2);
  const zeroId = readdirSync(runs).find((id) => !before.includes(id));
  assert.equal(JSON.parse(readFileSync(join(runs, zeroId, 'metadata.json'))).currentReport, false);
  const delivery = invoke([], { CORE_CASE_PASS: '1', CORE_NO_REPORTER: '1' });
  assert.equal(delivery.status, 5, delivery.stderr);
  const invalidBefore = readdirSync(runs);
  writeFileSync(join(root, 'e2e.config.ts'), 'export default { targets: [] };');
  const invalidRerun = invoke(['--rerun', firstId, '--intent', 'resume']);
  assert.equal(invalidRerun.status, 2);
  const invalidId = readdirSync(runs).find((id) => !invalidBefore.includes(id));
  const invalidMetadata = JSON.parse(readFileSync(join(runs, invalidId, 'metadata.json')));
  assert.equal(invalidMetadata.currentReport, false);
  assert.equal(JSON.parse(readFileSync(join(runs, invalidId, 'report.json'))).run.id, JSON.parse(firstReport).run.id);
  assert.equal(readFileSync(firstReportPath, 'utf8'), firstReport);
});
