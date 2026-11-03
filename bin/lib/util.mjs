// 文件与模板工具：只用 Node 内置能力，保持 kit 零依赖。

import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync, chmodSync } from 'node:fs';
import { dirname, join } from 'node:path';

export function sha256(text) {
  return createHash('sha256').update(text, 'utf8').digest('hex');
}

export function fileExists(p) {
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
}

export function dirExists(p) {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
}

export function readText(p, fallback = '') {
  try {
    return readFileSync(p, 'utf8');
  } catch {
    return fallback;
  }
}

export function readJson(p, fallback = null) {
  const text = readText(p, '');
  if (!text) return fallback;
  try {
    return JSON.parse(text);
  } catch {
    return fallback;
  }
}

export function ensureDir(p) {
  mkdirSync(p, { recursive: true });
}

export function writeText(p, content, { mode } = {}) {
  ensureDir(dirname(p));
  writeFileSync(p, content, 'utf8');
  if (mode) chmodSync(p, mode);
}

/**
 * 渲染模板：替换 {{KEY}} 占位符；未知占位符原样保留，便于暴露漏传。
 */
export function render(template, vars) {
  return template.replace(/\{\{([A-Z0-9_]+)\}\}/g, (match, key) =>
    Object.prototype.hasOwnProperty.call(vars, key) ? String(vars[key]) : match,
  );
}

export function loadTemplate(templatesDir, name) {
  return readFileSync(join(templatesDir, name), 'utf8');
}

/** 按行合并忽略规则：保留原有内容与顺序，只追加缺失行；返回 {content, added}。 */
export function mergeIgnoreList(existing, wantedLines) {
  const lines = (existing ?? '').split(/\r?\n/);
  const present = new Set(lines.map((l) => l.trim()));
  const added = [];
  for (const line of wantedLines) {
    const key = line.trim();
    if (!key || present.has(key)) continue;
    present.add(key);
    added.push(line);
  }
  if (!added.length) return { content: existing ?? '', added };
  const base = (existing ?? '').replace(/\s*$/, '');
  const head = base ? `${base}\n\n` : '';
  return { content: `${head}# e2e 测试产物（e2e-kit 追加）\n${added.join('\n')}\n`, added };
}

const MARKER_BEGIN = '<!-- e2e-kit:route:begin -->';
const MARKER_END = '<!-- e2e-kit:route:end -->';

/** 在文档末尾追加一个带标记的区块；已存在标记则跳过。返回 {content, added}。 */
export function mergeMarkedSection(existing, body) {
  const text = existing ?? '';
  if (text.includes(MARKER_BEGIN)) return { content: text, added: false };
  const block = `${MARKER_BEGIN}\n${body.trim()}\n${MARKER_END}\n`;
  const base = text.replace(/\s*$/, '');
  return { content: base ? `${base}\n\n${block}` : block, added: true };
}

/** 合并 .e2e-kit.json：保留用户字段，只更新工具管理的字段。 */
export function mergeMarker(existing, patch) {
  const current = existing && typeof existing === 'object' ? existing : {};
  const next = { ...current, ...patch };
  next.generated = { ...(current.generated ?? {}), ...(patch.generated ?? {}) };
  return next;
}

export function posix(p) {
  return p.split('\\').join('/');
}
