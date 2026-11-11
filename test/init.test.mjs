import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { locateProject, LocateError } from '../bin/lib/locate.mjs';

const CLI = join(dirname(fileURLToPath(import.meta.url)), '..', 'bin', 'e2e-kit.mjs');

function makeProject() {
  return mkdtempSync(join(tmpdir(), 'e2e-kit-'));
}

function init(project, args = []) {
  const res = spawnSync(
    process.execPath,
    [CLI, 'init', '--project', project, '--yes', '--no-install', '--no-smoke', '--json', ...args],
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

test('fresh init: 生成骨架、.env 权限 0600、二次运行零写入', () => {
  const project = makeProject();
  writeFileSync(join(project, 'package.json'), '{"name":"fixture"}\n');

  const first = init(project, ['--url', 'http://localhost:4200', '--user', 'admin', '--password', 'secret']);
  assert.equal(first.res.status, 0, first.stderr);
  assert.equal(first.json.mode, 'fresh');
  assert.ok(existsSync(join(project, 'e2e', 'e2e.config.ts')));
  assert.ok(existsSync(join(project, 'e2e', 'tests', 'login.e2e.ts')));
  assert.ok(existsSync(join(project, 'e2e', 'tests', 'auth.setup.e2e.ts')));
  assert.ok(existsSync(join(project, 'e2e', 'helpers', 'business-evidence.ts')));
  assert.ok(existsSync(join(project, 'e2e', 'tsconfig.json')), '应生成 tsconfig');
  assert.ok(existsSync(join(project, 'e2e', 'scripts', 'forward-test-env.mjs')), '应生成内网转发脚本');
  assert.ok(existsSync(join(project, 'e2e', 'scripts', 'check-case-doc.py')), '应用例文档自检脚本');
  assert.ok(existsSync(join(project, 'e2e', 'templates', '写测试.md')), '应生成写测试流程模板');
  assert.ok(existsSync(join(project, 'e2e', 'templates', '测试用例文档格式.md')), '应生成用例文档格式标准');
  assert.ok(existsSync(join(project, 'e2e', 'docs', '怎么指挥AI跑测试.md')), '应生成测试人员指令手册（docs/）');
  assert.ok(existsSync(join(project, 'e2e', 'docs', 'Excel用例工作流.md')), '应生成工作流文档');
  assert.ok(existsSync(join(project, 'e2e', 'scripts', 'run.mjs')), '应生成批次运行入口');
  assert.ok(existsSync(join(project, 'e2e', 'scripts', 'cases.mjs')), '应用例文档工作流入口');
  assert.ok(existsSync(join(project, 'e2e', 'templates', '用例初稿示例.json')), '应生成初稿示例');
  assert.ok(existsSync(join(project, 'e2e', 'package-lock.json')), '应生成锁文件');
  assert.equal(first.json.created.length, 43, '应生成 42 个框架文件 + .env');
  assert.ok(!existsSync(join(project, 'e2e', 'knowledge')), '团队知识库不应随 kit 生成');
  const pkg = JSON.parse(readFileSync(join(project, 'e2e', 'package.json'), 'utf8'));
  assert.ok(pkg.scripts.forward, 'package.json 应带 forward 脚本');
  assert.ok(existsSync(join(project, '.e2e-kit.json')), '标记文件应在仓库根');
  assert.ok(!existsSync(join(project, 'e2e', '.e2e-kit.json')), '标记文件不应落进 e2e 目录');

  const envPath = join(project, 'e2e', '.env');
  const env = readFileSync(envPath, 'utf8');
  assert.match(env, /APP_URL=http:\/\/localhost:4200\//); // 自动补尾斜杠
  assert.match(env, /EOFFICE_ADMIN_PASSWORD=secret/);
  assert.match(env, /EOFFICE_ADMIN_USER=admin/);
  assert.equal(statSync(envPath).mode & 0o777, 0o600);

  const gitignore = readFileSync(join(project, '.gitignore'), 'utf8');
  assert.equal(gitignore.split(/\r?\n/).filter((line) => line.trim() === '.env').length, 1);
  assert.equal(gitignore.split(/\r?\n/).filter((line) => line.trim() === '.e2e*/').length, 1);

  const second = init(project);
  assert.equal(second.res.status, 0, second.stderr);
  assert.equal(second.json.mode, 'existing');
  assert.deepEqual(second.json.created, [], '二次运行不应创建任何文件');
  assert.deepEqual(second.json.modified, [], '二次运行不应写任何文件');
  assert.equal(readFileSync(envPath, 'utf8'), env, '.env 不应被改动');

  const agents = readFileSync(join(project, 'AGENTS.md'), 'utf8');
  assert.equal(agents.split('e2e-kit:route:begin').length - 1, 1, 'AGENTS.md 路由块只出现一次');
});

test('已有 e2e 配置：进入体检模式，不覆盖用户配置', () => {
  const project = makeProject();
  mkdirSync(join(project, 'e2e'), { recursive: true });
  writeFileSync(join(project, 'e2e', 'e2e.config.ts'), '// 用户自己的配置\n');

  const { res, json } = init(project, ['--url', 'http://localhost:4200/', '--user', 'admin']);
  assert.equal(res.status, 0, res.stderr);
  assert.equal(json.mode, 'existing');
  assert.equal(readFileSync(join(project, 'e2e', 'e2e.config.ts'), 'utf8'), '// 用户自己的配置\n');
  assert.ok(!json.created.includes('e2e/e2e.config.ts'));
});

test('已有 Playwright：共存模式，仍生成 e2e 骨架且不改动原框架配置', () => {
  const project = makeProject();
  writeFileSync(join(project, 'playwright.config.ts'), 'export default {};\n');

  const { res, json } = init(project, ['--url', 'http://localhost:4200/', '--user', 'admin']);
  assert.equal(res.status, 0, res.stderr);
  assert.equal(json.mode, 'coexist');
  assert.ok(existsSync(join(project, 'e2e', 'e2e.config.ts')));
  assert.equal(readFileSync(join(project, 'playwright.config.ts'), 'utf8'), 'export default {};\n');
});

test('目录冲突：目标目录含非 e2e 内容时硬停，不写任何文件', () => {
  const project = makeProject();
  mkdirSync(join(project, 'e2e'), { recursive: true });
  writeFileSync(join(project, 'e2e', 'foo.spec.ts'), '// 别人的用例\n');

  const { res, stderr } = init(project, ['--url', 'http://localhost:4200/']);
  assert.equal(res.status, 4);
  assert.match(stderr, /目标目录已存在/);
  assert.ok(!existsSync(join(project, 'e2e', 'package.json')));
  assert.ok(!existsSync(join(project, '.e2e-kit.json')));
});

test('定位：同一目录两份配置报 CONFIG_AMBIGUOUS', () => {
  const project = makeProject();
  writeFileSync(join(project, 'e2e.config.ts'), '// a\n');
  writeFileSync(join(project, 'e2e.config.mts'), '// b\n');

  assert.throws(
    () => locateProject({ startDir: project }),
    (err) => err instanceof LocateError && err.code === 'CONFIG_AMBIGUOUS',
  );
});

test('定位：优先使用 .e2e-kit.json 记录的路径（支持非标准布局）', () => {
  const project = makeProject();
  mkdirSync(join(project, 'test', 'e2e'), { recursive: true });
  writeFileSync(join(project, 'test', 'e2e', 'e2e.config.ts'), '// custom\n');
  writeFileSync(
    join(project, '.e2e-kit.json'),
    JSON.stringify({ version: 1, dir: 'test/e2e', config: 'test/e2e/e2e.config.ts' }),
  );

  const located = locateProject({ startDir: join(project, 'test') });
  assert.equal(located.method, 'marker:.e2e-kit.json');
  assert.equal(located.config, join(project, 'test', 'e2e', 'e2e.config.ts'));
});

test('定位：E2E_PROJECT 指定起点，向上查找到配置', () => {
  const project = makeProject();
  mkdirSync(join(project, 'e2e'), { recursive: true });
  writeFileSync(join(project, 'e2e', 'e2e.config.ts'), '// x\n');
  mkdirSync(join(project, 'src', 'deep'), { recursive: true });

  const located = locateProject({ project: join(project, 'src', 'deep') });
  assert.equal(located.config, join(project, 'e2e', 'e2e.config.ts'));
});

test('重复 init 保留 clients 记录，不被空参数清空', () => {
  const project = makeProject();
  const first = init(project, ['--url', 'http://localhost:4200/', '--user', 'admin', '--client', 'workbuddy,dsh']);
  assert.equal(first.res.status, 0, first.stderr);

  const second = init(project);
  assert.equal(second.res.status, 0, second.stderr);
  const marker = JSON.parse(readFileSync(join(project, '.e2e-kit.json'), 'utf8'));
  assert.deepEqual(marker.clients, ['workbuddy', 'dsh']);
  assert.deepEqual(second.json.created, []);
});

test('doctor：全新项目体检通过，定位到仓库根而非 e2e 目录', () => {
  const project = makeProject();
  writeFileSync(join(project, 'package.json'), '{"name":"fixture"}\n');
  const seeded = init(project, ['--url', 'http://localhost:4200/', '--user', 'admin']);
  assert.equal(seeded.res.status, 0, seeded.stderr);

  const res = spawnSync(process.execPath, [CLI, 'doctor', '--project', project, '--json'], { encoding: 'utf8' });
  assert.equal(res.status, 0, res.stderr);
  const report = JSON.parse(res.stdout);
  assert.equal(report.ok, true);
  const markerCheck = report.checks.find((c) => c.name === '绑定标记');
  assert.equal(markerCheck.level, 'ok');
  const ignoreCheck = report.checks.find((c) => c.name === '.gitignore');
  assert.equal(ignoreCheck.level, 'ok');
  const aiCheck = report.checks.find((c) => c.name === 'AI 模型');
  assert.equal(aiCheck.level, 'warn', '未配 AI key 时体检应给出 warn 提示');
  assert.match(aiCheck.detail, /自动跳过/);
});

test('已有 .env（旧变量名 EOFFICE_ADMIN_*）：非交互重跑不需要再传账号', () => {
  const project = makeProject();
  mkdirSync(join(project, 'e2e'), { recursive: true });
  writeFileSync(join(project, 'e2e', 'e2e.config.ts'), '// legacy\n');
  writeFileSync(
    join(project, 'e2e', '.env'),
    'APP_URL=http://192.0.2.10:8010/app/\nEOFFICE_ADMIN_USER=admin\nEOFFICE_ADMIN_PASSWORD=secret\n',
  );

  const { res, json } = init(project);
  assert.equal(res.status, 0, res.stderr);
  assert.equal(json.mode, 'existing');
  assert.ok(!json.created.includes('e2e/e2e.config.ts'), '用户配置不能被重建');
  assert.ok(!json.created.includes('e2e/.env'), '.env 不能被重建');
  assert.equal(readFileSync(join(project, 'e2e', '.env'), 'utf8').includes('EOFFICE_ADMIN_PASSWORD=secret'), true);
});

test('init 对 AI 模型配置给出状态化提示（未配 key 警告跳过，配了则确认可用）', () => {
  const bare = makeProject();
  const bareInit = init(bare, ['--url', 'http://localhost:4200/', '--user', 'admin']);
  assert.equal(bareInit.res.status, 0, bareInit.res.stderr);
  assert.ok(
    bareInit.json.manualSteps.some((s) => s.includes('AI 模型未配置') && s.includes('自动跳过')),
    '未传 --api-key 时应显式提示 agent 用例会跳过',
  );

  const withKey = makeProject();
  const keyInit = init(withKey, ['--url', 'http://localhost:4200/', '--user', 'admin', '--api-key', 'sk-test']);
  assert.equal(keyInit.res.status, 0, keyInit.res.stderr);
  assert.ok(keyInit.json.manualSteps.some((s) => s.includes('AI 模型已配置')));
  const doctor = spawnSync(process.execPath, [CLI, 'doctor', '--project', withKey, '--json'], { encoding: 'utf8' });
  const aiCheck = JSON.parse(doctor.stdout).checks.find((c) => c.name === 'AI 模型');
  assert.equal(aiCheck.level, 'ok', '配置了 key 后体检应为 ok');
});

test('init --client codex：一条命令同时完成客户端接入与项目初始化', () => {
  const project = makeProject();
  const { res, json } = init(project, [
    '--url', 'http://localhost:4200/',
    '--user', 'admin',
    '--client', 'codex',
  ]);
  assert.equal(res.status, 0, res.stderr);
  assert.ok(existsSync(join(project, '.codex', 'config.toml')), '应写入 Codex MCP 配置');
  assert.ok(existsSync(join(project, '.agents', 'skills', 'e2e-kit', 'SKILL.md')), '应安装 skill');
  assert.equal(json.clientInstall[0].client, 'codex');
  assert.ok(json.clientInstall[0].files.length >= 2);
});

test('init --client claude：写入 .mcp.json（mcpServers 包裹）与项目级 skill', () => {
  const project = makeProject();
  const { res } = init(project, [
    '--url', 'http://localhost:4200/',
    '--user', 'admin',
    '--client', 'claude',
  ]);
  assert.equal(res.status, 0, res.stderr);
  const mcp = JSON.parse(readFileSync(join(project, '.mcp.json'), 'utf8'));
  assert.equal(mcp.mcpServers.e2e.command, process.execPath);
  assert.ok(mcp.mcpServers.e2e.args.includes('--project'));
  assert.ok(existsSync(join(project, '.claude', 'skills', 'e2e-kit', 'SKILL.md')));
});

test('init 迁移 codex 配置里失效的旧 kit 条目（shared 布局残留 / 裸 node）', () => {
  const project = makeProject();
  mkdirSync(join(project, '.codex'), { recursive: true });
  writeFileSync(
    join(project, '.codex', 'config.toml'),
    [
      '# e2e-kit:begin（由 e2e-kit 生成；删除本段即可移除）',
      '[mcp_servers.e2e]',
      'command = "node"',
      `args = ["/nonexistent/shared/bin/e2e-mcp.mjs", "--project", ${JSON.stringify(project)}]`,
      '# e2e-kit:end',
      '',
    ].join('\n'),
  );

  const { res } = init(project, ['--url', 'http://localhost:4200/', '--user', 'admin', '--client', 'codex']);
  assert.equal(res.status, 0, res.stderr);
  const toml = readFileSync(join(project, '.codex', 'config.toml'), 'utf8');
  assert.ok(!toml.includes('/shared/bin/'), '失效的 shared 路径应被迁移掉');
  assert.ok(!toml.includes('command = "node"'), '裸 node 应替换为绝对路径');
  assert.ok(toml.includes(`command = ${JSON.stringify(process.execPath)}`));
  assert.match(toml, /args = \["[^"]*bin\/e2e-mcp\.mjs"/);
  assert.ok(toml.includes('# e2e-kit:begin'), '标记块应保留');
});

test('init 迁移 .mcp.json 中失效的 kit 条目，不动 npx 风格条目', () => {
  const staleProject = makeProject();
  writeFileSync(
    join(staleProject, '.mcp.json'),
    JSON.stringify(
      { mcpServers: { e2e: { command: 'node', args: ['/nonexistent/shared/bin/e2e-mcp.mjs', '--project', staleProject] } } },
      null,
      2,
    ),
  );
  const stale = init(staleProject, ['--url', 'http://localhost:4200/', '--user', 'admin', '--client', 'claude']);
  assert.equal(stale.res.status, 0, stale.res.stderr);
  const migrated = JSON.parse(readFileSync(join(staleProject, '.mcp.json'), 'utf8'));
  assert.equal(migrated.mcpServers.e2e.command, process.execPath);
  assert.ok(migrated.mcpServers.e2e.args[0].endsWith('bin/e2e-mcp.mjs'));

  const npxProject = makeProject();
  writeFileSync(
    join(npxProject, '.mcp.json'),
    JSON.stringify(
      { mcpServers: { e2e: { command: 'npx', args: ['e2e@0.22.0', 'mcp', '--config', 'e2e/e2e.config.ts'] } } },
      null,
      2,
    ),
  );
  const kept = init(npxProject, ['--url', 'http://localhost:4200/', '--user', 'admin', '--client', 'claude']);
  assert.equal(kept.res.status, 0, kept.res.stderr);
  const untouched = JSON.parse(readFileSync(join(npxProject, '.mcp.json'), 'utf8'));
  assert.equal(untouched.mcpServers.e2e.command, 'npx', '非 kit 生成的 npx 条目不应被动');
});
