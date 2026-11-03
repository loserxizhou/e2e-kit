// 交互输入：普通问题、确认、隐藏输入（密码不回显）。
// 非交互（--yes / 无 TTY）时由调用方传默认值，绝不阻塞。

import { createInterface } from 'node:readline';

export function isInteractive() {
  return Boolean(process.stdin.isTTY && process.stdout.isTTY);
}

function askLine(question) {
  return new Promise((resolve) => {
    const rl = createInterface({ input: process.stdin, output: process.stdout });
    rl.question(question, (answer) => {
      rl.close();
      resolve(answer.trim());
    });
  });
}

export async function ask(question, { defaultValue = '', interactive = isInteractive() } = {}) {
  if (!interactive) return defaultValue;
  const hint = defaultValue ? `（默认：${defaultValue}）` : '';
  const answer = await askLine(`${question}${hint} `);
  return answer || defaultValue;
}

export async function askHidden(question, { interactive = isInteractive() } = {}) {
  if (!interactive) return '';
  if (!process.stdin.isTTY) return askLine(`${question} `);

  return new Promise((resolve) => {
    process.stdout.write(`${question} `);
    const stdin = process.stdin;
    const wasRaw = stdin.isRaw;
    stdin.setRawMode?.(true);
    stdin.resume();
    let value = '';
    const onData = (buf) => {
      const str = buf.toString('utf8');
      for (const ch of str) {
        if (ch === '\r' || ch === '\n') {
          stdin.setRawMode?.(wasRaw ?? false);
          stdin.pause();
          stdin.removeListener('data', onData);
          process.stdout.write('\n');
          resolve(value);
          return;
        }
        if (ch === '\u0003') {
          stdin.setRawMode?.(wasRaw ?? false);
          stdin.pause();
          stdin.removeListener('data', onData);
          process.stdout.write('\n');
          resolve('');
          return;
        }
        if (ch === '\u007f' || ch === '\b') {
          if (value.length) {
            value = value.slice(0, -1);
            process.stdout.write('\b \b');
          }
          continue;
        }
        if (ch >= ' ') {
          value += ch;
          process.stdout.write('*');
        }
      }
    };
    stdin.on('data', onData);
  });
}

export async function confirm(question, { defaultValue = false, interactive = isInteractive() } = {}) {
  if (!interactive) return defaultValue;
  const hint = defaultValue ? 'Y/n' : 'y/N';
  const answer = (await askLine(`${question} (${hint}) `)).toLowerCase();
  if (!answer) return defaultValue;
  return answer === 'y' || answer === 'yes';
}
