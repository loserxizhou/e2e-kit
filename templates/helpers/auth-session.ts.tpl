import { constants, publicEncrypt } from 'node:crypto';
import type { Browser } from '@e2e-dev/web';

type LoginData = Record<string, any>;

/** 通过正式认证接口初始化登录态，避免在页面填入 Secret 后丢失失败截图。 */
export async function initializeAdminSession(browser: Browser, appBaseUrl: string | undefined): Promise<void> {
  if (!appBaseUrl) throw new Error('登录准备缺少被测应用地址');
  const userAccount = process.env.E2E_USER_ADMIN_USERNAME ?? (process.env.EOFFICE_ADMIN_USER || process.env.E2E_USER);
  const password = process.env.E2E_USER_ADMIN_PASSWORD ?? (process.env.EOFFICE_ADMIN_PASSWORD || process.env.E2E_PASSWORD);
  if (!userAccount || !password) throw new Error('登录准备缺少测试账号或密码');

  // 只在 Node 端读取应用入口的 base href，不在浏览器加载未认证的应用。
  const appUrl = new URL(appBaseUrl);
  const html = await (await request(appUrl)).text();
  const baseHref = html.match(/<base\b[^>]*\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i);
  if (!baseHref) throw new Error('应用入口缺少 base href，无法确定登录接口地址');
  const apiRoot = new URL(baseHref[1] ?? baseHref[2] ?? baseHref[3], appUrl);
  if (apiRoot.origin !== appUrl.origin) {
    throw new Error('登录接口与被测页面不同源，拒绝发送测试凭据');
  }
  // 与 HttpService.getApiRoot() 的 base href 解析保持一致，兼容构建版和代理环境。
  const parts = apiRoot.pathname.split('/');
  parts.splice(-3);
  apiRoot.pathname = `${parts.join('/')}/server/public/`;
  apiRoot.search = '';
  apiRoot.hash = '';
  const init = await requestJson(new URL('api/auth/initinfo', apiRoot));
  if (typeof init.data !== 'string') throw new Error('登录初始化信息格式异常');
  const loginConfig = decodeInitInfo(init.data);
  if (Number(loginConfig.security_image_code) || Number(loginConfig.sms_verify) || Number(loginConfig.face_verify)) {
    throw new Error('当前环境要求验证码、短信或人脸验证，接口登录准备不能自动完成；请配置独立的验证流程');
  }
  if (typeof loginConfig.rsa_public_key !== 'string' || !loginConfig.rsa_public_key) {
    throw new Error('登录初始化未返回 RSA 公钥');
  }
  // 服务端把 PEM 头尾和正文直接拼接，Node crypto 需要补齐换行。
  const publicKey = loginConfig.rsa_public_key
    .replace('-----BEGIN PUBLIC KEY-----', '-----BEGIN PUBLIC KEY-----\n')
    .replace('-----END PUBLIC KEY-----', '\n-----END PUBLIC KEY-----');
  let encryptedPassword: string;
  try {
    encryptedPassword = publicEncrypt(
      { key: publicKey, padding: constants.RSA_PKCS1_PADDING }, Buffer.from(password),
    ).toString('base64');
  } catch {
    throw new Error('无法使用服务端 RSA 公钥加密登录密码');
  }
  const response = await requestJson(new URL('api/auth/login', apiRoot), {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ user_account: userAccount, password: encryptedPassword, terminal: 'pc', local: 'zh-CN' }),
  });
  const data = response.data;
  if (!data || typeof data.token !== 'string' || !data.token || !data.current_user?.user_id) {
    throw new Error('登录接口未建立完整登录态，可能仍需额外验证；不会保存未认证的 session');
  }

  // 同源空白文档只用于写存储，不加载 Angular，因此不会跳转或闪现登录页。
  const bootstrapRoute = new RegExp(`^${appUrl.href.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}$`);
  await browser.route(bootstrapRoute, async (route) => {
    await route.fulfill({
      contentType: 'text/html; charset=utf-8',
      body: '<!doctype html><html><head><title>测试登录态初始化</title></head><body></body></html>',
    });
  });
  try {
    await browser.goto(appUrl.href, { waitUntil: 'domcontentloaded' });
    await storeLoginData(browser, data);
  } finally {
    await browser.unroute(bootstrapRoute);
  }
}

/** 不返回、打印或另存 token，只写入前端本来使用的 localForage 存储。 */
async function storeLoginData(browser: Browser, data: LoginData): Promise<void> {
  await browser.evaluate(async (loginData: LoginData) => {
    await new Promise<void>((resolve, reject) => {
      const request = indexedDB.open('localforage');
      request.onupgradeneeded = () => {
        if (!request.result.objectStoreNames.contains('keyvaluepairs')) {
          request.result.createObjectStore('keyvaluepairs');
        }
      };
      request.onerror = () => reject(new Error('无法打开登录态存储'));
      request.onblocked = () => reject(new Error('登录态存储被其他页面占用'));
      request.onsuccess = () => {
        const db = request.result;
        if (!db.objectStoreNames.contains('keyvaluepairs')) {
          db.close();
          reject(new Error('登录态存储结构与当前前端不兼容'));
          return;
        }
        const transaction = db.transaction('keyvaluepairs', 'readwrite');
        transaction.objectStore('keyvaluepairs').put({ ...loginData, token_timestamp: Date.now() }, 'eoffice_login_user');
        transaction.oncomplete = () => { db.close(); resolve(); };
        transaction.onabort = () => { db.close(); reject(new Error('保存登录态失败')); };
        transaction.onerror = () => { db.close(); reject(new Error('保存登录态失败')); };
      };
    });
    if (loginData.access_path) localStorage.setItem('access_path', loginData.access_path);
    if (loginData.case_id) localStorage.setItem('caseID', String(loginData.case_id));
    localStorage.setItem('eoffice_current_local', 'zh-CN');
    return null;
  }, data);
}

function decodeInitInfo(encoded: string): LoginData {
  try {
    const source = Buffer.from(encoded, 'base64');
    const key = Buffer.from('123456');
    const decoded = Buffer.from(source.map((byte, index) => byte ^ key[index % key.length]));
    return JSON.parse(Buffer.from(decoded.toString(), 'base64').toString('utf8'));
  } catch {
    throw new Error('无法解析登录初始化信息');
  }
}

async function request(url: URL, options: RequestInit = {}): Promise<Response> {
  let response: Response;
  try {
    response = await fetch(url, { ...options, redirect: 'error', signal: AbortSignal.timeout(30_000) });
  } catch {
    throw new Error('登录准备接口无法连接或发生重定向，请检查被测地址和服务状态');
  }
  if (!response.ok) throw new Error(`登录准备接口 HTTP ${response.status}`);
  return response;
}

async function requestJson(url: URL, options: RequestInit = {}): Promise<LoginData> {
  const response = await request(url, options);
  let result: LoginData;
  try {
    result = await response.json();
  } catch {
    throw new Error('登录准备接口未返回 JSON');
  }
  // 原始响应可能含认证信息，错误只保留标准错误码。
  if (!result.status) {
    const code = result.errors?.[0]?.code;
    throw new Error(`登录准备被服务端拒绝${typeof code === 'string' && /^0x[0-9a-f]+$/i.test(code) ? `（${code}）` : ''}`);
  }
  return result;
}
