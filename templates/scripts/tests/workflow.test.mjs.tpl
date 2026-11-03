import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, mkdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { checkArchive, checkCaseSelection, confirmCaseDoc, prepareCaseDocs, readCaseDoc, snapshotCaseDocs, sourceFingerprint, baselineOf } from '../lib/case-workflow.mjs';
import { writeJson } from '../lib/files.mjs';
import { runCases } from '../cases.mjs';
import { fixtureWorkbook } from './workbook-fixture.mjs';

const file = 'exports/工具/用例.xlsx';
function temporary(t) {
  const root = mkdtempSync(join(tmpdir(), 'eoffice-case-workflow-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  fixtureWorkbook(join(root, file));
  return root;
}

test('审核按业务内容失效；回填结果/人工备注及排序不改变设计审核', (t) => {
  const root = temporary(t);
  assert.equal(readCaseDoc(root, file).state, 'draft');
  assert.throws(() => prepareCaseDocs(root, [file]), /未审核/);
  const approved = confirmCaseDoc(root, file, '真实审核人');
  fixtureWorkbook(join(root, file), { passed: true, note: '人工追加反馈', ids: ['RUN-002', 'RUN-001'] });
  const filled = readCaseDoc(root, file);
  assert.equal(filled.designHash, approved.designHash);
  assert.equal(filled.state, 'confirmed');
  assert.notEqual(filled.fileHash, approved.fileHash);
  fixtureWorkbook(join(root, file), { expectation: '1. 新业务标准' });
  assert.equal(readCaseDoc(root, file).state, 'changed');
  fixtureWorkbook(join(root, file), { role: '改变身份条件' });
  assert.equal(readCaseDoc(root, file).state, 'changed');
});

test('工作簿/跨工作簿重号、未关联执行编号及路径越界均阻断', (t) => {
  const root = temporary(t);
  fixtureWorkbook(join(root, file), { ids: ['RUN-001', 'RUN-001'] });
  assert.throws(() => readCaseDoc(root, file), /重复/);
  fixtureWorkbook(join(root, file));
  const approved = confirmCaseDoc(root, file, '审核人');
  assert.throws(() => prepareCaseDocs(root, [file, file]), /之间编号重复/);
  assert.throws(() => checkCaseSelection({ pairs: [{ file: 'tests/工具/场景/a.e2e.ts', tags: ['case:OTHER-001'] }] }, [approved]), /未关联/);
  assert.throws(() => baselineOf(root, '../outside'), /批次编号/);
  assert.throws(() => runCases(root, ['confirm', file, '--reviewer']), /完整参数/);
  assert.throws(() => readCaseDoc(root, '../outside.xlsx'));
  symlinkSync(join(root, file), join(root, 'exports/link.xlsx'));
  assert.throws(() => readCaseDoc(root, 'exports/link.xlsx'), /软链接/);
});

test('批次快照保持原字节；读取与快照之间的文件变化必须重读', (t) => {
  const root = temporary(t);
  const docs = [confirmCaseDoc(root, file, '审核人')];
  const output = join(root, '.e2e/runs/snapshot');
  snapshotCaseDocs(root, output, docs);
  const bytes = readFileSync(join(output, 'case-docs/1.xlsx'));
  assert.deepEqual(bytes, readFileSync(join(root, file)));
  fixtureWorkbook(join(root, file), { passed: true });
  assert.deepEqual(readFileSync(join(output, 'case-docs/1.xlsx')), bytes);
  assert.throws(() => snapshotCaseDocs(root, join(root, 'other'), docs), /发生变化/);
});

test('草稿独立校验不读取最近一次报告；不能携带旧通过', (t) => {
  const root = temporary(t);
  const check = () => spawnSync('python3', ['-B', new URL('../check-case-doc.py', import.meta.url).pathname, join(root, file), '--draft'], { encoding: 'utf8' });
  let result = check();
  assert.equal(result.status, 0, result.stdout + result.stderr);
  fixtureWorkbook(join(root, file), { passed: true });
  result = check();
  assert.equal(result.status, 1);
  assert.match(result.stdout, /草稿/);
});

test('归档须完整稳定通过、回填一致、证据与源码有效；部分复测不能代替全量', (t) => {
  const root = temporary(t);
  const batch = '20261102T080000Z-00000000-0000-0000-0000-000000000000';
  const output = join(root, '.e2e/runs', batch);
  const pairs = [{ file: 'tests/工具/批次/批次.e2e.ts', disposition: 'run', tags: ['case:RUN-001'] }];
  mkdirSync(join(root, 'tests/工具/批次'), { recursive: true });
  writeFileSync(join(root, pairs[0].file), '// fixture');
  fixtureWorkbook(join(root, file), { passed: true });
  snapshotCaseDocs(root, output, [confirmCaseDoc(root, file, '审核人')]);
  const doc = { schemaVersion: 'report-1', run: { id: 'run-a', status: 'passed', exitCode: 0,
    results: ['RUN-001', 'RUN-002'].map((id) => ({ id, testId: id, file: pairs[0].file, titlePath: [id], tags: [`case:${id}`], status: 'passed',
      attempts: [{ steps: [], artifacts: [] }] })) } };
  const metadata = { schemaVersion: 'eoffice-run-1', batchId: batch, mode: 'formal', nativeRunId: 'run-a', currentReport: true,
    phase: 'finished', delivery: 'complete', runnerExitCode: 0, selection: { preflightPairs: pairs }, sourceFingerprint: sourceFingerprint(root, pairs.map((p) => p.file)) };
  writeJson(root, join(output, 'metadata.json'), metadata);
  const save = () => writeJson(root, join(output, 'report.json'), doc);
  save();
  for (const name of ['summary.md', 'junit.xml', '业务摘要.md']) writeFileSync(join(output, name), 'fixture');
  writeJson(root, join(output, 'business-delivery.json'), { schemaVersion: 'eoffice-delivery-1', nativeRunId: 'run-a', status: 'complete' });
  assert.equal(checkArchive(root, batch).eligible, true);
  const missing = doc.run.results.pop(); save();
  assert.match(checkArchive(root, batch).problems.join(), /缺少唯一/);
  doc.run.results.push(missing);
  missing.status = 'flaky'; save();
  assert.match(checkArchive(root, batch).problems.join(), /稳定通过/);
  missing.status = 'passed'; missing.attempts[0].steps.push({ status: 'failed' }); save();
  assert.match(checkArchive(root, batch).problems.join(), /失败步骤/);
  missing.attempts[0].steps = []; missing.attempts[0].artifacts = [{ path: 'lost.png' }]; save();
  assert.match(checkArchive(root, batch).problems.join(), /证据文件缺失/);
  missing.attempts[0].artifacts = []; save();
  fixtureWorkbook(join(root, file));
  assert.match(checkArchive(root, batch).problems.join(), /完整校验/);
  fixtureWorkbook(join(root, file), { passed: true });
  writeFileSync(join(root, pairs[0].file), '// changed');
  assert.match(checkArchive(root, batch).problems.join(), /源码/);
});
