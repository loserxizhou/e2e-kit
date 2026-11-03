# ===== e2e 环境配置模板 =====
# 复制本文件为 .env 后填写；.env 不进 Git。
# 所有配置集中在此，代码无内置默认值：必填项缺失时启动即报错并列出缺失项。

# [必填] 被测前端「应用根」地址，必须以 / 结尾（URL 解析约定，详见 README）
# 本地构建版示例：http://localhost:8888/<应用路径>/
# dev server 示例：http://localhost:4200/
# 局域网测试机场景（非 localhost 主机框架强制 HTTPS）：APP_URL 照实填内网地址，
# 跑测试前 npm run forward -- 8010 <测试机IP> 8010 启动本地转发，
# e2e 配置会自动改经 127.0.0.1 接入（详见 README「配置」节）
APP_URL=http://localhost:4200/

# [必填] 测试账号（auth.setup 用它登录并保存 session 'admin'）
EOFFICE_ADMIN_USER=admin
EOFFICE_ADMIN_PASSWORD=填写测试账号密码

# [选填] 本机测试人员姓名：AI 生成 Excel 用例文档时的默认「创建人」署名；
# 未配置时 AI 会先询问。多人共用机器时以实际创建人为准。
EOFFICE_TESTER_NAME=

# [选填] AI agent 步骤模型；不填 AI_API_KEY 则 agent 用例自动跳过，回归库照常运行。
# 四项配套填写，AI_PROVIDER 二选一：
#   anthropic         —— Anthropic Messages 协议：Claude 官方及兼容网关
#   openai-compatible —— OpenAI 协议：DeepSeek、Kimi、Qwen、本地 Ollama 等
AI_PROVIDER=openai-compatible
AI_BASE_URL=https://api.deepseek.com
AI_MODEL=deepseek-chat
AI_API_KEY=

# ---- 换 Kimi / Qwen / 本地 Ollama 时（示例）----
# AI_PROVIDER=openai-compatible
# AI_BASE_URL=https://api.moonshot.cn/v1      # Kimi
# AI_BASE_URL=https://dashscope.aliyuncs.com/compatible-mode/v1   # 通义千问
# AI_BASE_URL=http://127.0.0.1:11434/v1       # Ollama 本地
