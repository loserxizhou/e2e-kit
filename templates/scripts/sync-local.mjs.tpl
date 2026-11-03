// npm ci 后执行：刷新官方 Skill、迁移项目级 MCP 配置、安装匹配的浏览器。
// 不读取 .env、不运行测试、不写用户级配置，也不覆盖 e2e-kit Skill。
import { spawnSync } from 'node:child_process';
import { existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, realpathSync, writeFileSync } from 'node:fs';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const dir = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const root = dirname(dir);
const launcher = join(dir, 'scripts/mcp.mjs');
const entry = { command: process.execPath, args: [launcher] };
const clients = {
  codex: '.codex/config.toml',
  claude: '.mcp.json',
  cursor: '.cursor/mcp.json',
};

function parseJson(text, label) {
  try { return JSON.parse(text); }
  catch { throw new Error(`${label} 不是有效 JSON，请先修复该文件`); }
}

function samePath(left, right) {
  if (typeof left !== 'string') return false;
  try { return realpathSync(left) === realpathSync(right); }
  catch { return resolve(left) === resolve(right); }
}

function safePath(file) {
  const rel = relative(root, file);
  if (isAbsolute(rel) || rel === '..' || rel.startsWith(`..${sep}`)) throw new Error('目标路径超出项目');
  let current = root;
  for (const part of rel.split(sep)) {
    current = join(current, part);
    try {
      if (lstatSync(current).isSymbolicLink()) throw new Error(`拒绝通过软链接写入：${relative(root, current)}`);
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
  }
}

// 仅覆盖官方 Skill 中的文件，保留目标目录中的额外自定义文件。
function planSkill(source, target, writes) {
  safePath(target);
  for (const item of readdirSync(source, { withFileTypes: true })) {
    const dest = join(target, item.name);
    if (item.isDirectory()) planSkill(join(source, item.name), dest, writes);
    else if (item.isFile()) writes.set(dest, readFileSync(join(source, item.name)));
    else throw new Error('官方 Skill 包含非普通文件，停止同步');
  }
}

function migrate(previous) {
  if (!previous) return entry;
  const args = previous.args;
  if (!Array.isArray(args) || !args.every((arg) => typeof arg === 'string')) throw new Error('e2e MCP 的 args 不是字符串数组');
  const npxArgs = args.filter((arg, index) => index !== 0 || !['-y', '--yes'].includes(arg));
  let extra;
  if (samePath(args[0], launcher)) extra = args.slice(1);
  else if (/(?:^|[\\/])(?:\.e2e-kit|e2e-kit)[\\/]bin[\\/]e2e-mcp\.mjs$/.test(args[0] ?? '')) {
    extra = args.slice(1);
  } else if (/^e2e(?:@[^/]+)?$/.test(npxArgs[0] ?? '') && npxArgs[1] === 'mcp' && /(?:^|[\\/])npx(?:\.cmd)?$/.test(previous.command ?? '')) {
    extra = npxArgs.slice(2);
  } else throw new Error('发现自定义 e2e MCP 启动方式，请按 README 的 MCP 片段手动迁移');
  const kept = [];
  for (let i = 0; i < extra.length; i++) {
    if (extra[i] === '--project' || extra[i] === '--config') {
      const value = extra[++i];
      const expected = extra[i - 1] === '--project' ? root : join(dir, 'e2e.config.ts');
      if (!value || ![resolve(root, value), resolve(dir, value)].some((path) => samePath(path, expected))) {
        throw new Error('e2e MCP 指向其他项目或配置，停止自动迁移');
      }
    } else if (extra[i].startsWith('--project=') || extra[i].startsWith('--config=')) {
      throw new Error('请将 MCP 的 --project/--config 改为独立参数后重试');
    } else kept.push(extra[i]);
  }
  return { ...previous, ...entry, args: [launcher, ...kept] };
}

// 只解析 kit 生成的 JSON 兼容 TOML 字符串/数组；自定义语法明确报错，避免重写整份 TOML。
function migrateToml(text) {
  const tables = [...text.matchAll(/^\s*\[[^\]\r\n]+\][^\r\n]*(?:\r?\n|$)/gm)];
  const matches = tables.filter((match) => /^\s*\[mcp_servers\.e2e\]/.test(match[0]));
  if (matches.length > 1) throw new Error('存在重复的 [mcp_servers.e2e]');
  const block = `[mcp_servers.e2e]\ncommand = ${JSON.stringify(entry.command)}\nargs = ${JSON.stringify(entry.args)}\n`;
  if (!matches.length) return `${text}${text && !text.endsWith('\n') ? '\n' : ''}\n${block}`;
  const match = matches[0];
  const end = tables[tables.indexOf(match) + 1]?.index ?? text.length;
  let section = text.slice(match.index, end);
  const command = section.match(/^command\s*=\s*("(?:[^"\\\r\n]|\\.)*")[ \t]*(?:#[^\r\n]*)?\r?$/m);
  const args = section.match(/^args\s*=\s*(\[[\s\S]*?\])[ \t]*(?:#[^\r\n]*)?\r?$/m);
  if (!command || !args) throw new Error('e2e TOML 使用自定义语法，请按 README 手动迁移 command/args');
  let previous;
  try { previous = { command: JSON.parse(command[1]), args: JSON.parse(args[1]) }; }
  catch { throw new Error('e2e TOML 参数无法安全解析，请按 README 手动迁移'); }
  const next = migrate(previous);
  section = section.replace(command[0], () => `command = ${JSON.stringify(next.command)}`)
    .replace(args[0], () => `args = ${JSON.stringify(next.args)}`);
  return text.slice(0, match.index) + section + text.slice(end);
}

function main() {
  const [major, minor, patch] = process.versions.node.split('.').map(Number);
  if (!(major > 24 || (major === 24 && minor >= 8) || (major === 22 && (minor > 22 || (minor === 22 && patch >= 3))))) {
    throw new Error('Node 版本不满足要求：22.22.3+（22.x）或 24.8.0+');
  }
  const options = process.argv.slice(2);
  const selected = new Set();
  for (let i = 0; i < options.length; i++) {
    if (options[i] === '--skip-browser') continue;
    if (options[i] !== '--client' || !options[i + 1]) throw new Error('用法：npm run sync -- [--client codex,claude,cursor] [--skip-browser]');
    for (const client of options[++i].split(',')) {
      if (!Object.hasOwn(clients, client)) throw new Error(`不支持自动配置客户端 ${client}，请按 README 手动接入`);
      selected.add(client);
    }
  }
  const project = JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8'));
  for (const name of ['e2e', '@e2e-dev/web']) {
    const installed = JSON.parse(readFileSync(join(dir, 'node_modules', name, 'package.json'), 'utf8'));
    if (installed.version !== project.devDependencies[name]) throw new Error(`${name} 版本与项目不一致，请先执行 npm ci`);
  }
  const writes = new Map();
  const official = join(dir, 'node_modules/e2e/skills/e2e');
  const canonical = join(root, '.agents/skills/e2e');
  planSkill(official, canonical, writes);
  for (const client of ['claude', 'cursor']) {
    const target = join(root, `.${client}/skills/e2e`);
    // 官方初始化生成的 .claude 软链直接复用 canonical，不重复写入。
    if (existsSync(target) && samePath(target, canonical)) continue;
    if (existsSync(target) || selected.has(client) || existsSync(join(root, clients[client]))) planSkill(official, target, writes);
  }
  for (const [client, rel] of Object.entries(clients)) {
    const file = join(root, rel);
    safePath(file);
    if (!existsSync(file) && !selected.has(client)) continue;
    const text = existsSync(file) ? readFileSync(file, 'utf8') : '';
    if (client === 'codex') writes.set(file, migrateToml(text));
    else {
      const data = text ? parseJson(text, rel) : {};
      if (!data || Array.isArray(data) || typeof data !== 'object' || (data.mcpServers && (typeof data.mcpServers !== 'object' || Array.isArray(data.mcpServers)))) throw new Error(`${rel} 格式不正确`);
      data.mcpServers ??= {};
      data.mcpServers.e2e = migrate(data.mcpServers.e2e);
      writes.set(file, `${JSON.stringify(data, null, 2)}\n`);
    }
  }
  const marker = join(root, '.e2e-kit.json');
  safePath(marker);
  if (existsSync(marker)) {
    const data = parseJson(readFileSync(marker, 'utf8'), '.e2e-kit.json');
    if (!data || typeof data !== 'object' || Array.isArray(data)) throw new Error('kit 标记格式不正确');
    if (data.config && !samePath(resolve(root, data.config), join(dir, 'e2e.config.ts'))) throw new Error('kit 标记指向其他配置，停止同步');
    data.e2eVersion = project.devDependencies.e2e;
    writes.set(marker, `${JSON.stringify(data, null, 2)}\n`);
  }
  // 先完成全部解析和路径校验，再写入，避免配置不兼容时只迁移一部分。
  for (const file of writes.keys()) safePath(file);
  let changed = 0;
  for (const [file, content] of writes) {
    const bytes = Buffer.isBuffer(content) ? content : Buffer.from(content);
    if (existsSync(file) && readFileSync(file).equals(bytes)) continue;
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, bytes, { mode: 0o600 });
    changed++;
  }
  console.log(`[e2e] 本机同步完成：e2e ${project.devDependencies.e2e}，Web ${project.devDependencies['@e2e-dev/web']}；更新 ${changed} 个文件。`);
  console.log('[e2e] 已保留 e2e-kit Skill、.env、草稿、运行产物及其他 MCP 配置。');
  console.log('[e2e] WorkBuddy / ZCode / DSH 等手动接入片段（只替换 e2e 的 command/args）：');
  console.log(JSON.stringify(entry, null, 2));
  if (!options.includes('--skip-browser')) {
    const result = spawnSync(process.execPath, [join(dir, 'node_modules/playwright-core/cli.js'), 'install', 'chromium'], { cwd: dir, stdio: 'inherit' });
    if (result.status !== 0) throw new Error('浏览器内核安装失败；可配置 PLAYWRIGHT_DOWNLOAD_HOST 后重新执行 npm run sync');
  }
  console.log('[e2e] 请重启客户端/MCP 会话；此命令没有执行业务测试。');
}

try { main(); }
catch (error) {
  console.error(`[e2e] 同步失败：${error.code === 'ENOENT' ? '缺少项目依赖，请先在 e2e 目录执行 npm ci' : error.message}`);
  process.exitCode = 1;
}
