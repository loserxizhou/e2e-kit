// 客户端接入：把 MCP 配置与 skill 写进「当前项目」。
// 只写项目内文件，不碰用户目录；WorkBuddy/ZCode 只输出片段（其配置在用户目录且格式未公开）。
// 由 init --client 调用，不单独暴露命令。

import { cpSync, existsSync } from 'node:fs';
import { join, relative } from 'node:path';

import { SKILLS_DIR, mcpWrapperPath } from './lib/kit.mjs';
import { readJson, readText, sha256, writeText } from './lib/util.mjs';

export const SUPPORTED_CLIENTS = ['claude', 'codex', 'cursor', 'workbuddy', 'zcode', 'dsh'];

export function detectInstalledClients(projectRoot) {
  // dsh 与 Codex 共用 .agents/skills/e2e-kit，无法仅凭目录区分；旧项目需显式传 --client dsh。
  return ['claude', 'codex', 'cursor'].filter((client) => {
    const dir = skillDir(client, projectRoot);
    return Boolean(dir && existsSync(join(dir, 'SKILL.md')));
  });
}

// command 用 init 进程的绝对路径：MCP 由客户端启动，继承的 PATH 里 node 可能低于 22.22.3
function mcpEntry(projectRoot) {
  return {
    command: process.execPath,
    args: [mcpWrapperPath(), '--project', projectRoot],
  };
}

// 旧 kit 条目（裸 node / 包装器路径失效 / command 指向的 node 已不存在）需要迁移；
// npx 风格条目或指向另一份有效安装的条目不是 kit 生成的失效项，不动。
function isStaleKitEntry(entry) {
  if (!entry || typeof entry !== 'object') return false;
  const wrapper = Array.isArray(entry.args) ? String(entry.args[0] ?? '') : '';
  const isKitWrapper = /e2e-mcp\.mjs$/.test(wrapper);
  const commandGone = isKitWrapper && typeof entry.command === 'string'
    && entry.command !== 'node' && entry.command !== 'npx' && !existsSync(entry.command);
  return entry.command === 'node' || (isKitWrapper && !existsSync(wrapper)) || commandGone;
}

function mergeMcpJson(file, entry) {
  const current = readJson(file, null);
  const next = current && typeof current === 'object' ? current : {};
  next.mcpServers = next.mcpServers ?? {};
  if (next.mcpServers.e2e && !isStaleKitEntry(next.mcpServers.e2e)) return { changed: false };
  next.mcpServers.e2e = entry;
  writeText(file, `${JSON.stringify(next, null, 2)}\n`);
  return { changed: true };
}

const KIT_BLOCK_RE = /# e2e-kit:begin[\s\S]*?# e2e-kit:end/;

function appendCodexToml(file, projectRoot) {
  const text = readText(file, '');
  const wrapper = mcpWrapperPath();
  const block = [
    '',
    '# e2e-kit:begin（由 e2e-kit 生成；删除本段即可移除）',
    '[mcp_servers.e2e]',
    `command = ${JSON.stringify(process.execPath)}`,
    `args = [${JSON.stringify(wrapper)}, "--project", ${JSON.stringify(projectRoot)}]`,
    '# e2e-kit:end',
    '',
  ].join('\n');
  if (KIT_BLOCK_RE.test(text)) {
    const existing = text.match(KIT_BLOCK_RE)[0];
    const oldWrapper = existing.match(/args = \["([^"]+)"/)?.[1] ?? '';
    const oldCommand = existing.match(/command = "([^"]+)"/)?.[1] ?? '';
    const stale = existing.includes('command = "node"')
      || (/e2e-mcp\.mjs$/.test(oldWrapper) && !existsSync(oldWrapper))
      || (/e2e-mcp\.mjs$/.test(oldWrapper) && oldCommand !== 'node' && !existsSync(oldCommand));
    if (!stale) return { changed: false };
    writeText(file, text.replace(KIT_BLOCK_RE, block.trim()));
    return { changed: true };
  }
  if (/\[mcp_servers\.e2e\]/.test(text)) return { changed: false };
  writeText(file, text ? `${text.replace(/\s*$/, '')}\n${block}` : block.replace(/^\n/, ''));
  return { changed: true };
}

const SKILL_CLIENT_DIRS = {
  claude: ['.claude', 'skills', 'e2e-kit'],
  codex: ['.agents', 'skills', 'e2e-kit'],
  cursor: ['.cursor', 'skills', 'e2e-kit'],
  dsh: ['.agents', 'skills', 'e2e-kit'],
};

export function skillDir(client, projectRoot) {
  const parts = SKILL_CLIENT_DIRS[client];
  return parts ? join(projectRoot, ...parts) : null;
}

function syncSkill(client, projectRoot, migration, generated) {
  const sourceDir = join(SKILLS_DIR, 'e2e-kit');
  const source = join(sourceDir, 'SKILL.md');
  const destDir = skillDir(client, projectRoot);
  if (!destDir) return { changed: false, status: 'unsupported' };
  const sourceHash = sha256(readText(source));
  const skillPath = relative(projectRoot, join(destDir, 'SKILL.md')).split('\\').join('/');
  const current = join(destDir, 'SKILL.md');
  if (!existsSync(destDir)) {
    cpSync(sourceDir, destDir, { recursive: true });
    return { changed: true, status: 'created', path: skillPath, hash: sourceHash };
  }
  if (!existsSync(current)) {
    cpSync(sourceDir, destDir, { recursive: true, force: true });
    return { changed: true, status: 'created', path: skillPath, hash: sourceHash };
  }
  const currentHash = sha256(readText(current));
  if (currentHash === sourceHash) return { changed: false, status: 'unchanged', path: skillPath, hash: sourceHash };
  const recorded = generated?.[skillPath];
  if (migration !== 'adopt' && recorded !== currentHash) {
    return { changed: false, status: 'skipped', path: skillPath, reason: recorded ? '用户已修改，保留现状' : '来源不明，保留现状' };
  }
  cpSync(sourceDir, destDir, { recursive: true, force: true });
  return { changed: true, status: migration === 'adopt' && recorded !== currentHash ? 'adopted' : 'updated', path: skillPath, hash: sourceHash };
}

function snippetFor(client, projectRoot) {
  const entry = mcpEntry(projectRoot);
  if (client === 'workbuddy') {
    return JSON.stringify(
      { e2e: { type: 'stdio', command: entry.command, args: entry.args, timeout: 120000 } },
      null,
      2,
    );
  }
  if (client === 'zcode') {
    return JSON.stringify({ mcpServers: { e2e: entry } }, null, 2);
  }
  if (client === 'dsh') {
    return [
      '- id: e2e-mcp',
      "  name: '@deepseek-ai/dsh-mcp-client'",
      '  config:',
      '    serverName: e2e',
      '    transport: stdio',
      `    command: ${JSON.stringify(entry.command)}`,
      `    args: [${JSON.stringify(entry.args[0])}, "--project", ${JSON.stringify(projectRoot)}]`,
    ].join('\n');
  }
  return '';
}

function note(record, changed, label) {
  (changed ? record.files : record.skipped).push(changed ? label : `${label}（已存在）`);
}

/**
 * 为指定客户端写入项目级配置。
 * @param {string[]} clients
 * @param {string} projectRoot
 */
export function installClients(clients, projectRoot, { migration = 'safe', skillGenerated = {} } = {}) {
  const result = { ok: true, clients: [] };
  result.skillGenerated = { ...skillGenerated };
  const entry = mcpEntry(projectRoot);

  for (const client of clients) {
    const record = { client, files: [], skipped: [], snippet: null };
    try {
      if (client === 'claude') {
        note(record, mergeMcpJson(join(projectRoot, '.mcp.json'), entry).changed, '.mcp.json');
        const skill = syncSkill(client, projectRoot, migration, skillGenerated);
        note(record, skill.changed, '.claude/skills/e2e-kit/');
        if (skill.hash) result.skillGenerated[skill.path] = skill.hash;
        if (skill.status === 'skipped') record.skipped.push(`${skill.path}（${skill.reason}）`);
      } else if (client === 'codex') {
        note(record, appendCodexToml(join(projectRoot, '.codex', 'config.toml'), projectRoot).changed, '.codex/config.toml');
        const skill = syncSkill(client, projectRoot, migration, skillGenerated);
        note(record, skill.changed, '.agents/skills/e2e-kit/');
        if (skill.hash) result.skillGenerated[skill.path] = skill.hash;
        if (skill.status === 'skipped') record.skipped.push(`${skill.path}（${skill.reason}）`);
      } else if (client === 'cursor') {
        note(record, mergeMcpJson(join(projectRoot, '.cursor', 'mcp.json'), entry).changed, '.cursor/mcp.json');
        const skill = syncSkill(client, projectRoot, migration, skillGenerated);
        note(record, skill.changed, '.cursor/skills/e2e-kit/');
        if (skill.hash) result.skillGenerated[skill.path] = skill.hash;
        if (skill.status === 'skipped') record.skipped.push(`${skill.path}（${skill.reason}）`);
      } else {
        if (client === 'dsh') {
          const skill = syncSkill(client, projectRoot, migration, skillGenerated);
          note(record, skill.changed, '.agents/skills/e2e-kit/');
          if (skill.hash) result.skillGenerated[skill.path] = skill.hash;
          if (skill.status === 'skipped') record.skipped.push(`${skill.path}（${skill.reason}）`);
        }
        record.snippet = snippetFor(client, projectRoot);
      }
    } catch (err) {
      result.ok = false;
      record.error = err instanceof Error ? err.message : String(err);
    }
    result.clients.push(record);
  }
  return result;
}
