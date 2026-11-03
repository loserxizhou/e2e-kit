// 智能办公面板公共操作（入库共享：scratch 草稿与 tests 回归用例统一 import 此文件，勿复制进草稿）。
// 关键经验（2026-10-19 实战沉淀）：
// 1) 目录话术必须写「在我的文档的“暂存目录”文件夹里」，「暂存目录」要被中文引号包住，
//    否则模型会把它截断成「暂存」，目录解析失败（不出确认卡片）。
// 2) is_draft 是必填参数，提问必须写明「保存为草稿」或「直接发布」。
// 3) 等待本轮结束用「内容由AI生成」脚注计数增量，不能用文本长度稳定。

export async function openAssistant(app: any, browser: any) {
  await app.open('./');
  await expectNode(browser.locator('text=全部应用').first(), 60_000);
  await browser.locator('text="智能办公"').first().click();
  await expectNode(browser.locator('[role=dialog]'), 30_000);
}

async function expectNode(locator: any, timeout: number) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const n = await locator.count();
    if (n > 0) return;
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error('节点未出现');
}

async function waitTurn(browser: any, before: string, waitMs: number) {
  const dialog = browser.locator('[role=dialog]');
  const beforeFooter = (before.match(/内容由AI生成/g) || []).length;
  const deadline = Date.now() + waitMs;
  let text = before;
  let lastLen = -1;
  let stable = 0;
  while (Date.now() < deadline) {
    text = (await dialog.textContent()) ?? '';
    if (text.includes('上下文长度') || text.includes('额度已用尽')) break;
    const footerCount = (text.match(/内容由AI生成/g) || []).length;
    if (footerCount > beforeFooter && text.length > before.length + 5) break;
    if (text.length === lastLen) stable += 1; else { stable = 0; lastLen = text.length; }
    if (stable >= 5 && text.length > before.length + 5) break;
    await new Promise((r) => setTimeout(r, 2_000));
  }
  await new Promise((r) => setTimeout(r, 1_500));
  text = (await dialog.textContent()) ?? '';
  return { delta: text.slice(before.length), full: text, tail: text.slice(-1600) };
}

export async function ask(browser: any, question: string, waitMs = 120_000, preserveSkill = false) {
  const dialog = browser.locator('[role=dialog]');
  const input = dialog.getByRole('textbox');
  await expectNode(input, 15_000);
  const before = (await dialog.textContent()) ?? '';
  // 智能体标签也在 contenteditable 内；续问验收用键盘追加，避免 fill 把标签一并清掉。
  if (preserveSkill) {
    await input.press('End');
    await input.pressSequentially(question);
  } else {
    await input.fill(question);
  }
  await dialog.getByRole('button', '发送').click();
  const r = await waitTurn(browser, before, waitMs);
  return { ...r, before };
}

export async function cardState(browser: any) {
  const dialog = browser.locator('[role=dialog]');
  const full = (await dialog.textContent()) ?? '';
  let review = 0;
  try { review = await browser.locator('[role=dialog] .xagent-review-item-title').count(); } catch { review = 0; }
  let confirmBtn = 0;
  try { confirmBtn = await dialog.getByRole('button', '确认执行').count(); } catch { confirmBtn = 0; }
  if (confirmBtn === 0) {
    try { confirmBtn = await dialog.getByRole('button', '确认').count(); } catch { confirmBtn = 0; }
  }
  return { review, confirmBtn, hasCard: review > 0 || confirmBtn > 0, text: full };
}

/** 点确认并等待执行结果 */
export async function confirmExecute(browser: any, waitMs = 120_000) {
  const dialog = browser.locator('[role=dialog]');
  const before = (await dialog.textContent()) ?? '';
  let clicked = false;
  for (const name of ['确认执行', '确认']) {
    try {
      const btn = dialog.getByRole('button', name).first();
      if (await btn.count()) { await btn.click(); clicked = true; break; }
    } catch { /* 继续尝试下一个 */ }
  }
  if (!clicked) return { clicked: false, delta: '', full: before };
  const r = await waitTurn(browser, before, waitMs);
  return { clicked: true, ...r };
}

/** 点取消按钮关闭确认卡片 */
export async function cancelCard(browser: any) {
  const dialog = browser.locator('[role=dialog]');
  const before = (await dialog.textContent()) ?? '';
  for (const name of ['取消', '取消执行', '关闭']) {
    try {
      const btn = dialog.getByRole('button', name).first();
      if (await btn.count()) {
        await btn.click();
        await new Promise((r) => setTimeout(r, 2_000));
        const after = (await dialog.textContent()) ?? '';
        return after.slice(-300);
      }
    } catch { /* 试下一个 */ }
  }
  return '未找到取消按钮|' + before.slice(-120);
}

export function record(id: string, result: string, actual: string) {
  console.log('[CASE]' + JSON.stringify({
    id,
    result,
    actual: actual.replace(/\s+/g, ' ').slice(0, 400),
  }));
}

/** 额度/上下文异常统一记为未执行，避免把环境问题算成功能缺陷 */
export function blocked(delta: string, id: string): boolean {
  if (delta.includes('额度已用尽')) {
    record(id, '未执行', '回复：个人 Token 额度已用尽，本轮未取得结论');
    return true;
  }
  if (delta.includes('上下文长度')) {
    record(id, '未通过', '回复：对话内容超出模型的上下文长度限制，请求未被执行');
    return true;
  }
  return false;
}

export const FOLDER = '在我的文档的“暂存目录”文件夹里';

export function q(subject: string, content: string, draft = true, extra = '') {
  const c = content ? `，正文写：${content}` : '';
  return `${FOLDER}新建一篇标题为${subject}的文档${c}，${draft ? '保存为草稿' : '直接发布'}${extra}`;
}
