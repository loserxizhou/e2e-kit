// kit 自身的路径与版本。
// 目录布局：<kit>/{bin,skills,templates,run.sh}

import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { readJson } from './util.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));

/** kit 根目录（bin/lib 的上一级）。 */
export const KIT_ROOT = resolve(HERE, '..', '..');
export const TEMPLATES_DIR = join(KIT_ROOT, 'templates');
export const SKILLS_DIR = join(KIT_ROOT, 'skills');
export const BIN_DIR = join(KIT_ROOT, 'bin');

export function kitVersion() {
  const pkg = readJson(join(KIT_ROOT, 'package.json'), null);
  return pkg?.version ?? '0.0.0';
}

export function mcpWrapperPath() {
  return join(BIN_DIR, 'e2e-mcp.mjs');
}

export function cliPath() {
  return join(BIN_DIR, 'e2e-kit.mjs');
}
