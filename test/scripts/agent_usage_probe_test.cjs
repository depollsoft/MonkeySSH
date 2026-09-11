const {test} = require('node:test');
const assert = require('node:assert/strict');
const {codexUsage, copilotUsage, claudeUsage, rpc} = require('../../assets/scripts/agent_usage_probe.cjs');

test('Claude and Cursor environment tokens bypass malformed and unreadable stores', async () => {
  const fs = require('fs'), os = require('os'), path = require('path');
  const {claude, cursor} = require('../../assets/scripts/agent_usage_probe.cjs');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'usage-override-'));
  const keys = ['CLAUDE_CONFIG_DIR', 'CLAUDE_CODE_OAUTH_TOKEN', 'CURSOR_AUTH_TOKEN', 'APPDATA', 'XDG_CONFIG_HOME'];
  const saved = Object.fromEntries(keys.map(k => [k, process.env[k]]));
  const homedir = os.homedir;
  try {
    os.homedir = () => dir;
    process.env.CLAUDE_CONFIG_DIR = dir;
    process.env.APPDATA = process.env.XDG_CONFIG_HOME = dir;
    process.env.CLAUDE_CODE_OAUTH_TOKEN = 'CLAUDE_OVERRIDE';
    process.env.CURSOR_AUTH_TOKEN = 'CURSOR_OVERRIDE';
    const cursorDir = path.join(dir, process.platform === 'darwin' ? '.cursor' : process.platform === 'win32' ? 'Cursor' : 'cursor');
    fs.mkdirSync(cursorDir);
    const files = [path.join(dir, '.credentials.json'), path.join(cursorDir, 'auth.json')];
    for (const invalid of ['malformed', 'unreadable']) {
      for (const file of files) {
        fs.rmSync(file, {force:true,recursive:true});
        if (invalid === 'malformed') fs.writeFileSync(file, '{'); else fs.mkdirSync(file);
      }
      const c = await claude(async (_, options) => {
        assert.equal(options.token, 'CLAUDE_OVERRIDE');
        return {five_hour:{utilization:25}};
      });
      assert.equal(c.windows[0].usedPercent, 25);
      const r = await cursor(async (_, options) => {
        assert.equal(options.token, 'CURSOR_OVERRIDE');
        return {};
      });
      assert.equal(r.windows[0].restricted, false);
    }
  } finally {
    os.homedir = homedir;
    for (const k of keys) saved[k] == null ? delete process.env[k] : process.env[k] = saved[k];
    fs.rmSync(dir, {recursive:true,force:true});
  }
});

test('Hermes copilot pool entries use GitHub quota and its provider label', async () => {
  const fs = require('fs'), os = require('os'), path = require('path');
  const {configuredAccounts, multiProvider, providerUsage} = require('../../assets/scripts/agent_usage_probe.cjs');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'usage-hermes-copilot-'));
  const previous = process.env.HERMES_HOME;
  try {
    process.env.HERMES_HOME = dir;
    fs.writeFileSync(path.join(dir, 'auth.json'), JSON.stringify({credential_pool:{copilot:[{access_token:'ghu_FIXTURE'}]}}));
    const result = await multiProvider('hermes', configuredAccounts('hermes'), (id, c) => providerUsage(id, c, async (url, options) => {
      assert.equal(url, 'https://api.github.com/copilot_internal/user');
      assert.equal(options.token, 'ghu_FIXTURE');
      return {quota_snapshots:{premium_interactions:{percent_remaining:75,entitlement:300,remaining:225}}};
    }));
    assert.equal(result.status, 'available');
    assert.match(result.windows[0].label, /^GitHub Copilot/);
    assert.equal(result.windows[0].usedPercent, 25);
  } finally {
    previous == null ? delete process.env.HERMES_HOME : process.env.HERMES_HOME = previous;
    fs.rmSync(dir, {recursive:true,force:true});
  }
});

test('Codex uses all buckets without duplicating the legacy bucket', () => {
  const bucket = {primary: {usedPercent: 40, windowDurationMins: 300, resetsAt: 1800000000}};
  const result = codexUsage({rateLimits: bucket, rateLimitsByLimitId: {
    codex: bucket, review: {secondary: {usedPercent: 20, windowDurationMins: 10080}},
  }, rateLimitResetCredits: {availableCount: 2}});
  assert.equal(result.windows.length, 2);
  assert.equal(result.windows[0].label, '5 hours');
  assert.equal(result.windows[0].resetsAt, '2027-01-15T08:00:00.000Z');
  assert.equal(result.resetCredits, 2);
});

test('Copilot distinguishes exhausted, unlimited, missing, and paid overage', () => {
  const result = copilotUsage({quotaSnapshots: {
    premium_interactions: {remainingPercentage: 0, usedRequests: 300,
      entitlementRequests: 300, overageAllowedWithExhaustedQuota: true,
      resetDate: '2026-10-01T00:00:00Z'},
    chat: {isUnlimitedEntitlement: true, entitlementRequests: -1},
    unknown: {},
  }});
  assert.equal(result.windows.length, 2);
  assert.equal(result.windows[0].usedPercent, 100);
  assert.equal(result.windows[0].overageAllowed, true);
  assert.equal(result.windows[1].unlimited, true);
  assert.equal(result.windows[1].usedPercent, null);
  assert.equal(result.windows[1].limit, null);
});

test('Claude accepts zero utilization and ignores account fields', () => {
  const result = claudeUsage({five_hour: {utilization: 0, resets_at: 'bad'},
    seven_day: {utilization: 98.5, resets_at: '2026-09-13T00:00:00Z'},
    seven_day_opus: null, accessToken: 'SECRET'});
  assert.equal(result.windows.length, 2);
  assert.equal(result.windows[0].usedPercent, 0);
  assert.equal(result.windows[0].resetsAt, null);
  assert.ok(!JSON.stringify(result).includes('SECRET'));
});

for (const framed of [true, false]) {
  test(`RPC supports fragmented ${framed ? 'Content-Length' : 'JSONL'} responses`, async () => {
    const source = `process.stdin.once('data', () => {
      const body = JSON.stringify({jsonrpc:'2.0', id:2, result:{ok:true}});
      const wire = ${framed} ? 'Content-Length: '+Buffer.byteLength(body)+'\\r\\n\\r\\n'+body : body+'\\n';
      process.stdout.write(wire.slice(0, 8));
      setTimeout(() => process.stdout.write(wire.slice(8)), 10);
    });`;
    assert.deepEqual(await rpc(process.execPath, ['-e', source], 'account.getQuota', framed, false), {ok: true});
  });
}

for (const framed of [false, true]) {
  test(`RPC drains final ${framed ? 'Content-Length' : 'JSONL'} response after process exit`, async t => {
    const {EventEmitter} = require('node:events');
    const {PassThrough} = require('node:stream');
    const child = new EventEmitter();
    child.stdin = new PassThrough();
    child.stdout = new PassThrough();
    t.mock.method(require('node:child_process'), 'spawn', () => {
      queueMicrotask(() => {
        child.emit('exit', 0);
        const body = JSON.stringify({id: 2, result: {ok: true}});
        child.stdout.end(framed ? `Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}` : body + '\n');
        child.emit('close', 0);
      });
      return child;
    });
    assert.deepEqual(await rpc('agent', [], 'account/get', framed, false), {ok: true});
  });
}

test('RPC rejects a closed process without a response', async t => {
  const {EventEmitter} = require('node:events');
  const {PassThrough} = require('node:stream');
  const child = new EventEmitter();
  child.stdin = new PassThrough();
  child.stdout = new PassThrough();
  t.mock.method(require('node:child_process'), 'spawn', () => {
    queueMicrotask(() => {
      child.emit('exit', 0);
      child.stdout.end();
      child.emit('close', 0);
    });
    return child;
  });
  await assert.rejects(rpc('agent', [], 'account/get', false, false), /unavailable/);
});

test('RPC errors do not propagate provider error text', async () => {
  const source = `process.stdin.once('data', () => process.stdout.write(JSON.stringify({id:2,error:{message:'SECRET'}})+'\\n'));`;
  await assert.rejects(rpc(process.execPath, ['-e', source], 'account/get', false, false),
    error => error.message === 'unavailable');
});


test('encoded SSH bootstrap returns only normalized data and handles initialization', async () => {
  const fs = require('fs');
  const os = require('os');
  const path = require('path');
  const cp = require('child_process');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'monkeyssh-usage-test-'));
  try {
    const executable = path.join(dir, "codex quote ' fixture");
    fs.writeFileSync(executable, `#!/usr/bin/env node
      const readline = require('readline');
      readline.createInterface({input: process.stdin}).on('line', line => {
        const request = JSON.parse(line);
        if (!request.id) return;
        const result = request.id === 1 ? {} : {rateLimits: {primary: {
          usedPercent: 42, windowDurationMins: 300, resetsAt: 1800000000}},
          accessToken: 'SECRET'};
        process.stdout.write(JSON.stringify({id:request.id,result})+'\\n');
      });`, {mode: 0o700});
    const script = fs.readFileSync(path.join(__dirname, '../../assets/scripts/agent_usage_probe.cjs'));
    const bootstrap = "process.env.MONKEYSSH_USAGE_PROBE='1';eval(Buffer.from('" +
      script.toString('base64') + "','base64').toString())";
    const input = Buffer.from(JSON.stringify({codex: executable})).toString('base64');
    const result = cp.spawnSync(process.execPath, ['-e', bootstrap, input], {encoding: 'utf8', timeout: 15000});
    assert.equal(result.status, 0);
    assert.ok(result.stdout.startsWith('__monkeyssh_usage__='));
    assert.ok(!result.stdout.includes('SECRET'));
    assert.equal(JSON.parse(result.stdout.split('=')[1]).windows[0].usedPercent, 42);
  } finally { fs.rmSync(dir, {recursive: true, force: true}); }
});

const {grokUsage, cursorUsage, antigravityUsage, openclawUsage, codexOAuthUsage,
  copilotOAuthUsage, openrouterUsage, nousUsage, multiProvider, configuredAccounts} = require('../../assets/scripts/agent_usage_probe.cjs');

test('Grok prefers current credits and keeps on-demand and prepaid separate', () => {
  const r = grokUsage({config: {creditUsagePercent: 42.5,
    currentPeriod: {end: '2026-10-01T00:00:00Z'}, monthlyLimit: {val: 10000}, used: {val: 2000},
    onDemandCap: {val: 5000}, onDemandUsed: {}, prepaidBalance: {val: 1234}}});
  assert.equal(r.windows.length, 3);
  assert.equal(r.windows[0].usedPercent, 42.5);
  assert.equal(r.windows[0].resetsAt, '2026-10-01T00:00:00.000Z');
  assert.equal(r.windows[1].usedPercent, 0);
  assert.equal(r.windows[2].remaining, 12.34);
  assert.equal(r.windows[2].unit, 'USD');
  assert.equal(grokUsage({config: {monthlyLimit: {val: 0}, used: {val: 12}}}).windows.length, 0);
});

test('Cursor reports a restriction without inventing a percentage', () => {
  const r = cursorUsage({isInSlowPool: true, resetAtMs: '1800000000000', errorDetail: 'SECRET'});
  assert.equal(r.windows[0].restricted, true);
  assert.equal(r.windows[0].usedPercent, undefined);
  assert.equal(r.windows[0].resetsAt, '2027-01-15T08:00:00.000Z');
  assert.ok(!JSON.stringify(r).includes('SECRET'));
  assert.equal(cursorUsage({}).windows[0].restricted, false);
});

test('Antigravity includes every group and excludes unknown or disabled amounts', () => {
  const r = antigravityUsage({summary: {groups: [{displayName: 'Fast', buckets: [
    {displayName: 'Weekly', remainingFraction: 0, resetTime: '2026-10-01T00:00:00Z'},
    {displayName: 'Daily', remainingFraction: 1}, {remainingFraction: .5, disabled: true}, {},
  ]}, {displayName: 'Pro', buckets: [{remainingFraction: .25}]}]}});
  assert.deepEqual(r.windows.map(w => w.usedPercent), [100, 0, 75]);
  assert.equal(r.windows[0].resetsAt, '2026-10-01T00:00:00.000Z');
  assert.equal(antigravityUsage({buckets: [{modelId: 'gemini', remainingFraction: .5}]}).windows[0].usedPercent, 50);
});

test('OpenClaw preserves provider failures alongside successful usage', () => {
  const r = openclawUsage({usage: {providers: [
    {provider: 'anthropic', windows: [{label: 'Weekly', usedPercent: 80, resetAt: 1800000000000}], accountEmail: 'SECRET'},
    {provider: 'openai-codex', windows: [], error: 'SECRET'},
    {provider: 'openrouter', billing: [{type: 'balance', amount: 9.25, unit: 'USD'}]},
  ]}});
  assert.equal(r.status, 'available');
  assert.equal(r.windows.length, 2);
  assert.equal(r.windows[0].resetsAt, '2027-01-15T08:00:00.000Z');
  assert.deepEqual(r.notices, [{provider: 'OpenAI Codex', status: 'unavailable'}]);
  assert.ok(!JSON.stringify(r).includes('SECRET'));
  assert.equal(openclawUsage({}).status, 'unavailable');
  assert.equal(openclawUsage({usage: {providers: [], refreshing: true}}).status, 'unavailable');
});

test('multi-provider OAuth schemas retain all limits and reset dates', () => {
  const r = codexOAuthUsage({rate_limit: {primary_window: {used_percent: 20, limit_window_seconds: 18000, reset_at: 1800000000}},
    additional_rate_limits: [{limit_name: 'Review', rate_limit: {secondary_window: {used_percent: 100, limit_window_seconds: 604800}}}]});
  assert.equal(r.windows.length, 2);
  assert.equal(r.windows[0].label, '5 hours');
  assert.equal(r.windows[1].usedPercent, 100);
  const c = copilotOAuthUsage({quota_reset_date: '2026-10-01', quota_snapshots: {
    premium_interactions: {percent_remaining: 25, remaining: 75, entitlement: 300}, chat: {unlimited: true},
  }});
  assert.equal(c.windows[0].used, 225);
  assert.equal(c.windows[0].usedPercent, 75);
  assert.equal(c.windows[1].unlimited, true);
});

test('OpenRouter and Nous expose balances without inventing allowances', () => {
  assert.equal(openrouterUsage({data: {limit: null, usage: 50}}).status, 'notReported');
  assert.equal(openrouterUsage({data: {limit: 100, usage: 12}}).windows[0].usedPercent, 12);
  assert.equal(openrouterUsage({data: {limit_remaining: 9}}).windows[0].remaining, 9);
  const r = nousUsage({subscription: {monthly_credits: 100, credits_remaining: 125},
    paid_service_access: {purchased_credits_remaining: 4, member_spend_cap_usd: 50, member_spend_usd: 10}});
  assert.equal(r.windows[0].remaining, 125);
  assert.equal(r.windows[0].usedPercent, undefined);
  assert.equal(r.windows[2].usedPercent, 20);
});

for (const id of ['pi', 'opencode', 'hermes']) {
  test(`${id} reads each configured account and isolates failed provider checks`, async () => {
    const accounts = [['anthropic', {access: 'ONE'}], ['openai-codex', {access: 'TWO'}], ['custom-id-SECRET', {key: 'SECRET'}], ['anthropic', {access: 'THREE'}]];
    const seen = [];
    const r = await multiProvider(id, accounts, async (provider, credential) => {
      seen.push(credential.access || credential.key);
      if (credential.access === 'TWO') throw new Error('signInRequired');
      if (credential.key) return {windows: [], status: 'notReported'};
      return {windows: [{label: 'Weekly', usedPercent: 20}]};
    });
    assert.equal(seen.length, 4);
    assert.equal(r.windows.length, 2);
    assert.equal(r.status, 'available');
    assert.equal(r.windows[1].label, 'Anthropic · Account 2 · Weekly');
    assert.deepEqual(r.notices, [{provider: 'OpenAI Codex', status: 'signInRequired'}, {provider: 'Custom provider', status: 'notReported'}]);
    assert.ok(!JSON.stringify(r).includes('SECRET'));
  });
}

test('saved accounts stay scoped to each tool and Hermes deduplicates its pool', () => {
  const fs = require('fs'), os = require('os'), path = require('path');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'monkeyssh-accounts-'));
  const keys = ['PI_CODING_AGENT_DIR', 'XDG_DATA_HOME', 'HERMES_HOME', 'OPENCODE_AUTH_CONTENT'];
  const previous = Object.fromEntries(keys.map(k => [k, process.env[k]]));
  try {
    delete process.env.OPENCODE_AUTH_CONTENT;
    process.env.PI_CODING_AGENT_DIR = path.join(dir, 'pi');
    process.env.XDG_DATA_HOME = path.join(dir, 'data');
    process.env.HERMES_HOME = path.join(dir, 'hermes');
    for (const d of ['pi', 'data/opencode', 'hermes']) fs.mkdirSync(path.join(dir, d), {recursive: true});
    fs.writeFileSync(path.join(dir, 'pi/auth.json'), JSON.stringify({anthropic: {type: 'oauth', access: 'PI'}}));
    fs.writeFileSync(path.join(dir, 'data/opencode/auth.json'), JSON.stringify({openai: {type: 'oauth', access: 'OPENCODE'}}));
    fs.writeFileSync(path.join(dir, 'hermes/auth.json'), JSON.stringify({providers: {nous: {access_token: 'HERMES'}},
      credential_pool: {nous: [{access_token: 'HERMES'}, {access_token: 'SECOND'}]}}));
    assert.deepEqual(configuredAccounts('pi').map(([, c]) => c.access), ['PI']);
    assert.deepEqual(configuredAccounts('opencode').map(([, c]) => c.access), ['OPENCODE']);
    assert.deepEqual(configuredAccounts('hermes').map(([, c]) => c.access_token), ['HERMES', 'SECOND']);
  } finally {
    for (const key of keys) previous[key] == null ? delete process.env[key] : process.env[key] = previous[key];
    fs.rmSync(dir, {recursive: true, force: true});
  }
});

test('Windows stdin bootstrap accepts a fragmented payload without command expansion', async () => {
  const fs = require('fs'), path = require('path'), cp = require('child_process');
  const script = fs.readFileSync(path.join(__dirname, '../../assets/scripts/agent_usage_probe.cjs')).toString('base64');
  const bootstrap = "process.env.MONKEYSSH_USAGE_PROBE='1';const r=require('readline').createInterface({input:process.stdin});r.once('line',s=>{r.close();eval(Buffer.from(s,'base64').toString())})";
  const child = cp.spawn(process.execPath, ['-e', bootstrap, Buffer.from(JSON.stringify({unknown: ''})).toString('base64')]);
  let output = '';
  child.stdout.on('data', chunk => output += chunk);
  const closed = new Promise(resolve => child.on('close', resolve));
  child.stdin.write(script.slice(0, 200));
  child.stdin.end(script.slice(200) + '\n');
  assert.equal(await closed, 0);
  assert.equal(JSON.parse(output.split('=')[1]).status, 'unsupported');
});

test('Antigravity uses the quota-summary request schema and falls back on older CLIs', async () => {
  const {antigravity} = require('../../assets/scripts/agent_usage_probe.cjs');
  const methods = [];
  const result = await antigravity([12345], async (url, options) => {
    methods.push(url.split('/').pop());
    assert.equal(options.local, true);
    if (methods.length === 1) {
      assert.deepEqual(options.body, {forceRefresh: true});
      throw new Error('unavailable');
    }
    return {userStatus: {email: 'SECRET', cascadeModelConfigData: {clientModelConfigs: [
      {label: 'Pro', quotaInfo: {remainingFraction: .75, resetTime: '2026-10-01T00:00:00Z'}},
    ]}}};
  });
  assert.deepEqual(methods, ['RetrieveUserQuotaSummary', 'GetUserStatus']);
  assert.equal(result.windows[0].usedPercent, 25);
  assert.ok(!JSON.stringify(result).includes('SECRET'));
});


test('OpenCode matches inline auth precedence, BOM files, and credential read failures', async () => {
  const fs = require('fs'), os = require('os'), path = require('path');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'monkeyssh-opencode-auth-'));
  const previous = {XDG_DATA_HOME: process.env.XDG_DATA_HOME, OPENCODE_AUTH_CONTENT: process.env.OPENCODE_AUTH_CONTENT};
  try {
    process.env.XDG_DATA_HOME = dir;
    delete process.env.OPENCODE_AUTH_CONTENT;
    assert.deepEqual(configuredAccounts('opencode'), []);
    fs.mkdirSync(path.join(dir, 'opencode'));
    const file = path.join(dir, 'opencode', 'auth.json');
    fs.writeFileSync(file, '\uFEFF' + JSON.stringify({openai: {type: 'oauth', access: 'FILE'}}));
    assert.equal(configuredAccounts('opencode')[0][1].access, 'FILE');
    process.env.OPENCODE_AUTH_CONTENT = JSON.stringify({anthropic: {type: 'oauth', access: 'INLINE'}});
    assert.equal(configuredAccounts('opencode')[0][1].access, 'INLINE');
    process.env.OPENCODE_AUTH_CONTENT = '{';
    assert.equal(configuredAccounts('opencode')[0][1].access, 'FILE');
    process.env.OPENCODE_AUTH_CONTENT = '{}';
    assert.deepEqual(configuredAccounts('opencode'), []);
    delete process.env.OPENCODE_AUTH_CONTENT;
    fs.writeFileSync(file, JSON.stringify({custom: {type: 'wellknown', key: 'KEY', token: 'TOKEN'}}));
    assert.equal((await multiProvider('opencode')).notices[0].status, 'notReported');
    for (const malformed of ['{', 'null', '[]']) {
      fs.writeFileSync(file, malformed);
      assert.deepEqual(await require('../../assets/scripts/agent_usage_probe.cjs').probe('opencode', ''), {status: 'unavailable'});
    }
    fs.rmSync(file);
    fs.mkdirSync(file);
    assert.throws(() => configuredAccounts('opencode'), /unavailable/);
  } finally {
    for (const [key, value] of Object.entries(previous)) value == null ? delete process.env[key] : process.env[key] = value;
    fs.rmSync(dir, {recursive: true, force: true});
  }
});
