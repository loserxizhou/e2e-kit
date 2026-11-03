import { spawnSync } from 'node:child_process';
import { existsSync, lstatSync, readFileSync } from 'node:fs';
import { basename, resolve } from 'node:path';

export function classifyPath(path) {
  const normalized = path.replaceAll('\\', '/');
  if (normalized.split('/').some((part) => part === '..' || part === '.' || !part)) return 'core';
  const name = basename(normalized).toLowerCase();
  if (['agents.md', 'skill.md', 'package.json', 'package-lock.json', 'tsconfig.json', '.gitignore'].includes(name) || /\.config\./.test(name)) return 'core';
  if (normalized === 'e2e/knowledge/README.md') return 'knowledge-index';
  if (/^e2e\/knowledge\/.+\.md$/.test(normalized)) return 'knowledge';
  const parts = normalized.split('/');
  const picture = /\.(?:png|jpe?g|webp)$/i.test(normalized);
  const scene = /^e2e\/tests\/[^/_][^/]*\/.+\.(?:ts|md|json|csv|yaml|yml|xlsx|png|jpg|jpeg|webp)$/i.test(normalized);
  if (scene && !parts.some((part) => part.startsWith('.') || (part.startsWith('_') && !(part === '_assets' && picture)))) return 'scenario';
  return 'core';
}

export function parseChanges(output) {
  const tokens = output.split('\0');
  const entries = [];
  for (let i = 0; i < tokens.length && tokens[i];) {
    const status = tokens[i++];
    const paths = /^[RC]/.test(status) ? [tokens[i++], tokens[i++]] : [tokens[i++]];
    if (paths.some((path) => !path)) throw new Error('无法识别 Git 变更清单');
    for (const path of paths) entries.push({ status, path });
  }
  return entries;
}

export function onlyKnowledgeIndexChanged(previous, current) {
  const heading = /^## 索引\s*$/m;
  const oldMatch = heading.exec(previous);
  const newMatch = heading.exec(current);
  if (!oldMatch || !newMatch || previous.slice(0, oldMatch.index) !== current.slice(0, newMatch.index)) return false;
  const tail = current.slice(newMatch.index + newMatch[0].length).trim();
  const before = previous.slice(oldMatch.index + oldMatch[0].length).trim().split('\n');
  const after = tail.split('\n');
  return before[0] === after[0] && before[1] === after[1] && after.every((line) => !line.trim() || (line.startsWith('|') && line.endsWith('|')));
}

function git(root, args, optional = false) {
  const result = spawnSync('git', args, { cwd: root, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
  if (result.error || result.status !== 0) {
    if (optional) return null;
    throw new Error('Git 范围检查失败，请确认仓库与比较基准');
  }
  return result.stdout;
}

export function inspectScope(root, { staged = false, base = null } = {}) {
  if (staged && base) throw new Error('--staged 与 --base 不能同时使用');
  let reference = 'HEAD';
  if (base) {
    if (base.startsWith('-')) throw new Error('比较基准不可作为 Git 选项');
    const commit = git(root, ['rev-parse', '--verify', `${base}^{commit}`]).trim();
    reference = git(root, ['merge-base', commit, 'HEAD']).trim();
  }
  const hasHead = git(root, ['rev-parse', '--verify', 'HEAD'], true) !== null;
  const changes = parseChanges(git(root, ['diff', ...(staged ? ['--cached'] : []), '--name-status', '-z', '--find-renames', ...(hasHead || base ? [reference] : []), '--']));
  if (!staged) for (const path of git(root, ['ls-files', '--others', '--exclude-standard', '-z']).split('\0').filter(Boolean)) changes.push({ status: '?', path });
  const unique = [...new Map(changes.map((entry) => [entry.path, entry])).values()];
  return unique.map((entry) => {
    let category = classifyPath(entry.path);
    if (category !== 'core') {
      const stage = git(root, ['ls-files', '--stage', '--', entry.path]);
      if (/^120000 /m.test(stage) || (existsSync(resolve(root, entry.path)) && lstatSync(resolve(root, entry.path)).isSymbolicLink())) category = 'core';
    }
    if (category === 'knowledge-index') {
      const previous = git(root, ['show', `${reference}:${entry.path}`], true);
      const current = staged ? git(root, ['show', `:${entry.path}`], true) :
        existsSync(resolve(root, entry.path)) ? readFileSync(resolve(root, entry.path), 'utf8') : null;
      if (previous === null || current === null || !onlyKnowledgeIndexChanged(previous, current)) category = 'core';
    }
    return { ...entry, category, allowed: category !== 'core' };
  });
}
