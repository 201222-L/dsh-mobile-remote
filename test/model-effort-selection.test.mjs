import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { apply } from '../lib/index.js';

const config = {
  path: '/m', authToken: 'test-token-long-enough', cookieName: 'dsh_mobile_token', trustedHosts: [],
  sessionTtlMs: 60000, rechargeUrl: 'https://example.test', maxConnections: 4,
  pushUrls: [], pushCooldownMs: 1000, doneGraceMs: 1000, pushContent: 'minimal',
  rateLimit: {}, lanBridge: { enabled: false }, approvalMode: 'desktop',
};

function harness({ next, lastUsed, defaultSelection, selectError, models, withoutSessionRegistry = false, sessionNotFound = false } = {}) {
  const routes = [];
  const calls = [];
  const created = [];
  const session = { header: { cwd: process.cwd() }, snapshotEvents: () => [] };
  const agents = {
    get: (id) => id === 'existing' ? { id, session } : undefined,
    roots: () => [], list: () => [],
    create: async ({ sessionId, agentOptions }) => {
      const result = { sessionId, agentOptions, disposed: false };
      created.push(result);
      return { agent: { id: sessionId, session }, dispose: async () => { result.disposed = true; } };
    },
  };
  const selection = { lastUsed, next };
  const entries = [
    { id: 'openai-codex', name: 'Codex', models: models ?? [{ id: 'gpt-6-luna', name: 'GPT', reasoning: { efforts: [{ id: 'low', name: 'Low' }, { id: 'high', name: 'High' }], defaultEffort: 'low' } }] },
  ];
  const gateway = {
    async invokeRpc(endpoint, payload) {
      calls.push({ endpoint, args: payload.args });
      if (endpoint === 'session/selectModel' && sessionNotFound) return { ok: false, error: { code: 'session/not-found', message: 'session not found' } };
      if (endpoint === 'session/selectModel' && selectError) return { ok: false, error: { code: 'session/model-unavailable', message: 'invalid model or effort' } };
      if (endpoint === 'session/modelCatalog') return { ok: true, value: { groups: entries, default: defaultSelection } };
      return { ok: true, value: {} };
    },
    async stream() {
      return (async function* () {
        yield { type: 'baseline', value: { projections: { existing: { values: { modelSelection: selection } } } } };
      })();
    },
  };
  const services = new Map([
    ['agents', agents], ['sessions', { get: id => !withoutSessionRegistry && id === 'existing' ? session : undefined }],
    ['llm', { listProviders: async () => [], listConfigurableProviders: async () => [], resolveModelInfo: async () => ({ inputModalities: [] }) }],
    ['typertGateway', gateway],
  ]);
  const ctx = {
    webServer: { host: '127.0.0.1', port: 3080, register(route) { routes.push(route); return () => {}; } },
    logger: { info() {}, warn() {}, error() {} },
    get: name => services.get(name), provide: (name, value) => services.set(name, value),
    on: () => () => {}, effect: cb => { const d = cb?.(); return typeof d === 'function' ? d : () => {}; },
    inject() {}, waterfall: async () => 'unavailable',
  };
  const dispose = apply(ctx, config);
  const route = routes.find(r => r.path === '/m/api').handler;
  return { route, calls, created, entries, dispose };
}

async function request(route, path, body) {
  const req = new EventEmitter();
  req.url = path; req.method = body === undefined ? 'GET' : 'POST';
  req.headers = { host: '127.0.0.1', 'x-mobile-token': config.authToken, 'content-type': 'application/json' };
  req.socket = { remoteAddress: '127.0.0.1' };
  const res = new EventEmitter();
  let text = '';
  res.headersSent = false;
  res.writeHead = status => { res.statusCode = status; res.headersSent = true; };
  res.write = value => { text += value; return true; };
  res.end = value => { if (value) text += value; res.emit('finish'); };
  res.destroy = () => res.emit('close');
  const done = new Promise(resolve => res.once('finish', resolve));
  route(req, res);
  if (body !== undefined) queueMicrotask(() => {
    req.emit('data', Buffer.from(JSON.stringify(body))); req.emit('end');
  });
  await done;
  return { status: res.statusCode, body: JSON.parse(text || '{}') };
}

test('只改 effort 保持当前待生效的 Codex 模型，不退回 DeepSeek 或 lastUsed', async () => {
  const h = harness({ next: { provider: 'openai-codex', model: 'gpt-6-luna', reasoningEffort: 'low' }, lastUsed: { provider: 'deepseek-official', model: 'deepseek-flash' } });
  try {
    const before = await request(h.route, '/m/api/session-config?sessionId=existing');
    assert.equal(before.body.config.provider, 'openai-codex');
    assert.equal(before.body.config.model, 'gpt-6-luna');
    const result = await request(h.route, '/m/api/session-config', { sessionId: 'existing', reasoningEffort: 'high' });
    assert.equal(result.status, 200);
    assert.deepEqual(h.calls.find(c => c.endpoint === 'session/selectModel')?.args.request, {
      sessionId: 'existing', provider: 'openai-codex', model: 'gpt-6-luna', reasoningEffort: 'high',
    });
  } finally { h.dispose?.(); }
});

test('持久化会话不在本地 sessions map 时仍通过内核选择 effort', async () => {
  const h = harness({ withoutSessionRegistry: true, next: { provider: 'openai-codex', model: 'gpt-6-luna', reasoningEffort: 'low' } });
  try {
    const result = await request(h.route, '/m/api/session-config', { sessionId: 'existing', reasoningEffort: 'high' });
    assert.equal(result.status, 200);
    assert.equal(h.calls.some(c => c.endpoint === 'session/selectModel'), true);
  } finally { h.dispose?.(); }
});

test('内核确认会话不存在时仍返回 session-not-found', async () => {
  const h = harness({ withoutSessionRegistry: true, sessionNotFound: true });
  try {
    const result = await request(h.route, '/m/api/session-config', {
      sessionId: 'missing', provider: 'openai-codex', model: 'gpt-6-luna',
    });
    assert.equal(result.status, 404);
    assert.equal(result.body.error, 'session-not-found');
    assert.equal(h.calls.some(c => c.endpoint === 'session/selectModel'), true);
  } finally { h.dispose?.(); }
});

test('休眠会话缺失本地对象时仍拒绝无法应用的权限修改', async () => {
  const h = harness({ withoutSessionRegistry: true });
  try {
    const result = await request(h.route, '/m/api/session-config', {
      sessionId: 'existing', permissionPreset: 'workspace-write',
    });
    assert.equal(result.status, 404);
    assert.equal(h.calls.some(c => c.endpoint === 'session/selectModel'), false);
  } finally { h.dispose?.(); }
});

test('只有 lastUsed 而没有 next 时，不猜测旧模型', async () => {
  const h = harness({ lastUsed: { provider: 'openai-codex', model: 'gpt-6-luna' } });
  try {
    const result = await request(h.route, '/m/api/session-config', { sessionId: 'existing', reasoningEffort: 'high' });
    assert.equal(result.status, 409);
    assert.equal(h.calls.some(c => c.endpoint === 'session/selectModel'), false);
  } finally { h.dispose?.(); }
});

test('模型目录保留每模型可选 effort 与默认 effort', async () => {
  const h = harness();
  try {
    const result = await request(h.route, '/m/api/catalog');
    assert.equal(result.status, 200);
    assert.deepEqual(result.body.reasoningEfforts, ['low', 'high']); // 兼容旧字段，不作为当前模型能力
    assert.deepEqual(result.body.models.find(m => m.id === 'gpt-6-luna')?.reasoning, {
      efforts: [{ id: 'low', name: 'Low' }, { id: 'high', name: 'High' }], defaultEffort: 'low',
    });
  } finally { h.dispose?.(); }
});

test('强制刷新目录绕过十五秒缓存，呈现最新强度能力', async () => {
  const h = harness();
  try {
    await request(h.route, '/m/api/catalog');
    h.entries[0].models[0].reasoning = { efforts: [{ id: 'off', name: 'Off' }], defaultEffort: 'off' };
    const cached = await request(h.route, '/m/api/catalog');
    assert.equal(cached.body.models[0].reasoning.defaultEffort, 'low');
    const fresh = await request(h.route, '/m/api/catalog?refresh=1');
    assert.equal(fresh.body.models[0].reasoning.defaultEffort, 'off');
  } finally { h.dispose?.(); }
});

test('切换模型与恢复默认强度不继承上一个模型的 effort', async () => {
  const h = harness({ next: { provider: 'openai-codex', model: 'gpt-6-luna', reasoningEffort: 'high' } });
  try {
    const switched = await request(h.route, '/m/api/session-config', { sessionId: 'existing', provider: 'other', model: 'other-model' });
    assert.equal(switched.status, 200);
    assert.deepEqual(h.calls.at(-1).args.request, { sessionId: 'existing', provider: 'other', model: 'other-model' });
    const reset = await request(h.route, '/m/api/session-config', { sessionId: 'existing', resetReasoningEffort: true });
    assert.equal(reset.status, 200);
    assert.deepEqual(h.calls.at(-1).args.request, { sessionId: 'existing', provider: 'openai-codex', model: 'gpt-6-luna' });
  } finally { h.dispose?.(); }
});

test('未选模型的新会话使用部署默认模型，不借用其他会话', async () => {
  const h = harness({ defaultSelection: { provider: 'openai-codex', model: 'gpt-6-luna', reasoningEffort: 'high' }, next: { provider: 'other', model: 'old-model', reasoningEffort: 'max' } });
  try {
    const result = await request(h.route, '/m/api/sessions', { preset: 'standard' });
    assert.equal(result.status, 200);
    assert.deepEqual(h.created[0].agentOptions, { provider: 'openai-codex', model: 'gpt-6-luna' });
    assert.deepEqual(h.calls.find(c => c.endpoint === 'session/selectModel')?.args.request, {
      sessionId: result.body.sessionId, provider: 'openai-codex', model: 'gpt-6-luna', reasoningEffort: 'high',
    });
  } finally { h.dispose?.(); }
});

test('模型身份必须完整，无部署默认时拒绝创建且不留会话', async () => {
  const h = harness();
  try {
    const missingProvider = await request(h.route, '/m/api/sessions', { preset: 'standard', model: 'gpt-6-luna' });
    assert.equal(missingProvider.status, 400);
    const noDefault = await request(h.route, '/m/api/sessions', { preset: 'standard' });
    assert.equal(noDefault.status, 400);
    assert.equal(noDefault.body.error, 'no-model-available');
    assert.equal(h.created.length, 0);
  } finally { h.dispose?.(); }
});

test('显式无效 effort 被内核拒绝时不静默降级', async () => {
  const h = harness({ next: { provider: 'openai-codex', model: 'gpt-6-luna' }, selectError: true });
  try {
    const result = await request(h.route, '/m/api/session-config', { sessionId: 'existing', reasoningEffort: 'stale' });
    assert.equal(result.status, 400);
    assert.equal(result.body.error, 'session/model-unavailable');
    assert.equal(h.calls.at(-1).args.request.reasoningEffort, 'stale');
  } finally { h.dispose?.(); }
});

test('新建会话模型选择失败时返回错误且清理会话', async () => {
  const h = harness({ selectError: true });
  try {
    const result = await request(h.route, '/m/api/sessions', { preset: 'standard', provider: 'openai-codex', model: 'gpt-6-luna' });
    assert.notEqual(result.status, 200);
    assert.equal(h.created.length, 1);
    assert.equal(h.created[0].disposed, true);
  } finally { h.dispose?.(); }
});
