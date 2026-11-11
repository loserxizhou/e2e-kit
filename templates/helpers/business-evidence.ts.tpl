import { randomUUID } from 'node:crypto';

const BUSINESS_STEP_MARKER = '[E2E_BUSINESS_STEP]';

export type BusinessEvidenceMode = 'always' | 'on-failure' | 'none';

export interface BusinessStepOptions {
  id: string;
  action: string;
  expected: string;
  evidence?: BusinessEvidenceMode;
}

interface ScreenshotApp {
  screenshot(label?: string): Promise<string>;
}

interface BusinessStepResult {
  actual?: string;
}

type StepWork = () => string | BusinessStepResult | void | Promise<string | BusinessStepResult | void>;

function emit(payload: Record<string, unknown>): void {
  // Keep this one-line and structured so the Reporter can collect it from the
  // runner's output events. Callers supply only safe, short observations.
  console.log(`${BUSINESS_STEP_MARKER}${JSON.stringify({ schemaVersion: 'business-step-1', ...payload })}`);
}

function actualOf(value: string | BusinessStepResult | void): string {
  const actual = typeof value === 'string' ? value : value?.actual;
  return actual?.trim().slice(0, 500) || '未记录实际观察';
}

async function capture(app: ScreenshotApp, id: string): Promise<string | undefined> {
  try {
    return await app.screenshot(`business-${id}`);
  } catch {
    return undefined;
  }
}

/**
 * Record a human-readable business milestone while preserving the native e2e
 * assertion and failure semantics. The callback owns the actual business
 * checks; this helper only transports the summary and optional screenshot.
 */
export async function businessStep(
  app: ScreenshotApp,
  options: BusinessStepOptions,
  work: StepWork,
): Promise<void> {
  const evidence = options.evidence ?? 'on-failure';
  const startedAt = new Date().toISOString();
  const started = performance.now();
  const step = { eventId: randomUUID(), stepId: options.id.slice(0, 80),
    action: options.action.slice(0, 500), expected: options.expected.slice(0, 500), startedAt };
  emit({ ...step, phase: 'start' });
  try {
    const result = await work();
    const durationMs = Math.round(performance.now() - started);
    const screenshot = evidence === 'always' ? await capture(app, options.id) : undefined;
    emit({
      ...step,
      phase: 'finish',
      status: 'passed',
      actual: actualOf(result),
      durationMs,
      ...(screenshot ? { evidence: [screenshot] } : {}),
    });
  } catch (error) {
    const durationMs = Math.round(performance.now() - started);
    const screenshot = evidence === 'none' ? undefined : await capture(app, options.id);
    emit({
      ...step,
      phase: 'finish',
      status: 'failed',
      actual: '步骤执行异常，详见原生失败信息和 trace',
      durationMs,
      ...(screenshot ? { evidence: [screenshot] } : {}),
    });
    // Keep the native assertion/locator error and stack so the report and
    // trace remain the source of truth for the failure diagnosis.
    throw error;
  }
}
