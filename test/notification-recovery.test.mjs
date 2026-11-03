import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { apply } from '../lib/index.js';

class Request extends EventEmitter {
  constructor(path, method = 'GET', token = '0123456789abcdef') {
    super(); this.url = path; this.method = method; this.complete = true;
    this.headers = { host: '127.0.0.1', 'x-mobile-token': token, 'content-type': 'application/json' };
    this.socket = { remoteAddress: '127.0.0.1' };
  }
}
class Response extends EventEmitter {
  constructor() { super(); this.chunks = []; }
  writeHead(code) { this.statusCode = code; this.headersSent = true; }
  write(chunk) { this.chunks.push(String(chunk)); return true; }
  end(chunk = '') { this.chunks.push(String(chunk)); this.emit('finish'); }
  destroy() { this.emit('close'); }
  frames() { return this.chunks.flatMap(s => s.split('\n').filter(l => l.startsWith('data: ')).map(l => JSON.parse(l.slice(6)))); }
}
function harness(t) {
  const handlers = new Map(), routes = [];
  const session = { id: 's', title: 'Task', header: { title: 'Task' } };
  const services = new Map([['sessions', new Map([['s', session]])]]);
  const ctx = {
    webServer: { host: '127.0.0.1', port: 43441, register(route) { routes.push(route); return () => {}; } },
    get: key => services.get(key), provide: (key, value) => services.set(key, value),
    logger: { info() {}, warn() {} }, inject() {}, waterfall: async () => 'unavailable',
    effect: callback => callback(), on: (name, callback) => { handlers.set(name, callback); return () => {}; },
  };
  const dispose = apply(ctx, { path: '/m', authToken: '0123456789abcdef', cookieName: 'dsh_mobile_token',
    maxConnections: 5, trustedHosts: [], pushUrls: [], pushCooldownMs: 0, doneGraceMs: 1,
    rateLimit: {}, lanBridge: { enabled: false }, approvalMode: 'both',
    pendingTimeoutMs: 60_000, offlineHoldMs: 60_000, pushApprovalGraceMs: 0, warmUpOnStart: false });
  t.after(() => dispose?.());
  const route = routes.find(r => r.path === '/m/api').handler;
  const call = async (path, method, body, token) => {
    const req = new Request(path, method, token), res = new Response();
    const done = new Promise(resolve => res.once('finish', resolve)); route(req, res);
    if (body !== undefined) queueMicrotask(() => { req.emit('data', Buffer.from(JSON.stringify(body))); req.emit('end'); });
    await done;
    return { code: res.statusCode, body: JSON.parse(res.chunks.join('') || '{}') };
  };
  return { route, call, handlers };
}

test('reconnect snapshot follows replay and excludes approvals already answered on another client', async t => {
  const h = harness(t);
  const pending = h.handlers.get('approval/request')({ agent: { session: { id: 's' } },
    callId: 'call', toolName: 'write' }, async () => new Promise(() => {}));
  await new Promise(resolve => setImmediate(resolve));
  const stream = new Response(); h.route(new Request('/m/api/events'), stream);
  const frames = stream.frames();
  const requested = frames.findIndex(f => f.type === 'mobile/frame' && f.frame.type === 'approval/requested');
  const snapshot = frames.findIndex(f => f.type === 'attention/snapshot');
  assert.ok(requested >= 0 && snapshot > requested);
  assert.deepEqual(frames[snapshot].pending, [{ kind: 'approval', identity: 's:call', sessionId: 's' }]);
  stream.destroy(); // Page/phone may disappear; host keeps the pending interaction.
  const answer = await h.call('/m/api/respond', 'POST', { kind: 'approval', sessionId: 's', rpcId: 's:call', outcome: 'allowed-once' });
  assert.equal(answer.code, 200); assert.equal(await pending, 'allowed-once');
  const next = new Response(); h.route(new Request('/m/api/events'), next);
  assert.deepEqual(next.frames().find(f => f.type === 'attention/snapshot').pending, []);
  next.destroy();
});

test('update mutations retain authentication and confirmation; health exposes only local version', async t => {
  const h = harness(t);
  assert.equal((await h.call('/m/api/release-update/status', 'GET', undefined, 'wrong')).code, 401);
  const status = await h.call('/m/api/release-update/status');
  assert.equal(status.code, 200); assert.equal(status.body.source, 'github');
  assert.equal((await h.call('/m/api/release-update/stage', 'POST', {})).body.error, 'update-confirmation-required');
  const health = await h.call('/m/api/release-update/health', 'GET', undefined, '');
  assert.equal(health.code, 200);
  assert.deepEqual(Object.keys(health.body).sort(), ['ok', 'plugin']);
  const req = new Request('/m/api/release-update/health'); req.socket.remoteAddress = '192.168.1.30';
  const response = new Response(); const done = new Promise(resolve => response.once('finish', resolve));
  h.route(req, response); await done;
  assert.equal(response.statusCode, 403);
});
