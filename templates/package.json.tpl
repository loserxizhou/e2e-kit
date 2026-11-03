{
  "name": "eoffice-e2e",
  "private": true,
  "eofficeWorkflowVersion": "0.3.0",
  "type": "module",
  "scripts": {
    "test:run": "node scripts/run.mjs",
    "test:scope": "node scripts/check-scope.mjs",
    "test:cases": "node scripts/cases.mjs",
    "check:core": "node --test scripts/tests/*.test.mjs",
    "check:types": "tsc --noEmit",
    "test:e2e": "node scripts/run.mjs --headed",
    "test:e2e:headless": "node scripts/run.mjs",
    "sync": "node scripts/sync-local.mjs",
    "mcp": "node scripts/mcp.mjs",
    "forward": "node scripts/forward-test-env.mjs"
  },
  "devDependencies": {
    "@ai-sdk/anthropic": "^4.0.80",
    "@ai-sdk/openai-compatible": "^3.0.70",
    "@e2e-dev/web": "{{WEB_VERSION}}",
    "@types/node": "24.19.2",
    "ai": "^7.0.0",
    "e2e": "{{E2E_VERSION}}",
    "typescript": "7.0.2",
    "zod": "^4.1.8"
  },
  "engines": {
    "node": "^22.22.3 || >=24.8.0"
  }
}
