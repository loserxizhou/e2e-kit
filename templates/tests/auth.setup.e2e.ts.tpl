import { test } from '@e2e-dev/web';
import { expect } from 'e2e';
import { initializeAdminSession } from '../helpers/auth-session';

// 登录一次并保存 session 'admin'；其他测试用 { session: 'admin' } 复用，无需重复登录。
// 密码只在 Node 端经 RSA 加密后提交正式登录接口，不填入页面，保留失败截图能力。
test.setup(
  'authenticate as admin',
  { sessions: ['admin'] },
  async ({ app, session, browser }) => {
    await initializeAdminSession(browser, app.baseUrl);
    await app.open('./');

    // session.save 不校验认证状态，必须确认已进入登录后的页面。
    await expect(browser).toHaveURL(/^(?!.*login)/, { timeout: 30_000 });
    await expect(browser.locator('text=全部应用').first()).toBeVisible({ timeout: 60_000 });
    await session.save('admin');
  },
);
