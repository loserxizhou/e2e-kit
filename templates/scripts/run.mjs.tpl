import { spawn, spawnSync } from 'node:child_process';
import { cpSync, existsSync, lstatSync, mkdirSync, readFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { randomUUID } from 'node:crypto';
import { inspectReport } from './lib/case-report.mjs';
import { projectPath, writeAtomic, writeJson } from './lib/files.mjs';
import { parseRunOptions } from './lib/run-options.mjs';
import { baselineOf, checkCaseSelection, prepareCaseDocs, snapshotCaseDocs, sourceFingerprint } from './lib/case-workflow.mjs';

function explanation(error) {
  const message = error instanceof Error ? error.message : '';
  return /^(正式运行|一条用例|同一目标|case:|仅支持|报告|用例|归档|模块|--|项目依赖|原生|无法识别|上一批次|上一批|路径|批次|项目工具|本次执行需要|继续上次批次)/.test(message)
    ? message.slice(0, 240).replace(/[\r\n]/g, ' ') : '请核对本地依赖、选择范围、报告结构和文件权限';
}

// 入口固定使用本项目；导出的工厂仅供核心工具在隔离临时工程中验证真实流程。
export function createBatchRunner(root) {
  const config = join(root, 'e2e.config.ts');

  function cliPath() {
    const project = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
    for (const name of ['e2e', '@e2e-dev/web']) {
      const path = join(root, 'node_modules', name, 'package.json');
      if (!existsSync(path)) throw new Error('项目依赖未安装，请在 e2e 目录执行 npm ci && npm run sync');
      const pkg = JSON.parse(readFileSync(path, 'utf8'));
      if (pkg.version !== project.devDependencies[name]) throw new Error('项目依赖版本不一致，请先 npm ci && npm run sync');
    }
    const pkg = JSON.parse(readFileSync(join(root, 'node_modules/e2e/package.json'), 'utf8'));
    return join(root, 'node_modules/e2e', typeof pkg.bin === 'string' ? pkg.bin : pkg.bin.e2e);
  }

  function json(file) { return JSON.parse(readFileSync(projectPath(root, file), 'utf8')); }

  function select(cli, options, output, env) {
    // 真正运行前只做候选编号检查；变更过滤交给原生 run 执行一次，避免 AI filter 双重调用。
    const selection = options.selection.filter((value, index, all) => options.list || (value !== '--changed-since' && all[index - 1] !== '--changed-since'));
    const args = options.rerun ? [join(dirname(fileURLToPath(import.meta.url)), 'list-selection.mjs')] :
      [cli, 'list', ...options.files, '--config', config, '--reporter', 'json', ...selection];
    const input = options.rerun ? JSON.stringify({ root, config, files: options.files, output: relative(root, output), selection }) : undefined;
    const result = spawnSync(process.execPath, args, { cwd: root, env, input, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
    if (result.stderr) process.stderr.write(result.stderr);
    if (result.error || result.status !== 0) throw new Error('原生用例发现/筛选失败，未启动业务测试；请查看上方诊断');
    let plan;
    try {
      const marker = '\nEOFFICE_SELECTION_JSON:';
      const position = result.stdout.lastIndexOf(marker);
      if (options.rerun && position < 0) throw new Error('MISSING_SELECTION');
      const text = options.rerun ? result.stdout.slice(position + marker.length) : result.stdout;
      plan = JSON.parse(text);
    } catch { throw new Error('原生 list 未返回有效 JSON，未启动业务测试'); }
    if (!Array.isArray(plan.pairs)) throw new Error('无法识别原生选择清单');
    // 原生 list 不展开 --agent/--repeat-each；此处只校验业务编号，不伪造实际实例数量。
    inspectReport({ schemaVersion: 'report-1', run: { id: 'selection', results: plan.pairs.map((pair) => ({
      ...pair, targetId: pair.target, selected: pair.disposition !== 'filtered', status: 'skipped', attempts: [],
    })) } }, { requireCaseIds: options.mode === 'formal' });
    return plan;
  }

  function start(cli, args, env) {
    return new Promise((resolve, reject) => {
      const child = spawn(process.execPath, [cli, ...args], { cwd: root, env, stdio: 'inherit' });
      const interrupt = () => child.kill('SIGINT');
      const terminate = () => child.kill('SIGTERM');
      process.on('SIGINT', interrupt);
      process.on('SIGTERM', terminate);
      const remove = () => { process.off('SIGINT', interrupt); process.off('SIGTERM', terminate); };
      child.once('error', (error) => { remove(); reject(error); });
      child.once('exit', (code, signal) => { remove(); resolve(code ?? (signal === 'SIGTERM' ? 143 : 130)); });
    });
  }

  async function main(argv) {
    const options = parseRunOptions(argv, root);
    if (options.help) {
      console.log('用法：npm run test:run -- [tests/路径 | scratch/具体场景] [--module 模块] [--case-id 编号] [--list] [--intent experience|smoke|formal|resume] [--mode debug|formal] [--rerun 批次编号] [原生筛选/运行参数]');
      console.log('运行信息：--tester 姓名 --env-name 环境标识 --frontend-version 版本 --backend-version 版本 --data-batch 数据批次（不填密码/token）。');
      console.log('含 scratch 或 --case-doc 的执行必须先选择 --intent：experience 体验流程、smoke 冒烟、formal 正式执行、resume 继续上次批次。默认仅回归 tests；debug 兼容未编号旧用例。');
      console.log('--case-doc <xlsx> 可重复指定；先选择执行意图后绑定已审核业务定义和本轮快照。正式执行支持已审核的 scratch 草稿，定稿另做归档检查。');
      return;
    }
    if (!options.list && options.requiresIntent && !options.intent) {
      throw new Error('本次执行需要先选择意图：experience 体验流程、smoke 冒烟验证、formal 正式执行或 resume 继续上次批次；请先向测试人员展示选择。');
    }
    const cli = cliPath();
    const env = { ...process.env, EOFFICE_E2E_INCLUDE_SCRATCH: options.scratch ? '1' : '0', EOFFICE_E2E_INTENT: options.intent ?? '' };
    const runs = projectPath(root, '.e2e/runs');
    let previous = null;
    if (options.rerun) {
      const parent = projectPath(root, runs, options.rerun);
      const manifest = json(join(parent, 'metadata.json'));
      if (manifest.schemaVersion !== 'eoffice-run-1' || manifest.batchId !== options.rerun || manifest.currentReport !== true) throw new Error('上一批次没有可用于原生复跑的已完成报告');
      const report = json(join(parent, 'report.json'));
      inspectReport(report);
      if (manifest.nativeRunId !== report.run.id) throw new Error('上一批次的运行身份与报告不一致，请核对原始产物');
      previous = { parent, nativeRunId: report.run.id };
      if (manifest.caseBaseline) {
        if (!options.modeExplicit && options.intent !== 'experience' && options.intent !== 'smoke') options.mode = manifest.mode;
        const old = baselineOf(root, options.rerun).baseline.documents;
        if (!options.caseDocs.length) options.caseDocs = old.map((doc) => doc.source);
        const current = prepareCaseDocs(root, options.caseDocs);
        if (JSON.stringify(current.map((d) => [d.source, d.designHash]).sort()) !== JSON.stringify(old.map((d) => [d.source, d.designHash]).sort())) throw new Error('用例业务定义已变化，请重新审核并新建运行，不沿用旧失败筛选');
      }
      // 被选入原生复跑的草稿仍需显式指定范围，以免默认导入全部探索。
      if (!options.scratch && report.run.results.some((r) => r.selected !== false && r.file?.startsWith('scratch/'))) throw new Error('上一批包含探索草稿，请同时指定其 scratch 场景路径');
    }
    const documents = options.caseDocs.length || options.mode === 'formal'
      ? prepareCaseDocs(root, options.caseDocs) : [];
    if (options.list) {
      const plan = select(cli, options, previous?.parent, env);
      if (documents.length) checkCaseSelection(plan, documents);
      for (const pair of plan.pairs) console.log(`${pair.disposition} · ${pair.file} · ${pair.title} · ${(pair.tags ?? []).join(' ')} · ${pair.target}/${pair.agent}`);
      console.log(`[e2e] 选择预览 ${plan.pairs.length} 个原生配对；未启动浏览器，未新建运行批次。`);
      return;
    }
    mkdirSync(runs, { recursive: true, mode: 0o700 });
    const batchId = `${new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '')}-${randomUUID()}`;
    const output = projectPath(root, runs, batchId);
    mkdirSync(output, { mode: 0o700 });
    const metadata = { schemaVersion: 'eoffice-run-1', batchId, startedAt: new Date().toISOString(), mode: options.mode, intent: options.intent,
      parentBatchId: options.rerun, context: options.context, selection: { files: options.files, native: options.native },
      phase: 'selection', currentReport: false, runnerExitCode: null, delivery: 'pending' };
    const save = () => writeJson(root, join(output, 'metadata.json'), metadata);
    save();
    const intentLabel = { experience: '体验流程', smoke: '冒烟验证', formal: '正式执行', resume: '继续上次批次' }[options.intent] ?? '兼容诊断';
    console.log(`[e2e] 执行意图：${intentLabel}`);
    console.log(`[e2e] 本轮批次：${batchId}`);
    try {
      if (documents.length) {
        snapshotCaseDocs(root, output, documents);
        metadata.caseBaseline = 'case-baseline.json';
      }
      if (previous) {
        // 给新输出目录提供原生 last-failed 的输入及关联证据；原批次保持不变。
        for (const name of ['report.json', 'results']) {
          const source = projectPath(root, previous.parent, name);
          if (existsSync(source)) cpSync(source, join(output, name), { recursive: true, filter: (path) => {
            projectPath(root, path);
            if (lstatSync(path).isSymbolicLink()) throw new Error('拒绝复制软链接制品');
            return true;
          } });
        }
        writeJson(root, join(output, 'previous-report.json'), json(join(previous.parent, 'report.json')));
      }
      const plan = select(cli, options, output, env);
      if (documents.length) checkCaseSelection(plan, documents);
      metadata.selection.preflightPairs = plan.pairs.map(({ id, file, tags, target, agent, disposition }) => ({ id, file, tags, target, agent, disposition }));
      metadata.sourceFingerprint = sourceFingerprint(root, plan.pairs.filter((p) => p.disposition !== 'filtered').map((p) => p.file));
      metadata.phase = 'running';
      save();
      const args = ['run', ...options.files, '--config', config, '--output', relative(root, output), '--reporter', 'list,markdown,junit', '--retries', '0', ...options.native];
      if (previous) args.push('--last-failed');
      const code = await start(cli, args, env);
      metadata.runnerExitCode = code;
      metadata.phase = 'finished';
      const reportFile = join(output, 'report.json');
      if (existsSync(reportFile)) {
        const report = json(reportFile);
        if (report.run?.id !== previous?.nativeRunId) {
          inspectReport(report, { requireCaseIds: options.mode === 'formal' });
          if (documents.length) checkCaseSelection({ pairs: report.run.results.map((r) => ({ ...r, disposition: r.selected === false ? 'filtered' : 'run' })) }, documents);
          metadata.currentReport = true;
          metadata.nativeRunId = report.run.id;
          const delivery = json(join(output, 'business-delivery.json'));
          metadata.delivery = delivery.schemaVersion === 'eoffice-delivery-1' && delivery.nativeRunId === report.run.id && delivery.status === 'complete'
            && ['业务摘要.md', 'summary.md', 'junit.xml'].every((name) => {
              const path = projectPath(root, output, name);
              return existsSync(path) && lstatSync(path).isFile();
            }) ? 'complete' : 'failed';
        }
      }
      if (!metadata.currentReport) metadata.delivery = 'failed';
      // 导出失败不覆盖原生失败码；原生成功但交付失败时返回单独的 5。
      process.exitCode = code || (metadata.delivery === 'complete' ? 0 : 5);
    } catch (error) {
      metadata.failureCode = metadata.phase === 'selection' ? 'SELECTION_FAILED' : 'RUN_OR_DELIVERY_FAILED';
      metadata.phase = 'incomplete';
      metadata.delivery = 'failed';
      metadata.explanation = explanation(error);
      process.exitCode = metadata.runnerExitCode || (metadata.failureCode === 'SELECTION_FAILED' ? 2 : 5);
      console.error(`[e2e] ${metadata.explanation}。本轮未完成，请结合原生诊断和 metadata.json 核查。`);
    } finally {
      metadata.finishedAt = new Date().toISOString();
      save();
      if (!metadata.currentReport) writeAtomic(root, join(output, '未完成说明.md'), '# 本轮未完成\n\n未取得可确认属于本轮的新报告。复跑时复制的上一批 report 仅作选择输入，不是本次结果。请查看 metadata.json 与终端原生诊断；不得据此填写通过。\n');
      console.log(`[e2e] 本轮交付：${metadata.delivery}；记录：${relative(root, join(output, 'metadata.json'))}`);
    }
  }

  return main;
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) createBatchRunner(dirname(dirname(fileURLToPath(import.meta.url))))(process.argv.slice(2)).catch((error) => {
  console.error(`[e2e] ${explanation(error)}；可先执行 npm run test:run -- --help 核对用法。未启动业务测试。`);
  process.exitCode = 2;
});
