// 用量与额度领域归一化：保持无运行时依赖，便于服务端单测与其它宿主复用。

/** 额度窗口标签：优先使用 provider 约定名称，未知窗口保持稳定可读。 */
export function usageWindowLabel(seconds) {
  const value = Number(seconds);
  if (!Number.isFinite(value) || value <= 0) return null;
  if (value === 18_000) return '5h';
  if (value === 604_800) return 'weekly';
  if (value === 2_592_000) return 'monthly';
  if (value % 604_800 === 0) return `${value / 604_800}w`;
  if (value % 3_600 === 0) return `${value / 3_600}h`;
  if (value % 60 === 0) return `${value / 60}m`;
  return `${value}s`;
}

function finiteNumber(value) {
  if (value === null || value === undefined || value === '' || typeof value === 'boolean') return undefined;
  const number = typeof value === 'number' ? value : Number(value);
  return Number.isFinite(number) ? number : undefined;
}

function clampPercent(value) {
  const number = finiteNumber(value);
  return number === undefined || number < 0 || number > 100 ? undefined : number;
}

function isoFromUnixSeconds(value) {
  const seconds = finiteNumber(value);
  if (seconds === undefined || seconds <= 0) return undefined;
  const date = new Date(seconds * 1000);
  return Number.isNaN(date.getTime()) ? undefined : date.toISOString();
}

function isoFromDate(value) {
  if (typeof value !== 'string' || value.trim() === '') return undefined;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? undefined : date.toISOString();
}

/** DeepSeek /user/balance 的顶层投影；优先选择 CNY 余额项。 */
export function normalizeDeepSeekBalance(data) {
  const infos = data && typeof data === 'object' && !Array.isArray(data) ? data.balance_infos : undefined;
  const validInfos = Array.isArray(infos) ? infos.filter((item) => item && typeof item === 'object' && !Array.isArray(item)) : [];
  const first = validInfos.find((item) => item.currency === 'CNY') ?? validInfos[0];
  const amount = first ? finiteNumber(first.total_balance) : undefined;
  if (!first || amount === undefined) throw new Error('invalid deepseek balance');
  return {
    amount: String(first.total_balance),
    currency: typeof first.currency === 'string' && first.currency !== '' ? first.currency : 'CNY',
    available: data.is_available !== false && first.is_available !== false,
  };
}

/**
 * dsh-codex-connect 的无密钥投影 → 手机额度领域模型。
 * 保留主 bucket 与 additional_rate_limits 的全部有效窗口，仅返回百分比/金额/窗口，不接触 OAuth token。
 */
export function normalizeCodexUsage(usage) {
  if (!usage || typeof usage !== 'object' || Array.isArray(usage)) throw new Error('invalid codex usage');
  if (usage.rateLimits !== undefined && !Array.isArray(usage.rateLimits)) throw new Error('invalid codex rate limits');
  const rateLimits = (usage.rateLimits ?? []).filter((bucket) => bucket && typeof bucket === 'object' && !Array.isArray(bucket));
  const primaryIndex = rateLimits.findIndex((bucket) => bucket.id === 'codex');
  const orderedBuckets = primaryIndex >= 0
    ? [rateLimits[primaryIndex], ...rateLimits.filter((_, index) => index !== primaryIndex)]
    : rateLimits;
  const windows = [];
  for (const [bucketIndex, bucket] of orderedBuckets.entries()) {
    if (!Array.isArray(bucket.windows)) continue;
    const bucketName = typeof bucket.name === 'string' && bucket.name.trim() !== ''
      ? bucket.name.trim().slice(0, 80)
      : typeof bucket.id === 'string' && bucket.id.trim() !== '' ? bucket.id.trim().slice(0, 80) : undefined;
    const seenInBucket = new Set();
    for (const item of bucket.windows) {
      if (!item || typeof item !== 'object' || Array.isArray(item)) continue;
      const baseWindow = usageWindowLabel(item.windowSeconds);
      const remainingPercent = clampPercent(item.remainingPercent);
      const resetAt = isoFromUnixSeconds(item.resetAt);
      if (!baseWindow || seenInBucket.has(baseWindow) || remainingPercent === undefined) continue;
      seenInBucket.add(baseWindow);
      const window = bucketIndex === 0 || !bucketName ? baseWindow : `${bucketName} · ${baseWindow}`;
      windows.push({ window, remainingPercent, ...(resetAt ? { resetAt } : {}) });
    }
  }
  const individual = usage.individualLimit;
  let individualLimit;
  if (individual && typeof individual === 'object' && !Array.isArray(individual)) {
    const limit = finiteNumber(individual.limit);
    const used = finiteNumber(individual.used);
    const remaining = finiteNumber(individual.remaining);
    const remainingPercent = clampPercent(individual.remainingPercent ?? (limit > 0 && remaining !== undefined ? remaining / limit * 100 : undefined));
    if (limit !== undefined && used !== undefined && remaining !== undefined && limit > 0 && remainingPercent !== undefined) {
      individualLimit = {
        limit: String(individual.limit),
        used: String(individual.used),
        remaining: String(individual.remaining),
        remainingPercent,
      };
    }
  }
  const credits = usage.credits;
  let codexCredits;
  if (credits && typeof credits === 'object' && !Array.isArray(credits) && typeof credits.unlimited === 'boolean') {
    if (credits.unlimited) {
      codexCredits = { unlimited: true };
    } else if (typeof credits.balance === 'string' && credits.balance.trim() !== '') {
      codexCredits = { unlimited: false, balance: credits.balance };
    } else if (finiteNumber(credits.balance) !== undefined) {
      codexCredits = { unlimited: false, balance: String(credits.balance) };
    } else {
      // balance 是可选字段，但 unlimited=false 仍是一个有效、可展示的 Credits 状态。
      codexCredits = { unlimited: false };
    }
  }
  if (windows.length === 0 && individualLimit === undefined && codexCredits === undefined) throw new Error('codex usage has no usable allowance');
  return {
    windows,
    ...(individualLimit ? { individualLimit } : {}),
    ...(codexCredits ? { credits: codexCredits } : {}),
  };
}

/** OpenCode Go usage payload → 剩余百分比窗口；无效窗口单独跳过，限流窗口保留。 */
export function normalizeOpenCodeUsage(payload) {
  const usage = payload && typeof payload === 'object' && !Array.isArray(payload) ? (payload.usage ?? payload) : undefined;
  if (!usage || typeof usage !== 'object' || Array.isArray(usage)) throw new Error('invalid opencode usage');
  const windows = [];
  for (const [key, label] of [['rolling', '5h'], ['weekly', 'weekly'], ['monthly', 'monthly']]) {
    const detail = usage[key];
    if (!detail || typeof detail !== 'object' || Array.isArray(detail)) continue;
    const status = detail.status;
    if (status !== undefined && status !== null && status !== 'ok' && status !== 'rate-limited') continue;
    const usedPercent = clampPercent(detail.percent);
    if (usedPercent === undefined) continue;
    // percent=0 时 OpenCode 返回的是 now+window 占位值，不是可展示的 resetAt。
    const resetAt = usedPercent === 0 ? undefined : isoFromDate(detail.resetsAt);
    windows.push({
      window: label,
      remainingPercent: 100 - usedPercent,
      ...(status === 'rate-limited' ? { limited: true } : {}),
      ...(resetAt ? { resetAt } : {}),
    });
  }
  if (windows.length === 0) throw new Error('opencode usage has no usable windows');
  return { windows };
}
