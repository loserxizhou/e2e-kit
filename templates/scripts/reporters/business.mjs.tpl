import { dirname, relative, resolve } from 'node:path';
import { existsSync, readFileSync } from 'node:fs';
import { projectPath, writeAtomic, writeJson } from '../lib/files.mjs';
import { renderBusinessSummary } from '../lib/case-report.mjs';

// 构造不读环境、不写文件；worker 也会加载配置。
export function businessReporter() {
  return {
    name: 'eoffice-business',
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
        const text = renderBusinessSummary(finished.report, { batch: batch?.schemaVersion === 'eoffice-run-1' ? batch : null });
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
