import type { E2EConfig } from 'e2e';
import { web } from '@e2e-dev/web';
import { createAnthropic } from '@ai-sdk/anthropic';
import { createOpenAICompatible } from '@ai-sdk/openai-compatible';
import { readFileSync } from 'node:fs';
import { businessReporter } from './scripts/reporters/business.mjs';

// e2e 不自动加载 .env；本文件用自身路径定位 .env，从仓库根启动（MCP）也能读到。
// 所有环境配置集中在 e2e/.env（模板见 .env.example），代码不内置默认值：
// 必填项缺失时启动即失败，报错列出缺失项。
try {
  process.loadEnvFile(new URL('./.env', import.meta.url));
} catch {
  // .env 不存在时继续，由下方的必填项检查给出明确报错
}

const required = ['APP_URL', 'EOFFICE_ADMIN_USER', 'EOFFICE_ADMIN_PASSWORD'];
if (process.env.AI_API_KEY) required.push('AI_PROVIDER', 'AI_MODEL', 'AI_BASE_URL');
const missing = required.filter((k) => !process.env[k]?.trim());
if (missing.length) {
  throw new Error(
    `e2e 配置缺失：${missing.join('、')}。请复制 e2e/.env.example 为 e2e/.env 并填写（被测地址、测试账号、模型配置全部在 .env 中）。`,
  );
}

// agent 步骤的模型，按 .env 的 AI_PROVIDER 选协议：
//   anthropic        —— Anthropic Messages 协议（智谱 /api/anthropic、Claude 官方）
//   openai-compatible —— OpenAI Chat Completions 协议（DeepSeek、Kimi、Qwen、
//                        智谱 /api/paas/v4、Ollama/vLLM 本地模型等）
// 不含 agent 步骤的测试不需要模型，未配置 AI_API_KEY 时也能加载和运行。
function buildAgentModel() {
  const baseURL = process.env.AI_BASE_URL!;
  const apiKey = process.env.AI_API_KEY!;
  const modelId = process.env.AI_MODEL!;
  if (process.env.AI_PROVIDER === 'anthropic') {
    return createAnthropic({ baseURL, apiKey })(modelId);
  }
  if (process.env.AI_PROVIDER === 'openai-compatible') {
    return createOpenAICompatible({ name: 'e2e-ai', baseURL, apiKey }).chatModel(modelId);
  }
  throw new Error(
    `AI_PROVIDER 只支持 anthropic / openai-compatible，当前值：${process.env.AI_PROVIDER}`,
  );
}

// 局域网目标自动经本地转发接入（scripts/forward-test-env.mjs）：
// .env 的 APP_URL 始终填真实地址。转发进程启动时在 .e2e/forward.json 登记目标，
// 当 APP_URL 是非 loopback 的明文 HTTP 且与登记目标匹配（进程存活）时，
// 自动改经 127.0.0.1 接入（127.x 属 loopback，明文 HTTP 放行）；
// 未启动转发则按原地址直连——本地环境不受影响，裸 IP 明文会被框架拒绝（属预期，启动转发即可）。
function resolveAppUrl(raw: string): string {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return raw;
  }
  const host = url.hostname;
  const isLoopback =
    host === 'localhost' ||
    host.endsWith('.localhost') ||
    host === '::1' ||
    host === '[::1]' ||
    /^127(\.\d{1,3}){3}$/.test(host);
  if (url.protocol !== 'http:' || isLoopback) return raw; // 本地 / hosts 别名 / HTTPS：直连，不经转发
  let forward: { listenPort?: number; targetHost?: string; targetPort?: number | string; pid?: number };
  try {
    forward = JSON.parse(readFileSync(new URL('./.e2e/forward.json', import.meta.url), 'utf8'));
  } catch {
    return raw; // 转发未启动：按原地址直连
  }
  if (forward.targetHost !== host || Number(forward.targetPort) !== Number(url.port || 80)) return raw;
  try {
    process.kill(forward.pid ?? 0, 0); // 登记进程已死（如被强杀）视为未启动，防残留误改写
  } catch {
    return raw;
  }
  // 约定：转发监听端口 = 目标端口（见 scripts/forward-test-env.mjs）
  const via = `http://127.0.0.1:${forward.listenPort ?? url.port}${url.pathname}`;
  console.log(`[e2e] 检测到本地转发：${host}:${url.port || 80} 经 ${via} 接入`);
  return via;
}

const base = {
  // 普通回归不导入探索脚本；批次入口按明确 scratch 范围开启发现。
  tests: ['tests/**/*.e2e.ts', ...(process.env.EOFFICE_E2E_INCLUDE_SCRATCH === '1' ? ['scratch/**/*.e2e.ts'] : []), '!tests/**/_*/**', '!scratch/**/_*/**'],
  reporters: ['list', 'markdown', 'junit', businessReporter()],
  credentials: {
    admin: {
      username: process.env.EOFFICE_ADMIN_USER!,
      // 函数形式惰性求值：只在真正填密码时读取，明文不进代码与报告
      password: () => process.env.EOFFICE_ADMIN_PASSWORD ?? '',
    },
  },
  // 本地 dev server 与 AI 后端都是单实例，串行跑避免并发把环境压垮
  workers: 1,
  targets: [
    {
      engine: web(),
      app: {
        url: resolveAppUrl(process.env.APP_URL!),
      },
    },
  ],
} satisfies E2EConfig;

// 配置了 AI_API_KEY 才挂载 agent 模型；否则测试文件里的 agent 用例按各自 skip 逻辑跳过
export default process.env.AI_API_KEY
  ? { ...base, agents: { default: { model: buildAgentModel() } } }
  : base;
