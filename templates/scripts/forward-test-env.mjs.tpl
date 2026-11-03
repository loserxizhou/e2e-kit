#!/usr/bin/env node
// 内网测试机本地转发（全操作系统通用，无需管理员权限）。
// e2e 框架对非 loopback 主机强制 HTTPS，本脚本在本机 127.0.0.1 上监听并转发到内网测试机；
// 启动后会把目标登记到 .e2e/forward.json，e2e.config.ts 检测到登记且与 APP_URL 匹配时
// 自动改经 127.0.0.1 接入（约定：监听端口 = 目标端口）。
// 用法：node scripts/forward-test-env.mjs [本机端口] <目标IP> [目标端口]；目标 IP 必填
// 示例：node scripts/forward-test-env.mjs 8010 192.0.2.10 8010（跑测试期间保持运行，Ctrl+C 停止并清除登记）
import net from 'node:net';
import { mkdirSync, writeFileSync, unlinkSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const [listenPortArg, targetHost, targetPortArg] = process.argv.slice(2);
if (!targetHost) {
  console.error('用法：node scripts/forward-test-env.mjs [本机端口] <目标IP> [目标端口]；目标 IP 必填');
  process.exit(1);
}
const listenPort = Number(listenPortArg ?? 8010);
const targetPort = Number(targetPortArg ?? 8010);
const host = targetHost;

const registry = fileURLToPath(new URL('../.e2e/forward.json', import.meta.url));

const server = net.createServer((client) => {
  const upstream = net.connect(targetPort, host);
  client.pipe(upstream);
  upstream.pipe(client);
  client.on('error', () => upstream.destroy());
  upstream.on('error', () => client.destroy());
});

const cleanup = () => {
  try { unlinkSync(registry); } catch { /* 已清除 */ }
};
process.on('SIGINT', () => { cleanup(); process.exit(0); });
process.on('SIGTERM', () => { cleanup(); process.exit(0); });
process.on('exit', cleanup);

server.listen(listenPort, '127.0.0.1', () => {
  mkdirSync(fileURLToPath(new URL('../.e2e', import.meta.url)), { recursive: true });
  writeFileSync(registry, JSON.stringify({ listenPort, targetHost: host, targetPort, pid: process.pid }, null, 2));
  console.log(`e2e 内网测试环境转发已启动: 127.0.0.1:${listenPort} -> ${host}:${targetPort}（Ctrl+C 停止并清除登记）`);
});
