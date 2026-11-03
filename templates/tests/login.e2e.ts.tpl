import { test } from '@e2e-dev/web';
import { expect } from 'e2e';

// 冒烟测试：登录页能打开并渲染出输入框，不依赖任何 AI 模型
test('login page opens', async ({ app, browser }) => {
  await app.open('./');
  await expect(browser.locator('body')).toBeVisible();
  await expect(browser.locator('input').first()).toBeVisible({ timeout: 30_000 });
});
