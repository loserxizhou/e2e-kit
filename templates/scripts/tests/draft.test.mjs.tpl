// 固定生成入口的维护者自检；隔离临时目录，无业务环境/浏览器/账号。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync, mkdirSync, existsSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { readCaseDoc, confirmCaseDoc } from '../lib/case-workflow.mjs';
import { fixtureWorkbook } from './workbook-fixture.mjs';

const generator = new URL('../generate-case-doc.py', import.meta.url).pathname;
const example = new URL('../../templates/用例初稿示例.json', import.meta.url);
function temporary(t) {
  const root = mkdtempSync(join(tmpdir(), 'eoffice-draft-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return root;
}
function generate(root, model, output = 'exports/模块/初稿.xlsx') {
  const input = join(root, 'draft.json');
  writeFileSync(input, JSON.stringify(model));
  return spawnSync('python3', ['-B', generator, root, input, join(root, output)], { encoding: 'utf8', timeout: 30_000 });
}
function model() { return JSON.parse(readFileSync(example)); }

test('固定初稿生成后可校验、读取及审核；所有结果未执行，不冒写审核', (t) => {
  const root = temporary(t), content = model();
  content.sheets[0].cases[0].scenario = '=HYPERLINK("https://example.invalid", "业务输入")';
  const proc = generate(root, content);
  assert.equal(proc.status, 0, proc.stderr);
  const delivered = JSON.parse(proc.stdout);
  assert.equal(delivered.cases, 1);
  assert.equal(delivered.errors, 0);
  assert.ok(Number.isFinite(delivered.durationMs));
  const doc = readCaseDoc(root, delivered.output);
  assert.equal(doc.state, 'draft');
  assert.equal(doc.cases[0].design['测试场景'], content.sheets[0].cases[0].scenario);
  assert.match(doc.cases[0].design['前置条件'], /A00/);
  assert.match(doc.cases[0].design['前置条件'], /D00/);
  const check = spawnSync('python3', ['-B', new URL('../check-case-doc.py', import.meta.url).pathname, join(root, delivered.output), '--draft'], { encoding: 'utf8' });
  assert.equal(check.status, 0, check.stdout + check.stderr);
  assert.equal(existsSync(join(root, delivered.output + '.review.json')), false);
  const bytes = readFileSync(join(root, delivered.output));
  assert.equal(confirmCaseDoc(root, delivered.output, '自检模拟审核人').state, 'confirmed');
  assert.deepEqual(readFileSync(join(root, delivered.output)), bytes);
});

test('覆盖和软链接路径拒绝，现有工作簿及审核记录保留', (t) => {
  const root = temporary(t), content = model();
  const first = generate(root, content);
  assert.equal(first.status, 0, first.stderr);
  const file = join(root, JSON.parse(first.stdout).output), original = readFileSync(file);
  const second = generate(root, content);
  assert.equal(second.status, 2);
  assert.match(second.stderr, /拒绝覆盖/);
  assert.deepEqual(readFileSync(file), original);
  symlinkSync(join(root, 'exports/模块'), join(root, 'exports/link'), 'dir');
  assert.equal(generate(root, content, 'exports/link/new.xlsx').status, 2);
  assert.equal(existsSync(join(root, 'exports/模块/new.xlsx')), false);
  assert.equal(generate(root, content, 'tests/模块/初稿.xlsx').status, 2);
});

test('错误编号/引用/步骤/权限适用性及伪造执行字段不交付文件', (t) => {
  const root = temporary(t);
  const corruptions = [
    (m) => m.sheets[0].cases.push(structuredClone(m.sheets[0].cases[0])),
    (m) => m.sheets[0].cases[0].data.push('D99'),
    (m) => m.sheets[0].cases[0].steps.push('额外步骤'),
    (m) => m.sheets[0].cases[0].result = '通过',
    (m) => m.permissionTesting.enabled = true,
    (m) => m.data[0].source = '新建',
    (m) => m.accounts[0].checks = ['V99'],
    (m) => m.sheets[0].name = '说明',
    (m) => m.sheets[0].cases[0].preconditions = ['依赖D99'],
  ];
  for (const corrupt of corruptions) {
    const content = model(); corrupt(content);
    const result = generate(root, content);
    assert.equal(result.status, 2, result.stdout);
    assert.equal(existsSync(join(root, 'exports/模块/初稿.xlsx')), false);
  }
});

test('读取缺省或少报维度的合法工作簿，并按实际行列限制防止绕过', (t) => {
  const root = temporary(t), file = 'exports/模块/初稿.xlsx';
  mkdirSync(join(root, 'exports/模块'), { recursive: true });
  const cases = [];
  for (const dimension of ['correct', null, 'small']) {
    fixtureWorkbook(join(root, file), { dimension });
    cases.push(readCaseDoc(root, file));
    for (const extra of [{ overflowRow: 10001 }, { overflowColumn: 'BM' }]) {
      fixtureWorkbook(join(root, file), { dimension, ...extra });
      assert.throws(() => readCaseDoc(root, file), /实际规模超过限制/);
    }
  }
  assert.deepEqual(cases.map(d => d.cases.length), [2, 2, 2]);
  assert.equal(new Set(cases.map(d => d.designHash)).size, 1);
});
