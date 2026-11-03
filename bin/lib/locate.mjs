// 项目定位：找到「这个仓库的 e2e 配置在哪」。
// 优先级：--project / E2E_PROJECT → E2E_CONFIG → .e2e-kit.json → 从 startDir 向上查找。

import { existsSync, readFileSync, statSync } from 'node:fs';
import { dirname, isAbsolute, join, resolve } from 'node:path';

export const CONFIG_NAMES = ['e2e.config.ts', 'e2e.config.mts'];
/** 常见布局：根目录、e2e/、test/e2e/；按顺序在每一层里查找。 */
export const SUBDIRS = ['', 'e2e', join('test', 'e2e')];

export class LocateError extends Error {
  constructor(code, message, details = {}) {
    super(message);
    this.name = 'LocateError';
    this.code = code;
    this.details = details;
  }
}

export const NOT_INITIALIZED_MESSAGE = [
  '未找到 e2e 配置：从当前目录向上没有发现 e2e.config.ts。',
  '· 本项目尚未初始化：克隆 e2e-kit 仓库后运行 bash run.sh（github.com/loserxizhou/e2e-kit）',
  '· e2e 放在自定义目录：在 .e2e-kit.json 的 dir/config 中记录，或设置 E2E_CONFIG',
  '· 多个子项目：用 --project <目录> 指定项目根',
].join('\n');

function isDir(p) {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
}

function isFile(p) {
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
}

/** 在单个目录里按常见布局收集候选配置。 */
export function findCandidates(dir) {
  const found = [];
  for (const sub of SUBDIRS) {
    for (const name of CONFIG_NAMES) {
      const file = join(dir, sub, name);
      if (isFile(file)) found.push(resolve(file));
    }
  }
  return found;
}

function readMarker(dir) {
  const file = join(dir, '.e2e-kit.json');
  if (!isFile(file)) return null;
  try {
    const data = JSON.parse(readFileSync(file, 'utf8'));
    return { file, data };
  } catch {
    return { file, data: null, broken: true };
  }
}

function markerConfig(dir, marker) {
  if (!marker?.data) return null;
  const rel = marker.data.config ?? (marker.data.dir ? join(marker.data.dir, 'e2e.config.ts') : null);
  if (!rel) return null;
  const file = isAbsolute(rel) ? rel : resolve(dir, rel);
  return isFile(file) ? file : null;
}

/**
 * @param {object} options
 * @param {string} [options.project] --project 或 E2E_PROJECT 指定的项目根
 * @param {string} [options.config]  E2E_CONFIG 指定的配置文件
 * @param {string} [options.startDir] 开始向上查找的目录，默认 cwd
 * @param {NodeJS.ProcessEnv} [options.env]
 * @returns {{config: string, projectRoot: string, method: string}}
 */
export function locateProject(options = {}) {
  const env = options.env ?? process.env;
  const explicitProject = options.project ?? env.E2E_PROJECT;
  const explicitConfig = options.config ?? env.E2E_CONFIG;

  if (explicitConfig) {
    const config = isAbsolute(explicitConfig) ? explicitConfig : resolve(process.cwd(), explicitConfig);
    if (!isFile(config)) {
      throw new LocateError('CONFIG_NOT_FOUND', `E2E_CONFIG 指向的文件不存在：${config}`);
    }
    return { config, projectRoot: dirname(config), method: 'env:E2E_CONFIG' };
  }

  let dir = explicitProject
    ? resolve(process.cwd(), explicitProject)
    : resolve(options.startDir ?? process.cwd());

  if (explicitProject && !isDir(dir)) {
    throw new LocateError('PROJECT_NOT_FOUND', `--project / E2E_PROJECT 指向的目录不存在：${dir}`);
  }

  // 第一遍：优先认 .e2e-kit.json（最近祖先优先），它记录的是权威布局。
  {
    let probe = dir;
    while (true) {
      const marker = readMarker(probe);
      const fromMarker = markerConfig(probe, marker);
      if (fromMarker) {
        return { config: fromMarker, projectRoot: dirname(fromMarker), method: 'marker:.e2e-kit.json' };
      }
      const parent = dirname(probe);
      if (parent === probe) break;
      probe = parent;
    }
  }

  // 第二遍：从近到远找标准布局的配置。
  const visited = [];
  while (true) {
    visited.push(dir);

    const candidates = findCandidates(dir);
    if (candidates.length === 1) {
      return { config: candidates[0], projectRoot: dirname(candidates[0]), method: 'walk-up' };
    }
    if (candidates.length > 1) {
      throw new LocateError(
        'CONFIG_AMBIGUOUS',
        `当前目录存在多个 e2e 配置，无法确定使用哪一个：\n${candidates.map((c) => `  - ${c}`).join('\n')}\n请用 --config <路径> 指定，或在 .e2e-kit.json 记录 config。`,
        { candidates },
      );
    }

    const parent = dirname(dir);
    if (parent === dir) {
      throw new LocateError('NOT_INITIALIZED', NOT_INITIALIZED_MESSAGE, { visited });
    }
    dir = parent;
  }
}

/** locate 的安全包装：未初始化时返回 null，其余错误继续抛。 */
export function tryLocate(options = {}) {
  try {
    return locateProject(options);
  } catch (err) {
    if (err?.code === 'NOT_INITIALIZED') return null;
    throw err;
  }
}

/** 从配置文件向上找仓库根：优先 .e2e-kit.json，其次 .git；都找不到则返回配置目录。 */
export function findRepoRoot(configPath) {
  const fallback = dirname(configPath);
  let probe = fallback;
  while (true) {
    if (existsSync(join(probe, '.e2e-kit.json')) || existsSync(join(probe, '.git'))) return probe;
    const parent = dirname(probe);
    if (parent === probe) return fallback;
    probe = parent;
  }
}

export function configCandidatesIn(dir) {
  return findCandidates(resolve(dir));
}

export function markerPath(projectRoot) {
  return join(projectRoot, '.e2e-kit.json');
}

export function markerExists(projectRoot) {
  return existsSync(markerPath(projectRoot));
}
