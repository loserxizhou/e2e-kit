#!/usr/bin/env bash
# e2e-kit 一键引导：拿到 kit → 装 skill + MCP → 初始化当前项目。
#
# 用法（本地已克隆，推荐）：
#   git clone https://github.com/loserxizhou/eoffice-e2e.git
#   cd <目标项目> && bash <克隆目录>/run.sh        # 客户端自动探测（Codex/Claude/Cursor）
#   bash <克隆目录>/run.sh --client workbuddy,zcode # 显式指定：workbuddy/zcode/dsh 探测不到
#   bash <克隆目录>/run.sh --project /path/to/repo
#
# 用法（远程一行，首次试用）：
#   bash <(curl -fsSL https://raw.githubusercontent.com/loserxizhou/eoffice-e2e/main/run.sh)
#
# 升级已有项目的 e2e 框架文件（不覆盖手改文件）：
#   node <克隆目录>/bin/e2e-kit.mjs upgrade --project /path/to/repo
#
# 可选：
#   --update              强制重新拉取 kit（默认：本地有 kit 就直接用）
#   --project <dir>       目标项目（默认当前目录）
#   --client <name>       claude / codex / cursor / workbuddy / zcode / dsh，逗号分隔；省略则自动探测
#   其余参数原样传给 e2e-kit init（如 --url、--user、--yes）

set -euo pipefail

REPO_URL="https://github.com/loserxizhou/eoffice-e2e.git"
RAW_RUN_SH="https://raw.githubusercontent.com/loserxizhou/eoffice-e2e/main/run.sh"
KIT_HOME="${E2E_KIT_HOME:-$HOME/.e2e-kit}"
E2E_KIT_URL="${E2E_KIT_URL:-$REPO_URL}"

CLIENT=""
PROJECT="."
UPDATE=0
PASSTHRU=()

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --client) CLIENT="${2:-}"; shift 2 ;;
    --client=*) CLIENT="${1#*=}"; shift ;;
    --project) PROJECT="${2:-}"; shift 2 ;;
    --project=*) PROJECT="${1#*=}"; shift ;;
    --update) UPDATE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) PASSTHRU+=("$1"); shift ;;
  esac
done

say() { printf '%s\n' "$*"; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }

# 1. Node 版本
command -v node >/dev/null 2>&1 || die "未找到 node。请安装 Node >= 22.22.3。"
node -e 'const [a,b,c]=process.versions.node.split(".").map(Number);process.exit(a>22||(a===22&&(b>22||(b===22&&c>=3)))?0:1)' \
  || die "Node 版本过低：$(node -v)，需要 >= 22.22.3。可先切版本再试：nvm install 24 && nvm use 24（长期用：nvm alias default 24）"

# 2. 定位或下载 kit
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
KIT_DIR=""
if [ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/bin/e2e-kit.mjs" ]; then
  KIT_DIR="$SRC_DIR"
elif [ -f "$KIT_HOME/bin/e2e-kit.mjs" ] && [ "$UPDATE" -eq 0 ]; then
  KIT_DIR="$KIT_HOME"
else
  say "未找到本地 kit，拉取：$E2E_KIT_URL → $KIT_HOME"
  rm -rf "$KIT_HOME"
  if command -v git >/dev/null 2>&1 && git clone --depth 1 "$E2E_KIT_URL" "$KIT_HOME" 2>/dev/null; then
    :
  else
    die "拉取失败：$E2E_KIT_URL（也可手动 git clone 后运行 bash <克隆目录>/run.sh）"
  fi
  KIT_DIR="$KIT_HOME"
fi

# 3. 没指定客户端时自动探测（只探测会写项目内配置的三家）
if [ -z "$CLIENT" ]; then
  detected=""
  [ -d "$HOME/.codex" ] && detected="${detected}${detected:+,}codex"
  [ -d "$HOME/.claude" ] && detected="${detected}${detected:+,}claude"
  [ -d "$HOME/.cursor" ] && detected="${detected}${detected:+,}cursor"
  CLIENT="$detected"
  [ -n "$CLIENT" ] && say "检测到客户端：$CLIENT"
fi

# 4. 执行 init（幂等：重复跑只补缺）
args=(init --project "$PROJECT")
[ -n "$CLIENT" ] && args+=(--client "$CLIENT")
if [ ${#PASSTHRU[@]} -gt 0 ]; then
  args+=("${PASSTHRU[@]}")
fi

say "e2e-kit：$KIT_DIR"
exec node "$KIT_DIR/bin/e2e-kit.mjs" "${args[@]}"
