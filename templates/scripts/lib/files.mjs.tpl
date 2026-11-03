import { lstatSync, mkdirSync, renameSync, writeFileSync } from 'node:fs';
import { dirname, isAbsolute, relative, resolve, sep } from 'node:path';
import { randomUUID } from 'node:crypto';

// 批次与交付工具只写项目内的普通路径，不通过软链接写出项目。
export function projectPath(root, ...parts) {
  const target = resolve(root, ...parts);
  const rel = relative(root, target);
  if (isAbsolute(rel) || rel === '..' || rel.startsWith(`..${sep}`)) throw new Error('路径超出项目');
  let current = resolve(root);
  for (const part of rel.split(sep).filter(Boolean)) {
    current = resolve(current, part);
    try {
      if (lstatSync(current).isSymbolicLink()) throw new Error('项目工具拒绝通过软链接读写批次');
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
  }
  return target;
}

export function writeAtomic(root, file, content) {
  projectPath(root, file);
  mkdirSync(dirname(file), { recursive: true, mode: 0o700 });
  const temporary = `${file}.${randomUUID()}.tmp`;
  writeFileSync(temporary, content, { flag: 'wx', mode: 0o600 });
  renameSync(temporary, file);
}

export function writeJson(root, file, value) {
  writeAtomic(root, file, `${JSON.stringify(value, null, 2)}\n`);
}
