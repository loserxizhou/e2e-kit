import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const KIT_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const CLI = join(KIT_ROOT, 'bin', 'e2e-kit.mjs');

function makeProject() {
  return mkdtempSync(join(tmpdir(), 'e2e-kit-upgrade-'));
}

function run(command, project, args = []) {
  const res = spawnSync(
    process.execPath,
    [CLI, command, '--project', project, '--yes', '--no-install', '--no-smoke', '--json', ...args],
    { encoding: 'utf8' },
  );
  let json = null;
  try {
    json = JSON.parse(res.stdout);
  } catch {
    json = null;
  }
  return { res, json, stdout: res.stdout, stderr: res.stderr };
}

function seed(project) {
  const seeded = run('init', project, ['--url', 'http://localhost:4200/', '--user', 'admin']);
  assert.equal(seeded.res.status, 0, seeded.stderr);
  return seeded;
}

test('upgrade 幂等：init 后立即升级，全部已最新、零写入', () => {
  const project = makeProject();
  seed(project);

  const upgraded = run('upgrade', project);
  assert.equal(upgraded.res.status, 0, upgraded.stderr);
  assert.deepEqual(upgraded.json.created, []);
  assert.deepEqual(upgraded.json.updated, []);
  assert.equal(upgraded.json.unchanged.length, 41, '41 个框架文件应全部已最新');
  assert.deepEqual(upgraded.json.skipped, []);
});

test('upgrade 保护手改文件：用户改过的框架文件跳过，其余刷新', () => {
  const project = makeProject();
  seed(project);

  // 手改一个框架文件 → 应跳过
  const modifiedRel = 'e2e/docs/运行与结果管理.md';
  writeFileSync(join(project, modifiedRel), '# 用户手改版\n');

  // 缺失一个框架文件 → 应补建
  rmSync(join(project, 'e2e', 'templates', '用例初稿示例.json'));

  // 用户资产：业务用例、草稿、.env
  mkdirSync(join(project, 'e2e', 'tests', '业务模块'), { recursive: true });
  writeFileSync(join(project, 'e2e', 'tests', '业务模块', '业务.e2e.ts'), '// 业务用例\n');
  mkdirSync(join(project, 'e2e', 'scratch'), { recursive: true });
  writeFileSync(join(project, 'e2e', 'scratch', '草稿.e2e.ts'), '// 草稿\n');
  const envBefore = readFileSync(join(project, 'e2e', '.env'), 'utf8');

  const upgraded = run('upgrade', project);
  assert.equal(upgraded.res.status, 0, upgraded.stderr);
  assert.deepEqual(upgraded.json.created, ['e2e/templates/用例初稿示例.json'], '缺失文件应补建');
  const skipped = upgraded.json.skipped.find((s) => s.path === modifiedRel);
  assert.ok(skipped, '手改文件应出现在 skipped');
  assert.match(skipped.reason, /用户已修改/);
  assert.equal(readFileSync(join(project, modifiedRel), 'utf8'), '# 用户手改版\n', '手改内容保持原样');
  assert.equal(readFileSync(join(project, 'e2e', '.env'), 'utf8'), envBefore, '.env 永不触碰');
  assert.equal(readFileSync(join(project, 'e2e', 'tests', '业务模块', '业务.e2e.ts'), 'utf8'), '// 业务用例\n', '业务用例不触碰');
  assert.equal(readFileSync(join(project, 'e2e', 'scratch', '草稿.e2e.ts'), 'utf8'), '// 草稿\n', '草稿不触碰');
});

test('upgrade 刷新未手改文件：模板变化后，未手改文件更新为新版并更新记录', () => {
  const project = makeProject();
  seed(project);

  // 临时修改 kit 模板模拟新版本，测试后还原
  const tplPath = join(KIT_ROOT, 'templates', 'docs', '初稿生成入口.md.tpl');
  const tplBackup = readFileSync(tplPath, 'utf8');
  try {
    writeFileSync(tplPath, `${tplBackup}\n<!-- vNEW 升级标记 -->\n`);
    const upgraded = run('upgrade', project);
    assert.equal(upgraded.res.status, 0, upgraded.stderr);
    assert.ok(upgraded.json.updated.includes('e2e/docs/初稿生成入口.md'), '未手改文件应刷新');
    const refreshed = readFileSync(join(project, 'e2e', 'docs', '初稿生成入口.md'), 'utf8');
    assert.match(refreshed, /vNEW 升级标记/);

    // 再次升级：新记录已更新 → 已最新
    const again = run('upgrade', project);
    assert.deepEqual(again.json.updated, []);
    assert.ok(again.json.unchanged.includes('e2e/docs/初稿生成入口.md'));
  } finally {
    writeFileSync(tplPath, tplBackup);
  }
});

test('upgrade dry-run：只打印计划，不写文件', () => {
  const project = makeProject();
  seed(project);
  rmSync(join(project, 'e2e', 'docs', '版本与变更记录.md'));

  const dry = run('upgrade', project, ['--dry-run']);
  assert.equal(dry.res.status, 0, dry.stderr);
  assert.deepEqual(dry.json.created, ['e2e/docs/版本与变更记录.md']);
  assert.ok(!existsSync(join(project, 'e2e', 'docs', '版本与变更记录.md')), 'dry-run 不应写文件');
});

test('upgrade 对旧版变量名给出迁移提示', () => {
  const project = makeProject();
  seed(project);
  writeFileSync(
    join(project, 'e2e', '.env'),
    'APP_URL=http://192.0.2.10:8010/app/\nE2E_USER=admin\nE2E_PASSWORD=secret\n',
  );

  const upgraded = run('upgrade', project);
  assert.equal(upgraded.res.status, 0, upgraded.stderr);
  assert.ok(
    upgraded.json.warnings.some((w) => w.includes('EOFFICE_ADMIN_USER') && w.includes('E2E_USER')),
    '应提示变量名映射，且不修改 .env',
  );
  assert.match(readFileSync(join(project, 'e2e', '.env'), 'utf8'), /E2E_USER=admin/);
});

test('upgrade 未初始化项目：明确报错，不写任何文件', () => {
  const project = makeProject();
  const { res, stderr } = run('upgrade', project);
  assert.equal(res.status, 4);
  assert.match(stderr, /先运行 e2e-kit init/);
  assert.ok(!existsSync(join(project, '.e2e-kit.json')));
});

test('upgrade 迁移模式：safe 保护旧框架与 Skill，adopt 明确接管两者', () => {
  const project = makeProject();
  const seeded = run('init', project, ['--url', 'http://localhost:4200/', '--user', 'admin', '--client', 'codex']);
  assert.equal(seeded.res.status, 0, seeded.stderr);
  const skill = join(project, '.agents', 'skills', 'e2e-kit', 'SKILL.md');
  writeFileSync(skill, `${readFileSync(skill, 'utf8')}\n用户定制\n`);
  writeFileSync(join(project, 'e2e', 'docs', '运行与结果管理.md'), '# 旧版手改\n');

  const safe = run('upgrade', project, ['--migration', 'safe']);
  assert.equal(safe.res.status, 0, safe.stderr);
  assert.equal(safe.json.migration, 'safe');
  assert.match(readFileSync(skill, 'utf8'), /用户定制/);
  assert.equal(readFileSync(join(project, 'e2e', 'docs', '运行与结果管理.md'), 'utf8'), '# 旧版手改\n');
  assert.ok(safe.json.skills.some((item) => item.skipped.some((path) => path.includes('用户已修改'))));

  const adopted = run('upgrade', project, ['--migration', 'adopt']);
  assert.equal(adopted.res.status, 0, adopted.stderr);
  assert.equal(adopted.json.migration, 'adopt');
  assert.doesNotMatch(readFileSync(skill, 'utf8'), /用户定制/);
  assert.notEqual(readFileSync(join(project, 'e2e', 'docs', '运行与结果管理.md'), 'utf8'), '# 旧版手改\n');
});

test('upgrade 旧项目：safe 保留来源不明文件，adopt 才接管', () => {
  const project = makeProject();
  mkdirSync(join(project, 'e2e'), { recursive: true });
  writeFileSync(join(project, 'e2e', 'e2e.config.ts'), 'export default { legacy: true };\n');

  const safe = run('upgrade', project, ['--migration', 'safe']);
  assert.equal(safe.res.status, 0, safe.stderr);
  assert.match(readFileSync(join(project, 'e2e', 'e2e.config.ts'), 'utf8'), /legacy/);
  assert.ok(safe.json.skipped.some((item) => item.path === 'e2e/e2e.config.ts'));
  assert.ok(safe.json.modified.includes('.gitignore'));
  assert.ok(safe.json.modified.includes('AGENTS.md'));
  assert.match(readFileSync(join(project, 'AGENTS.md'), 'utf8'), /e2e-kit:route:begin/);

  const adopted = run('upgrade', project, ['--migration', 'adopt']);
  assert.equal(adopted.res.status, 0, adopted.stderr);
  assert.doesNotMatch(readFileSync(join(project, 'e2e', 'e2e.config.ts'), 'utf8'), /legacy/);
  assert.ok(adopted.json.adopted.includes('e2e/e2e.config.ts'));
});
