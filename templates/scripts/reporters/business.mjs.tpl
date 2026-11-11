import { dirname, relative, resolve } from 'node:path';
import { existsSync, readFileSync } from 'node:fs';
import { projectPath, writeAtomic, writeJson } from '../lib/files.mjs';
import { businessResultKey, renderBusinessSummary } from '../lib/case-report.mjs';

// Kept in sync with helpers/business-evidence.ts. The reporter is plain Node
// ESM and must remain loadable before TypeScript is compiled by the runner.
const BUSINESS_STEP_MARKER = '[E2E_BUSINESS_STEP]';

function collectBusinessStepEvents(stepEvents, outputBuffers, event) {
  if (event?.type !== 'output' || event.stream !== 'stdout' || !event.pair || typeof event.text !== 'string') return;
  const key = businessResultKey({ ...event.pair, targetId: event.target });
  const text = `${outputBuffers.get(key) ?? ''}${event.text}`;
  const lines = text.split(/\r?\n/);
  const tail = lines.pop() ?? '';
  if (!tail || tail.length > 8192) outputBuffers.delete(key);
  else outputBuffers.set(key, tail);
  for (const line of lines) {
    if (!line.startsWith(BUSINESS_STEP_MARKER) || line.length > 8192) continue;
    const raw = line.slice(BUSINESS_STEP_MARKER.length);
    try {
      const payload = JSON.parse(raw);
      if (!payload || payload.schemaVersion !== 'business-step-1' ||
          !['start', 'finish'].includes(payload.phase) || typeof payload.stepId !== 'string' ||
          typeof payload.eventId !== 'string' || typeof payload.startedAt !== 'string' ||
          typeof payload.action !== 'string' || typeof payload.expected !== 'string' ||
          (payload.phase === 'finish' && !['passed', 'failed'].includes(payload.status))) continue;
      const list = stepEvents.get(key) ?? [];
      list.push(payload);
      stepEvents.set(key, list);
    } catch {
      // Ignore a malformed line while continuing to collect later markers.
    }
  }
}

// 构造不读环境、不写文件；worker 也会加载配置。
export function businessReporter() {
  const stepEvents = new Map();
  const outputBuffers = new Map();
  return {
    name: 'eoffice-business',
    onEvent(event) {
      if (event.type === 'run-started') {
        stepEvents.clear();
        outputBuffers.clear();
      } else {
        collectBusinessStepEvents(stepEvents, outputBuffers, event);
      }
    },
    async onRunFinished(finished, signal) {
      if (!finished.reportPath) throw new Error('原生报告未写入，无法生成业务摘要');
      const root = resolve(finished.projectRoot);
      const output = dirname(projectPath(root, finished.reportPath));
      const delivery = projectPath(root, output, 'business-delivery.json');
      try {
        if (signal.aborted) throw new Error('报告生成已中断');
        const summary = projectPath(root, output, '业务摘要.md');
        const metadataFile = projectPath(root, output, 'metadata.json');
        const batch = existsSync(metadataFile) ? JSON.parse(readFileSync(metadataFile, 'utf8')) : null;
        const text = renderBusinessSummary(finished.report, {
          batch: batch?.schemaVersion === 'eoffice-run-1' ? batch : null,
          businessSteps: stepEvents,
          outputRoot: output,
          artifactsRoot: finished.artifactsRoot,
          tracePaths: finished.traces,
          projectRoot: root,
        });
        writeAtomic(root, summary, text);
        writeJson(root, delivery, { schemaVersion: 'eoffice-delivery-1', nativeRunId: finished.report.run.id, status: 'complete', summary: '业务摘要.md' });
        return [{ label: '业务摘要', text: relative(root, summary) }];
      } catch (error) {
        // 不复制异常中的潜在业务/敏感原文。原生报告保留，交付异常单独记录。
        writeJson(root, delivery, { schemaVersion: 'eoffice-delivery-1', nativeRunId: finished.report.run.id, status: 'failed', code: 'BUSINESS_SUMMARY_FAILED' });
        throw error;
      }
    },
  };
}
