import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, readdirSync, lstatSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { projectPath, writeAtomic, writeJson } from './files.mjs';
import { caseId, infrastructure, inspectReport } from './case-report.mjs';

const hash = (data) => createHash('sha256').update(data).digest('hex');
const readJson = (root, file) => JSON.parse(readFileSync(projectPath(root, file), 'utf8'));
const reader = join(dirname(fileURLToPath(import.meta.url)), '../read-case-doc.py');
const python = process.env.E2E_PYTHON || (process.platform === 'win32' ? 'python' : 'python3');

export function readCaseDoc(root, file) {
  const path = projectPath(root, file);
  const source = relative(root, path).replaceAll('\\', '/');
  if (!/^(tests|scratch|exports)\/.+\.xlsx$/i.test(source)) throw new Error('用例文档须位于 tests、scratch 或 exports 中');
  const result = spawnSync(python, ['-B', reader, path], { encoding: 'utf8', maxBuffer: 8 * 1024 * 1024, timeout: 30_000 });
  if (result.error || result.status !== 0) throw new Error(`用例文档读取失败：${result.stderr?.trim().slice(0, 200) || '请检查 Python/openpyxl 依赖'}`);
  const model = JSON.parse(result.stdout);
  if (model.schemaVersion !== 'eoffice-case-doc-1' || !model.cases?.length) throw new Error('无法识别用例文档结构');
  const receipt = `${path}.review.json`;
  const review = existsSync(receipt) ? readJson(root, receipt) : null;
  // 审核绑定业务内容，整理路径时可随文档移动回执；原路径保留作审计线索。
  const confirmed = review?.schemaVersion === 'eoffice-case-review-1'
    && review.designHash === model.designHash && typeof review.reviewer === 'string' && review.reviewer.trim()
    && Number.isFinite(Date.parse(review.confirmedAt));
  return { ...model, source, review, state: confirmed ? 'confirmed' : review ? 'changed' : 'draft' };
}

export function confirmCaseDoc(root, file, reviewer) {
  if (!reviewer?.trim() || reviewer.length > 80 || /[\r\n\0]/.test(reviewer)) throw new Error('请填写实际审核人（最多 80 字符）');
  const model = readCaseDoc(root, file);
  writeJson(root, projectPath(root, `${model.source}.review.json`), { schemaVersion: 'eoffice-case-review-1',
    source: model.source, designHash: model.designHash, reviewer, confirmedAt: new Date().toISOString() });
  return readCaseDoc(root, file);
}

export function prepareCaseDocs(root, files, { requireConfirmed = true } = {}) {
  if (!files.length) throw new Error('正式运行须用 --case-doc 指定测试人员确认过的 Excel');
  const docs = files.map((file) => readCaseDoc(root, file));
  const seen = new Set();
  for (const doc of docs) {
    if (requireConfirmed && doc.state !== 'confirmed') throw new Error(`用例文档未审核或业务定义已变化：${doc.source}`);
    for (const record of doc.cases) {
      if (seen.has(record.id)) throw new Error(`用例文档之间编号重复：${record.id}`);
      seen.add(record.id);
    }
  }
  return docs;
}

export function checkCaseSelection(plan, docs) {
  const allowed = new Set(docs.flatMap((d) => d.cases.map((c) => c.id)));
  for (const pair of plan.pairs) {
    if (pair.disposition === 'filtered' || infrastructure(pair)) continue;
    const id = caseId(pair.tags);
    if (!id || !allowed.has(id)) throw new Error(`用例编号未关联到本次 Excel：${id ?? pair.title}`);
  }
}

export function snapshotCaseDocs(root, output, docs) {
  const documents = docs.map((doc, index) => {
    const snapshot = `case-docs/${index + 1}.xlsx`;
    const data = readFileSync(projectPath(root, doc.source));
    if (hash(data) !== doc.fileHash) throw new Error('用例文档在准备期间发生变化，请重新读取');
    writeAtomic(root, projectPath(root, output, snapshot), data);
    return { ...doc, snapshot };
  });
  writeJson(root, projectPath(root, output, 'case-baseline.json'), { schemaVersion: 'eoffice-case-baseline-1', documents });
}

// 固定实际执行文件、所属业务模块及公共代码/素材指纹；不读取 .env、依赖或运行产物。
export function sourceFingerprint(root, selectedFiles) {
  const paths = new Set();
  let bytes = 0;
  const walk = (file) => {
    const path = projectPath(root, file);
    if (!existsSync(path)) return;
    const stat = lstatSync(path);
    if (stat.isDirectory()) {
      for (const entry of readdirSync(path)) {
        const business = /^(tests|scratch)[/\\]/.test(file);
        if (entry.startsWith('.') || (business && entry.startsWith('_') && entry !== '_assets') || ['node_modules', '用例文档'].includes(entry)) continue;
        walk(join(file, entry));
      }
    } else if ((/\.(?:[cm]?[jt]sx?|py|json|csv|ya?ml|png|jpe?g|webp)$/i.test(path) || file.split(/[/\\]/).includes('_assets')) && !/\.review\.json$/i.test(path)) {
      if (stat.size > 20 * 1024 * 1024) throw new Error('用例源码或素材超过 20 MB 限制');
      const key = relative(root, path);
      if (!paths.has(key)) bytes += stat.size;
      if (bytes > 100 * 1024 * 1024 || paths.size >= 3000) throw new Error('用例源码范围过大，请缩小运行范围');
      paths.add(key);
    }
  };
  for (const file of ['e2e.config.ts', 'package.json', 'package-lock.json', 'helpers', 'scripts']) walk(file);
  for (const file of selectedFiles) {
    if (!/^(tests|scratch)\//.test(file)) throw new Error('用例源码路径不合法');
    const parts = file.split('/');
    walk(parts.length > 2 ? parts.slice(0, 2).join('/') : file);
  }
  if (paths.size > 3000) throw new Error('用例源码范围过大，请缩小运行范围');
  return [...paths].sort().map((file) => ({ path: file.replaceAll('\\', '/'), sha256: hash(readFileSync(projectPath(root, file))) }));
}

export function baselineOf(root, batch) {
  if (typeof batch !== 'string' || !/^[0-9]{8}T[0-9]{6}Z-[a-f0-9-]{36}$/.test(batch)) throw new Error('请填写有效的运行批次编号');
  const output = projectPath(root, '.e2e/runs', batch);
  const baseline = readJson(root, join(output, 'case-baseline.json'));
  if (baseline.schemaVersion !== 'eoffice-case-baseline-1' || !Array.isArray(baseline.documents)) throw new Error('本批次没有有效的 Excel 基线');
  return { output, baseline };
}

export function checkArchive(root, batch) {
  const { output, baseline } = baselineOf(root, batch);
  const metadata = readJson(root, join(output, 'metadata.json'));
  const report = readJson(root, join(output, 'report.json'));
  const view = inspectReport(report, { requireCaseIds: true });
  const problems = [];
  if (metadata.schemaVersion !== 'eoffice-run-1' || metadata.mode !== 'formal' || metadata.batchId !== batch || metadata.currentReport !== true || metadata.nativeRunId !== report.run.id
    || metadata.phase !== 'finished' || metadata.delivery !== 'complete' || metadata.runnerExitCode !== 0 || report.run.exitCode !== 0 || report.run.status !== 'passed') problems.push('本批次执行或交付尚未完整通过');
  for (const name of ['summary.md', 'junit.xml', '业务摘要.md', 'business-delivery.json']) {
    const file = projectPath(output, name);
    if (!existsSync(file) || !lstatSync(file).isFile()) problems.push(`批次交付文件缺失：${name}`);
  }
  const deliveryFile = projectPath(output, 'business-delivery.json');
  if (existsSync(deliveryFile)) {
    const delivery = readJson(output, deliveryFile);
    if (delivery.schemaVersion !== 'eoffice-delivery-1' || delivery.nativeRunId !== report.run.id || delivery.status !== 'complete') problems.push('业务摘要交付身份与当前报告不一致');
  }
  if (report.run.errors?.length) problems.push('原生报告仍有运行错误');
  const expected = new Set();
  for (const doc of baseline.documents) {
    const data = readFileSync(projectPath(output, doc.snapshot));
    if (hash(data) !== doc.fileHash) problems.push('批次 Excel 快照校验不一致');
    const current = readCaseDoc(root, doc.source);
    if (doc.state !== 'confirmed' || current.state !== 'confirmed' || current.designHash !== doc.designHash) problems.push(`业务定义未确认或已变化：${doc.source}`);
    for (const record of doc.cases) {
      if (expected.has(record.id)) problems.push(`基线编号重复：${record.id}`);
      expected.add(record.id);
    }
    const validation = spawnSync(python, ['-B', join(dirname(reader), 'check-case-doc.py'),
      projectPath(root, doc.source), projectPath(output, 'report.json')], { encoding: 'utf8', timeout: 30_000, maxBuffer: 2 * 1024 * 1024 });
    if (validation.error || validation.status !== 0) problems.push(`Excel 结果或准备记录尚未通过完整校验：${doc.source}（请使用 check-case-doc.py 查看明细）`);
  }
  const actual = new Map();
  for (const record of view.records) {
    if (record.result.status !== 'passed') problems.push(`尚未稳定通过：${record.id ?? record.result.file}`);
    if (!record.attempts.length || record.attempts.some((a) => a.status === 'failed' || a.error || (a.steps ?? []).some((s) => s.status === 'failed' || s.error))) problems.push(`执行中仍有失败步骤或缺少尝试：${record.id ?? record.result.file}`);
    if (!record.infrastructure) actual.set(record.id, (actual.get(record.id) ?? 0) + 1);
    for (const attempt of record.attempts) for (const artifact of [...(attempt.artifacts ?? []), ...(attempt.steps ?? []).flatMap((s) => s.artifacts ?? [])]) {
      if (artifact.path) {
        const file = projectPath(join(output, 'results'), artifact.path);
        if (!existsSync(file) || !lstatSync(file).isFile()) problems.push('本批次证据文件缺失');
      }
    }
  }
  for (const id of expected) if (actual.get(id) !== 1) problems.push(`用例缺少唯一的本次执行：${id}`);
  for (const id of actual.keys()) if (!expected.has(id)) problems.push(`执行编号未在基线中：${id}`);
  if (!Array.isArray(metadata.sourceFingerprint) || JSON.stringify(sourceFingerprint(root, metadata.selection.preflightPairs.filter((p) => p.disposition !== 'filtered').map((p) => p.file))) !== JSON.stringify(metadata.sourceFingerprint)) problems.push('执行后源码/素材已变化，或本批次没有源码指纹');
  return { eligible: problems.length === 0, problems, cases: expected.size, nativeRunId: report.run.id };
}
