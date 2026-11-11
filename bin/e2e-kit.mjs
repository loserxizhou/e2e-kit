#!/usr/bin/env node
// e2e-kit 命令行入口：init / upgrade / doctor / mcp / version。

import { runInit, help as initHelp } from './init.mjs';
import { runUpgrade, help as upgradeHelp } from './upgrade.mjs';
import { runDoctor } from './doctor.mjs';
import { kitVersion } from './lib/kit.mjs';

const version = kitVersion();

const USAGE = `e2e-kit v${version} — e2e 测试的项目初始化工具

用法:
  e2e-kit init [选项]     初始化/体检项目，并接入指定客户端（--client）
  e2e-kit upgrade [选项]  选择 safe/adopt 后迁移项目框架文件（默认不刷新 Skill）
  e2e-kit doctor [选项]   体检当前项目（不改文件）
  e2e-kit mcp [选项]      MCP 包装器：定位项目并启动 e2e mcp
  e2e-kit version         打印版本
  e2e-kit help            显示本帮助

常用:
  e2e-kit init --client codex
  e2e-kit init --client codex --url http://localhost:4200/ --user admin --yes
  e2e-kit upgrade
  e2e-kit doctor
`;

async function main() {
  const [command, ...rest] = process.argv.slice(2);

  if (!command || command === 'help' || command === '--help' || command === '-h') {
    console.log(USAGE);
    return 0;
  }
  if (command === 'version' || command === '--version' || command === '-v') {
    console.log(version);
    return 0;
  }
  if (command === 'init') {
    if (rest.includes('--help') || rest.includes('-h')) {
      console.log(initHelp());
      return 0;
    }
    return runInit(rest);
  }
  if (command === 'upgrade') {
    if (rest.includes('--help') || rest.includes('-h')) {
      console.log(upgradeHelp());
      return 0;
    }
    return await runUpgrade(rest);
  }
  if (command === 'doctor') {
    return runDoctor(rest);
  }
  if (command === 'mcp') {
    // 直接复用包装器：保持单一实现
    await import('./e2e-mcp.mjs');
    return 0;
  }

  console.error(`未知命令：${command}\n\n${USAGE}`);
  return 2;
}

main()
  .then((code) => {
    if (typeof code === 'number') process.exitCode = code;
  })
  .catch((err) => {
    console.error(err?.stack || String(err));
    process.exitCode = 1;
  });
