import { test } from '@e2e-dev/web';
import { expect, credentials } from 'e2e';
import { initializeAdminSession } from '../helpers/auth-session';

// 登录一次并保存 session 'admin'；其他测试用 { session: 'admin' } 复用，无需重复登录。
// admin 通过同源认证接口初始化登录态；密码只在 Node 端从 e2e/.env 读取，
// 不进入页面输入、模型输入或报告。
//
// TODO 登录页定位器：默认值与 e-office 登录页一致，其他系统请按下面三个环境变量改
//   E2E_LOGIN_USER_SELECTOR / E2E_LOGIN_PASSWORD_SELECTOR / E2E_LOGIN_BUTTON_TEXT
// 也可直接改本文件的定位器（改完记得提交）。
const USER_SELECTOR = process.env.E2E_LOGIN_USER_SELECTOR || '#user_account';
const PASSWORD_SELECTOR = process.env.E2E_LOGIN_PASSWORD_SELECTOR || '#password';
const BUTTON_TEXT = process.env.E2E_LOGIN_BUTTON_TEXT || '登录';

async function expectHome(browser: import('@e2e-dev/web').Browser) {
  await expect(browser.locator('text=全部应用').first()).toBeVisible({ timeout: 60_000 });
}

test.setup(
  'authenticate as admin',
  { sessions: ['admin'] },
  async ({ app, screen, session, browser }) => {
    if (process.env.EOFFICE_E2E_LOGIN_MODE === 'ui') {
      const admin = credentials.user('admin');
      await app.open('./');
      await browser.locator(USER_SELECTOR).fill(admin.username);
      await browser.locator(PASSWORD_SELECTOR).fill(admin.password);
      await screen.getByRole('button', BUTTON_TEXT).tap();
    } else {
      await initializeAdminSession(browser, app.baseUrl);
      await app.open('./');
    }
    // 刚打开入口时 URL 也可能不含 login；主页出现才保存会话。
    await expectHome(browser);
    await session.save('admin');
  },
);

// 特权会话：入库记录删除等按钮只对 user_id === 'admin' 放行，普通测试账号看不到。
// 密码同样只来自 e2e/.env（E2E_ADMIN_PASSWORD），不进代码与报告。
test.setup(
  'authenticate as root admin',
  { sessions: ['adminRoot'] },
  async ({ app, screen, session, browser }) => {
    const root = credentials.user('adminRoot');

    await app.open('./');
    const userInput = browser.locator(USER_SELECTOR);
    // 已认证时用原生重置清掉包括 IndexedDB 在内的登录态。
    if (await browser.locator('text=全部应用').first().isVisible()) await app.clearState();
    await expect(userInput).toBeVisible({ timeout: 30_000 });

    await userInput.fill(root.username);
    await browser.locator(PASSWORD_SELECTOR).fill(root.password);
    await screen.getByRole('button', BUTTON_TEXT).tap();
    await expectHome(browser);
    await session.save('adminRoot');
  },
);
