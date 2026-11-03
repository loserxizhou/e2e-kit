export const statuses = {
  passed: '通过', flaky: '重试后通过', failed: '执行失败（原因待诊断）',
  'timed-out': '超时', interrupted: '中断', skipped: '未执行',
};

export function caseId(tags = []) {
  const ids = tags.filter((tag) => typeof tag === 'string' && tag.startsWith('case:'));
  if (ids.length > 1) throw new Error('一条用例只能有一个 case: 编号标签');
  if (!ids.length) return null;
  const id = ids[0].slice(5);
  if (!/^[A-Za-z][A-Za-z0-9_-]{1,79}$/.test(id)) throw new Error('case: 编号须为 2–80 位字母、数字、连字符或下划线，并以字母开头');
  return id;
}

export function infrastructure(result) {
  return result.kind === 'setup' || /^tests\/[^/]+\.e2e\.[cm]?[jt]s$/.test(result.file ?? '');
}

export function attemptsFor(run, result) {
  if (!result.serialGroupId) return result.attempts ?? [];
  const group = (run.serialGroups ?? []).find((entry) => entry.id === result.serialGroupId);
  if (!group) throw new Error('报告缺少用例关联的串行组');
  return group.attempts.flatMap((attempt) => (attempt.members ?? [])
    .filter((member) => member.testId === result.testId)
    .map((member) => ({ ...member, groupAttemptId: attempt.id, groupAttemptIndex: attempt.index })));
}

// 只产生内存视图，原生 report-1 始终是执行事实来源。
export function inspectReport(report, { requireCaseIds = false } = {}) {
  if (report?.schemaVersion !== 'report-1' || !report.run?.id || !Array.isArray(report.run.results)) {
    throw new Error('仅支持具有运行身份的原生 report-1 报告');
  }
  const run = report.run;
  const records = [];
  const warnings = [];
  const identities = new Set();
  const definitions = new Map();
  let unselected = 0;
  for (const result of run.results) {
    if (result.selected === false) { unselected++; continue; }
    if (!Object.hasOwn(statuses, result.status)) throw new Error('报告含未知的用例执行状态');
    const isInfrastructure = infrastructure(result);
    const id = caseId(result.tags);
    if (!isInfrastructure && !id) {
      if (requireCaseIds) throw new Error('正式运行的业务用例缺少 case: 编号标签');
      warnings.push(`旧用例未编号：${result.file} · ${(result.titlePath ?? []).at(-1) ?? result.testId}`);
    }
    if (id && !isInfrastructure) {
      const definition = result.testId ?? JSON.stringify([result.file, result.titlePath]);
      if (definitions.has(id) && definitions.get(id) !== definition) throw new Error('同一业务编号关联了多个测试定义');
      definitions.set(id, definition);
      const key = JSON.stringify([id, result.targetId, result.agent ?? 'default', result.repeat ?? 0]);
      if (identities.has(key)) throw new Error('同一目标、agent 和重复序号中业务编号重复');
      identities.add(key);
    }
    records.push({ id, result, infrastructure: isInfrastructure, attempts: attemptsFor(run, result) });
  }
  return { run, records, warnings, unselected };
}

function cell(value) {
  return String(value ?? '—').replace(/[\r\n]+/g, ' ').replace(/[\\|`\[\]]/g, '\\$&').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

export function renderBusinessSummary(report, options = {}) {
  const view = inspectReport(report, options);
  const business = view.records.filter((record) => !record.infrastructure);
  const setup = view.records.length - business.length;
  const counts = Object.keys(statuses).map((status) => `${statuses[status]} ${business.filter((r) => r.result.status === status).length}`);
  const lines = [
    '# e-office 测试执行摘要', '',
    `原生运行编号：${cell(view.run.id)}。运行状态：${cell(view.run.status)}，原生退出码：${cell(view.run.exitCode)}。`, '',
    `业务执行实例 ${business.length}；已编号业务用例 ${new Set(business.map((r) => r.id).filter(Boolean)).size}；基础设施实例 ${setup}；本轮未选中 ${view.unselected}。`, '',
    counts.join('；') + '。', '',
    '执行失败的原因需结合断言和 trace 诊断；未执行、中断、超时及重试后通过均单独列出，不直接作为产品缺陷或完整验收通过。', '',
    '[原生报告](report.json) · [原生摘要](summary.md)', '',
    '| 编号 | 场景 | 目标 / agent / 重复 | 执行状态 | 尝试次数 | 证据 |',
    '| --- | --- | --- | --- | --- | --- |',
  ];
  if (options.batch) {
    const context = options.batch.context ?? {};
    lines.splice(4, 0, `批次：${cell(options.batch.batchId)}；模式：${cell(options.batch.mode)}；执行人：${cell(context.tester ?? '未填写')}。`, '',
      `被测环境：${cell(context.environment ?? '未知')}；前端部署：${cell(context.frontendVersion ?? '未知')}；后端部署：${cell(context.backendVersion ?? '未知')}；数据批次：${cell(context.dataBatch ?? '未填写')}。`, '',
      '[批次信息](metadata.json)。部署版本未知时，本摘要不能证明某个发布版本已验收通过。', '');
    if (options.batch.caseBaseline) lines.splice(4, 0, '[本轮 Excel 业务定义与审核记录](case-baseline.json)；原文件快照见同批次 case-docs/。归档前另行检查完整覆盖和结果回填。', '');
  }
  for (const record of business) {
    const result = record.result;
    const evidence = record.attempts.flatMap((a) => [...(a.artifacts ?? []), ...(a.steps ?? []).flatMap((s) => s.artifacts ?? [])]);
    // 只引用报告实际提供的路径；缺图、远程视频或无证据均不能猜测本地文件。
    const paths = [...new Set(evidence.map((artifact) => artifact.path).filter((path) =>
      typeof path === 'string' && !/^[a-z]+:/i.test(path) && !path.includes('\\') && path.split('/').every((part) => part && part !== '.' && part !== '..')))];
    // 原生 artifact.path 相对 <output>/results，摘要位于 <output>。
    const links = paths.slice(0, 3).map((path, index) => `[证据${index + 1}](${['results', ...path.split('/')].map((part) => encodeURIComponent(part).replace(/[()]/g, (c) => `%${c.charCodeAt(0).toString(16)}`)).join('/')})`).join(' · ');
    lines.push(`| ${cell(record.id ?? '旧用例未编号')} | ${cell((result.titlePath ?? []).join(' › '))} | ${cell(`${result.targetId} / ${result.agent ?? 'default'} / ${result.repeat ?? 0}`)} | ${statuses[result.status]} | ${record.attempts.length} | ${links || '见原生报告/trace'} |`);
  }
  if (setup) lines.push('', `基础设施单独统计：${setup} 个实例；登录准备失败会影响依赖用例，请同时查看原生报告。`);
  if (view.run.carried) lines.push('', '本轮存在原生复跑的历史关联（run.carried），请结合原报告核对待验证项；不计入本轮通过数。');
  if (view.warnings.length) lines.push('', '兼容提示：', '', ...view.warnings.map((warning) => `- ${cell(warning)}`));
  lines.push('', '本摘要由原生报告转换。业务步骤与机器步骤粒度不同，未采集的逐步结论不得按预期补写。', '');
  return lines.join('\n');
}
