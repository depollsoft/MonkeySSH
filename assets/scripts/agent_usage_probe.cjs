// Runs on the SSH host. Never emit credentials, raw provider responses, or errors.
// Codex: https://developers.openai.com/codex/app-server#rate-limits-chatgpt
// Copilot: github/copilot-sdk nodejs/src/generated/rpc.ts AccountGetQuotaResult.
const fs = require('fs');
const os = require('os');
const path = require('path');
const cp = require('child_process');
const https = require('https');
const http = require('http');
const crypto = require('crypto');
const number = x => typeof x === 'number' && Number.isFinite(x) ? x : null;
const date = x => {
  if (x == null) return null;
  const d = new Date(typeof x === 'number' ? x * 1000 : x);
  return Number.isFinite(d.getTime()) ? d.toISOString() : null;
};
function codexUsage(data) {
  const buckets = data.rateLimitsByLimitId || (data.rateLimits ? {codex: data.rateLimits} : {});
  const windows = [];
  for (const [id, bucket] of Object.entries(buckets)) {
    for (const key of ['primary', 'secondary']) {
      const w = bucket?.[key];
      if (number(w?.usedPercent) == null) continue;
      const minutes = number(w.windowDurationMins);
      const label = minutes === 10080 ? 'Weekly' : minutes === 300 ? '5 hours' :
        minutes > 0 ? `${minutes} minutes` : key === 'primary' ? 'Primary limit' : 'Secondary limit';
      windows.push({label: id === 'codex' ? label : `${String(id).slice(0, 60)} · ${label}`,
        usedPercent: w.usedPercent, resetsAt: date(w.resetsAt)});
    }
  }
  return {windows, resetCredits: number(data.rateLimitResetCredits?.availableCount)};
}
function copilotUsage(data) {
  const names = {premium_interactions: 'Premium requests', chat: 'Chat', completions: 'Completions'};
  return {windows: Object.entries(data.quotaSnapshots || {}).flatMap(([id, w]) => {
    if (!w || (!w.isUnlimitedEntitlement && number(w.remainingPercentage) == null)) return [];
    return [{label: names[id] || String(id).slice(0, 60),
      usedPercent: w.isUnlimitedEntitlement ? null : 100 - w.remainingPercentage,
      unlimited: w.isUnlimitedEntitlement === true, used: number(w.usedRequests),
      limit: w.entitlementRequests >= 0 ? number(w.entitlementRequests) : null,
      overageAllowed: w.overageAllowedWithExhaustedQuota === true,
      resetsAt: date(w.resetDate)}];
  })};
}
function claudeUsage(data) {
  const names = {five_hour: '5 hours', seven_day: 'Weekly', seven_day_opus: 'Weekly · Opus',
    seven_day_sonnet: 'Weekly · Sonnet', seven_day_oauth_apps: 'Weekly · OAuth apps',
    seven_day_cowork: 'Weekly · Cowork'};
  return {windows: Object.entries(names).flatMap(([key, label]) => {
    const w = data[key];
    return number(w?.utilization) == null ? [] :
      [{label, usedPercent: w.utilization, resetsAt: date(w.resets_at)}];
  })};
}
function stop(child) {
  if (!child.pid) return;
  if (process.platform === 'win32') {
    cp.spawn('taskkill.exe', ['/PID', String(child.pid), '/T', '/F'], {stdio: 'ignore', windowsHide: true}).on('error', () => {});
  } else {
    try { process.kill(-child.pid, 'SIGKILL'); } catch { child.kill('SIGKILL'); }
  }
}
function spawnAgent(executable, args) {
  // Use a neutral directory so no project configuration is loaded.
  // npm launchers on Windows are .cmd files, which CreateProcess cannot run.
  // Encode a literal PowerShell invocation instead of passing paths to cmd /c.
  if (process.platform === 'win32' && /\.(cmd|bat)$/i.test(executable)) {
    const quote = value => "'" + value.replace(/['\u2018\u2019\u201a\u201b]/g, '$&$&') + "'";
    const script = '& ' + [executable, ...args].map(quote).join(' ');
    executable = 'powershell.exe';
    args = ['-NoProfile', '-NonInteractive', '-EncodedCommand', Buffer.from(script, 'utf16le').toString('base64')];
  }
  return cp.spawn(executable, args, {cwd: os.tmpdir(),
    detached: process.platform !== 'win32', windowsHide: true,
    stdio: ['pipe', 'pipe', 'ignore'], env: {...process.env, NO_COLOR: '1',
      OTEL_SDK_DISABLED: 'true', COPILOT_TELEMETRY_ENABLED: 'false'}});
}
function rpc(executable, args, method, framed, initialize) {
  return new Promise((resolve, reject) => {
    const child = spawnAgent(executable, args);
    let buffer = Buffer.alloc(0), done = false;
    const finish = (error, result) => {
      if (done) return;
      done = true; clearTimeout(timer); stop(child);
      error ? reject(error) : resolve(result);
    };
    const timer = setTimeout(() => finish(new Error('timeout')), 12000);
    child.on('error', () => finish(new Error('unavailable')));
    child.on('exit', () => finish(new Error('unavailable')));
    child.stdin.on('error', () => finish(new Error('unavailable')));
    const send = message => {
      const body = JSON.stringify({jsonrpc: '2.0', ...message});
      child.stdin.write(framed ? `Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}` : body + '\n');
    };
    const receive = message => {
      if (message.id === 1 && initialize) {
        if (message.error) return finish(new Error('unavailable'));
        send({method: 'initialized', params: {}});
        send({id: 2, method, params: {}});
      } else if (message.id === 2) {
        if (message.error) return finish(new Error('unavailable'));
        finish(null, message.result || {});
      }
    };
    child.stdout.on('data', chunk => {
      buffer = Buffer.concat([buffer, chunk]);
      if (buffer.length > 1024 * 1024) return finish(new Error('unavailable'));
      while (!done) {
        let body;
        if (framed) {
          const end = buffer.indexOf('\r\n\r\n');
          if (end < 0) break;
          const match = /Content-Length: (\d+)/i.exec(buffer.subarray(0, end).toString());
          if (!match) return finish(new Error('unavailable'));
          const size = Number(match[1]);
          if (size > 1024 * 1024) return finish(new Error('unavailable'));
          if (buffer.length < end + 4 + size) break;
          body = buffer.subarray(end + 4, end + 4 + size).toString();
          buffer = buffer.subarray(end + 4 + size);
        } else {
          const end = buffer.indexOf('\n');
          if (end < 0) break;
          body = buffer.subarray(0, end).toString(); buffer = buffer.subarray(end + 1);
        }
        try { receive(JSON.parse(body)); } catch { finish(new Error('unavailable')); }
      }
    });
    if (initialize) send({id: 1, method: 'initialize', params: {
      clientInfo: {name: 'monkeyssh_usage', version: '1.0.0'}, capabilities: {}}});
    else send({id: 2, method, params: {}});
  });
}
function readJson(file) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return {}; } }
const requestCache = new Map();
function requestJson(url, {token, headers = {}, body, local = false} = {}) {
  const address = new URL(url);
  if (local && address.hostname !== '127.0.0.1') return Promise.reject(new Error('unavailable'));
  const key = crypto.createHash('sha256').update(JSON.stringify([url, token, headers, body])).digest('hex');
  if (requestCache.has(key)) return requestCache.get(key);
  const promise = new Promise((resolve, reject) => {
    const payload = body == null ? null : JSON.stringify(body);
    const transport = address.protocol === 'https:' ? https : http;
    const request = transport.request(address, {method: payload ? 'POST' : 'GET',
      rejectUnauthorized: !local, headers: {
        Accept: 'application/json', 'User-Agent': 'MonkeySSH-Usage/1.0',
        ...(token ? {Authorization: `Bearer ${token}`} : {}),
        ...(payload ? {'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload)} : {}),
        ...headers,
      }}, response => {
      if (response.statusCode !== 200) {
        response.resume();
        reject(new Error(response.statusCode === 429 ? 'rateLimited' :
          response.statusCode === 401 ? 'signInRequired' : 'unavailable')); return;
      }
      let text = '';
      response.on('data', chunk => {
        text += chunk;
        if (text.length > 1024 * 1024) request.destroy(new Error('unavailable'));
      });
      response.on('error', () => reject(new Error('unavailable')));
      response.on('end', () => { try { resolve(JSON.parse(text)); } catch { reject(new Error('unavailable')); } });
    });
    const timer = setTimeout(() => request.destroy(new Error('timeout')), local ? 2500 : 8000);
    request.on('close', () => clearTimeout(timer));
    request.on('error', () => reject(new Error('unavailable')));
    request.end(payload);
  });
  requestCache.set(key, promise);
  return promise;
}
function runJson(executable, args) {
  return new Promise((resolve, reject) => {
    const child = spawnAgent(executable, args);
    let output = '', done = false;
    const finish = error => {
      if (done) return;
      done = true; clearTimeout(timer); stop(child);
      if (error) return reject(new Error('unavailable'));
      try { resolve(JSON.parse(output)); } catch { reject(new Error('unavailable')); }
    };
    const timer = setTimeout(() => finish(true), 12000);
    child.on('error', () => finish(true));
    child.on('close', code => finish(code !== 0));
    child.stdin.end();
    child.stdout.on('data', chunk => {
      output += chunk;
      if (output.length > 1024 * 1024) finish(true);
    });
  });
}
function keychain(service, account) {
  if (process.platform !== 'darwin') return null;
  try {
    return cp.execFileSync('security', ['find-generic-password', '-s', service,
      ...(account ? ['-a', account] : []), '-w'],
      {timeout: 2000, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 65536}).trim();
  } catch (error) {
    if (error.status === 44) return null; // Keychain item not found.
    throw new Error('unavailable'); // Locked or inaccessible keychain.
  }
}
async function claude() {
  const dir = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
  let credentials = readJson(path.join(dir, '.credentials.json'));
  if (!credentials.claudeAiOauth && process.platform === 'darwin' && !process.env.CLAUDE_CONFIG_DIR) {
    const value = keychain('Claude Code-credentials');
    if (value) { try { credentials = JSON.parse(value); } catch { throw new Error('unavailable'); } }
  }
  const token = process.env.CLAUDE_CODE_OAUTH_TOKEN || credentials.claudeAiOauth?.accessToken;
  if (!token) throw new Error('signInRequired');
  return claudeUsage(await requestJson('https://api.anthropic.com/api/oauth/usage', {
    token, headers: {'anthropic-beta': 'oauth-2025-04-20'},
  }));
}

// Provider-specific account readers. Authentication is read only; never refreshed.
const providerNames = {
  anthropic: 'Anthropic', openai: 'OpenAI', 'openai-codex': 'OpenAI Codex',
  'github-copilot': 'GitHub Copilot', 'google-antigravity': 'Google Antigravity',
  'google-gemini-cli': 'Google Gemini', google: 'Google', openrouter: 'OpenRouter',
  nous: 'Nous', xai: 'xAI', groq: 'Groq', mistral: 'Mistral', deepseek: 'DeepSeek',
  opencode: 'OpenCode Zen', 'opencode-go': 'OpenCode Go', ollama: 'Ollama',
};
const label = (value, fallback) => typeof value === 'string' && value.trim()
  ? value.replace(/[\x00-\x1f\x7f]/g, '').slice(0, 65) : fallback;
const statusOf = error => ['signInRequired', 'rateLimited', 'needsRunning', 'notReported'].includes(error?.message)
  ? error.message : 'unavailable';
const milliseconds = value => {
  const n = typeof value === 'string' && /^\d+$/.test(value) ? Number(value) : number(value);
  return n != null && n > 0 ? date(n / 1000) : null;
};
function budget(label, used, limit, resetsAt, unit) {
  return {label, used, limit, unit, resetsAt,
    usedPercent: used != null && limit > 0 ? 100 * used / limit : null};
}
function grokUsage(data) {
  const c = data.config || {};
  const cents = x => x && typeof x === 'object' ? (number(x.val) ?? (Object.keys(x).length === 0 ? 0 : null)) : null;
  const windows = [];
  const used = cents(c.used), cap = cents(c.monthlyLimit);
  const percent = number(c.creditUsagePercent);
  const reset = date(c.currentPeriod?.end || c.billingPeriodEnd);
  if (percent != null || (cap > 0 && used != null) || reset) {
    windows.push({...budget('Included credits', used == null ? null : used / 100,
      cap == null ? null : cap / 100, reset, 'USD'), usedPercent: percent ?? (cap > 0 && used != null ? used / cap * 100 : null)});
  }
  const demandUsed = cents(c.onDemandUsed), demandCap = cents(c.onDemandCap);
  if (demandCap > 0 && demandUsed != null) windows.push(budget('On-demand spending', demandUsed / 100, demandCap / 100, reset, 'USD'));
  const prepaid = cents(c.prepaidBalance);
  if (prepaid != null) windows.push({label: 'Prepaid balance', remaining: prepaid / 100, unit: 'USD'});
  return {windows};
}
async function grok() {
  const data = readJson(path.join(process.env.GROK_HOME || path.join(os.homedir(), '.grok'), 'auth.json'));
  const scope = Object.keys(data).find(x => x.startsWith('https://auth.x.ai::')) || 'https://accounts.x.ai/sign-in';
  const token = data[scope]?.key;
  if (!token) throw new Error(data['xai::api_key'] ? 'notReported' : 'signInRequired');
  return grokUsage(await requestJson('https://cli-chat-proxy.grok.com/v1/billing?format=credits', {
    token, headers: {'x-xai-token-auth': 'xai-grok-cli'},
  }));
}
function cursorUsage(data) {
  const policy = data.usageLimitPolicyStatus || data;
  // Proto3 omits false scalars. An empty valid policy means no slow-pool restriction.
  return {windows: [{label: 'Account access', restricted: policy.isInSlowPool === true,
    resetsAt: milliseconds(policy.resetAtMs)}]};
}
async function cursor() {
  const dir = process.platform === 'darwin' ? path.join(os.homedir(), '.cursor') :
    process.platform === 'win32' ? path.join(process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming'), 'Cursor') :
      path.join(process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config'), 'cursor');
  const credentials = readJson(path.join(dir, 'auth.json'));
  const token = process.env.CURSOR_AUTH_TOKEN || keychain('cursor-access-token', 'cursor-user') || credentials.accessToken;
  if (!token) throw new Error(credentials.apiKey || process.env.CURSOR_API_KEY ? 'notReported' : 'signInRequired');
  return cursorUsage(await requestJson('https://api2.cursor.sh/aiserver.v1.DashboardService/GetUsageLimitPolicyStatus', {
    token, headers: {'Connect-Protocol-Version': '1'}, body: {},
  }));
}
function antigravityUsage(data) {
  const summary = data.response || data.summary || data;
  const windows = [];
  for (const group of summary.groups || []) {
    for (const bucket of group.buckets || []) {
      const fraction = number(bucket.remainingFraction);
      if (bucket.disabled || fraction == null || fraction < 0 || fraction > 1) continue;
      windows.push({label: label(`${group.displayName || 'Quota'} · ${bucket.displayName || 'Limit'}`, 'Quota'),
        usedPercent: (1 - fraction) * 100, resetsAt: date(bucket.resetTime)});
    }
  }
  for (const model of data.userStatus?.cascadeModelConfigData?.clientModelConfigs || []) {
    const fraction = number(model.quotaInfo?.remainingFraction);
    if (fraction == null || fraction < 0 || fraction > 1) continue;
    windows.push({label: label(model.label, 'Model quota'), usedPercent: (1 - fraction) * 100,
      resetsAt: date(model.quotaInfo.resetTime)});
  }
  // Gemini / Antigravity OAuth providers return model buckets directly.
  for (const bucket of data.buckets || []) {
    const fraction = number(bucket.remainingFraction);
    if (fraction == null || fraction < 0 || fraction > 1) continue;
    windows.push({label: label(bucket.modelId, 'Model quota'), usedPercent: (1 - fraction) * 100,
      resetsAt: date(bucket.resetTime)});
  }
  return {windows};
}
function antigravityPorts() {
  const command = (exe, args) => cp.execFileSync(exe, args, {
    encoding: 'utf8', timeout: 2000, maxBuffer: 1024 * 1024, stdio: ['ignore', 'pipe', 'ignore'],
  });
  if (process.platform === 'win32') {
    const script = "$ids = @(Get-Process -Name agy,antigravity,antigravity-cli -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id); @((Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $ids -contains $_.OwningProcess }).LocalPort) | ConvertTo-Json -Compress";
    try { return [].concat(JSON.parse(command('powershell.exe', ['-NoProfile', '-NonInteractive', '-EncodedCommand', Buffer.from(script, 'utf16le').toString('base64')]))).filter(Number.isInteger); } catch { return []; }
  }
  const ports = new Set();
  let processes;
  try { processes = command('ps', ['-axo', 'pid=,comm=']).split('\n'); } catch { return []; }
  const deadline = Date.now() + 4000;
  for (const line of processes) {
    if (Date.now() > deadline) throw new Error('unavailable');
    const match = /^\s*(\d+)\s+(.+)$/.exec(line);
    if (!match || !['agy', 'antigravity', 'antigravity-cli'].includes(path.basename(match[2].trim()))) continue;
    const pid = match[1];
    try {
      if (process.platform === 'darwin') {
        const output = command('lsof', ['-a', '-p', pid, '-iTCP', '-sTCP:LISTEN', '-Fn']);
        for (const row of output.split('\n')) {
          const port = /^n.*:(\d+)$/.exec(row);
          if (port) ports.add(Number(port[1]));
        }
      } else {
        const fds = path.join('/proc', pid, 'fd');
        const sockets = new Set(fs.readdirSync(fds).flatMap(fd => {
          try { const m = /^socket:\[(\d+)\]$/.exec(fs.readlinkSync(path.join(fds, fd))); return m ? [m[1]] : []; } catch { return []; }
        }));
        for (const version of ['tcp', 'tcp6']) {
          const rows = fs.readFileSync(path.join('/proc', pid, 'net', version), 'utf8').split('\n');
          for (const row of rows) {
            const fields = row.trim().split(/\s+/);
            if (fields[3] === '0A' && sockets.has(fields[9])) ports.add(parseInt(fields[1].split(':')[1], 16));
          }
        }
      }
    } catch {}
  }
  return [...ports];
}
async function antigravity(ports = antigravityPorts(), request = requestJson) {
  if (!ports.length) throw new Error('needsRunning');
  const results = await Promise.all(ports.slice(0, 16).map(async port => {
    for (const scheme of process.platform === 'linux' ? ['https', 'http'] : ['https']) {
      for (const [method, body] of [
        ['RetrieveUserQuotaSummary', {forceRefresh: true}],
        ['GetUserStatus', {metadata: {ideName: 'antigravity', extensionName: 'antigravity', ideVersion: 'unknown', locale: 'en'}}],
      ]) {
        try {
          const result = antigravityUsage(await request(`${scheme}://127.0.0.1:${port}/exa.language_server_pb.LanguageServerService/${method}`, {local: true, body}));
          if (result.windows.length) return result;
        } catch {}
      }
    }
    return {windows: []};
  }));
  // Multiple running servers can use different accounts. Do not silently choose one.
  return {windows: results.flatMap((r, i) => r.windows.map(w => ({...w,
    label: results.filter(x => x.windows.length).length > 1 ? `Instance ${i + 1} · ${w.label}` : w.label}))) };
}
function openclawUsage(data) {
  const usage = data.usage;
  if (!usage || !Array.isArray(usage.providers)) return {windows: [], status: 'unavailable'};
  const windows = [], notices = [];
  for (const provider of usage.providers) {
    const name = providerNames[provider.provider] || 'Provider';
    const before = windows.length;
    for (const w of provider.windows || []) {
      if (number(w.usedPercent) == null) continue;
      windows.push({label: `${name} · ${label(w.label, 'Quota')}`.slice(0, 100),
        usedPercent: w.usedPercent, resetsAt: milliseconds(w.resetAt)});
    }
    for (const b of provider.billing || []) {
      if (b.unit !== 'USD') continue;
      if (b.type === 'balance' && number(b.amount) != null) windows.push({label: `${name} · Balance`, remaining: b.amount, unit: 'USD'});
      if (b.type === 'budget' && number(b.used) != null && number(b.limit) > 0) windows.push(budget(`${name} · Budget`, b.used, b.limit, milliseconds(b.resetAt), 'USD'));
    }
    if (provider.error || windows.length === before) notices.push({provider: name,
      status: provider.error ? 'unavailable' : 'notReported'});
  }
  return {windows, notices, status: windows.length ? 'available' : notices.length ? 'notReported' : usage.refreshing ? 'unavailable' : 'noAccounts'};
}
function codexOAuthUsage(data) {
  const convert = bucket => ({primary: convertWindow(bucket?.primary_window), secondary: convertWindow(bucket?.secondary_window)});
  const convertWindow = w => w && ({usedPercent: w.used_percent,
    windowDurationMins: w.limit_window_seconds / 60, resetsAt: w.reset_at});
  const buckets = {codex: convert(data.rate_limit)};
  for (const [i, item] of (data.additional_rate_limits || []).entries()) {
    buckets[label(item.limit_name, `Additional limit ${i + 1}`)] = convert(item.rate_limit);
  }
  return codexUsage({rateLimitsByLimitId: buckets,
    rateLimitResetCredits: {availableCount: data.rate_limit_reset_credits?.available_count}});
}
function copilotOAuthUsage(data) {
  return copilotUsage({quotaSnapshots: Object.fromEntries(Object.entries(data.quota_snapshots || {}).map(([id, w]) => [id, {
    isUnlimitedEntitlement: w.unlimited, remainingPercentage: w.percent_remaining,
    usedRequests: number(w.entitlement) != null && number(w.remaining) != null ? w.entitlement - w.remaining : null,
    entitlementRequests: w.entitlement, overageAllowedWithExhaustedQuota: w.overage_permitted,
    resetDate: data.quota_reset_date,
  }]))});
}
function openrouterUsage(data) {
  const d = data.data || {};
  if (number(d.limit) > 0 && number(d.usage) != null) return {windows: [budget('Key spending limit', d.usage, d.limit, null, 'USD')]};
  if (number(d.limit_remaining) != null) return {windows: [{label: 'Key balance', remaining: d.limit_remaining, unit: 'USD'}]};
  return {windows: [], status: 'notReported'};
}
function nousUsage(data) {
  const subscription = data.subscription || {}, access = data.paid_service_access || {};
  const cap = number(subscription.monthly_credits), remaining = number(subscription.credits_remaining);
  const windows = [];
  if (cap > 0 && remaining != null && remaining <= cap) windows.push(budget('Subscription credits', cap - remaining, cap, date(subscription.current_period_end), 'USD'));
  else if (remaining != null) windows.push({label: 'Subscription balance', remaining, unit: 'USD'});
  if (number(access.purchased_credits_remaining) != null) windows.push({label: 'Purchased balance', remaining: access.purchased_credits_remaining, unit: 'USD'});
  if (number(access.member_spend_cap_usd) > 0 && number(access.member_spend_usd) != null) windows.push(budget('Member spending limit', access.member_spend_usd, access.member_spend_cap_usd, null, 'USD'));
  return {windows};
}
async function providerUsage(id, credential) {
  const c = credential.tokens || credential;
  const token = c.access || c.access_token || c.accessToken;
  const oauth = credential.type === 'oauth' || credential.auth_type === 'oauth' || Boolean(token);
  if (oauth && token) {
    if (id === 'anthropic') return claudeUsage(await requestJson('https://api.anthropic.com/api/oauth/usage', {
      token, headers: {'anthropic-beta': 'oauth-2025-04-20'},
    }));
    if (id === 'openai' || id === 'openai-codex') {
      let account = c.accountId || c.account_id;
      if (!account) { try { account = JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString())['https://api.openai.com/auth']?.chatgpt_account_id; } catch {} }
      return codexOAuthUsage(await requestJson('https://chatgpt.com/backend-api/wham/usage', {
        token, headers: account ? {'ChatGPT-Account-Id': account} : {},
      }));
    }
    if (id === 'github-copilot') {
      const githubToken = [c.refresh, c.refresh_token, token].find(x => typeof x === 'string' && /^(ghu_|gho_|ghp_|github_pat_)/.test(x));
      if (!githubToken) throw new Error('unavailable');
      return copilotOAuthUsage(await requestJson('https://api.github.com/copilot_internal/user', {token: githubToken}));
    }
    if (['google-antigravity', 'google-gemini-cli'].includes(id)) return antigravityUsage(await requestJson(
      'https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota', {token,
        body: c.projectId ? {project: c.projectId} : {}}));
    if (id === 'nous') return nousUsage(await requestJson('https://portal.nousresearch.com/api/oauth/account', {token}));
  }
  if (id === 'openrouter') {
    const key = c.key || c.api_key;
    // Some tools allow shell commands as keys. Never evaluate those commands.
    if (typeof key === 'string' && key.startsWith('sk-or-')) return openrouterUsage(await requestJson('https://openrouter.ai/api/v1/key', {token: key}));
  }
  return {windows: [], status: oauth && !token ? 'signInRequired' : 'notReported'};
}
function configuredAccounts(id) {
  let data;
  if (id === 'opencode') data = readJson(path.join(process.env.XDG_DATA_HOME || path.join(os.homedir(), '.local', 'share'), 'opencode', 'auth.json'));
  else if (id === 'pi') data = readJson(path.join(process.env.PI_CODING_AGENT_DIR || path.join(os.homedir(), '.pi', 'agent'), 'auth.json'));
  else {
    data = readJson(path.join(process.env.HERMES_HOME || path.join(os.homedir(), '.hermes'), 'auth.json'));
    const entries = [];
    for (const [provider, state] of Object.entries(data.providers || {})) if (state && typeof state === 'object') entries.push([provider, state]);
    for (const [provider, pool] of Object.entries(data.credential_pool || {})) {
      if (Array.isArray(pool)) for (const state of pool) if (state && typeof state === 'object') entries.push([provider, state]);
    }
    // Same credentials may be present in both active state and the account pool.
    const seen = new Set();
    return entries.filter(([provider, c]) => {
      const token = c.tokens || c;
      const key = JSON.stringify([provider, token.access || token.access_token || token.key || token.api_key]);
      if (seen.has(key)) return false; seen.add(key); return true;
    });
  }
  return Object.entries(data).filter(([, c]) => c && typeof c === 'object' && ['oauth', 'api', 'api_key'].includes(c.type));
}
async function multiProvider(id, accounts = configuredAccounts(id), reader = providerUsage) {
  if (!accounts.length) return {windows: [], notices: [], status: 'noAccounts'};
  const totals = new Map(), seen = new Map();
  for (const [id] of accounts) totals.set(id, (totals.get(id) || 0) + 1);
  const results = await Promise.all(accounts.map(async ([provider, credential]) => {
    const index = (seen.get(provider) || 0) + 1; seen.set(provider, index);
    const name = (providerNames[provider] || 'Custom provider') + (totals.get(provider) > 1 ? ` · Account ${index}` : '');
    try {
      const result = await reader(provider, credential);
      return {windows: result.windows.map(w => ({...w, label: `${name} · ${w.label}`.slice(0, 100)})),
        notices: result.windows.length ? [] : [{provider: name, status: result.status || 'unavailable'}]};
    } catch (error) { return {windows: [], notices: [{provider: name, status: statusOf(error)}]}; }
  }));
  const windows = results.flatMap(r => r.windows), notices = results.flatMap(r => r.notices);
  return {windows, notices, status: windows.length ? 'available' : 'notReported'};
}

async function probe(id, executable) {
  try {
    let result;
    if (id === 'claude') result = await claude();
    else if (id === 'codex') result = codexUsage(await rpc(executable,
      ['app-server'], 'account/rateLimits/read', false, true));
    else if (id === 'copilot') result = copilotUsage(await rpc(executable,
      ['--headless', '--stdio', '--no-auto-update', '--log-level', 'none'], 'account.getQuota', true, false));
    else if (id === 'grok') result = await grok();
    else if (id === 'cursor') result = await cursor();
    else if (id === 'antigravity') result = await antigravity();
    else if (id === 'openclaw') result = openclawUsage(await runJson(executable, ['status', '--usage', '--json']));
    else if (['opencode', 'pi', 'hermes'].includes(id)) result = await multiProvider(id);
    else return {status: 'unsupported'};
    return {...result, status: result.status || (result.windows.length ? 'available' : 'unavailable')};
  } catch (error) {
    return {status: statusOf(error)};
  }
}
module.exports = {codexUsage, copilotUsage, claudeUsage, grokUsage, cursorUsage, antigravityUsage,
  openclawUsage, codexOAuthUsage, copilotOAuthUsage, openrouterUsage, nousUsage, configuredAccounts, multiProvider, antigravity, rpc, probe};
if (require.main === module || process.env.MONKEYSSH_USAGE_PROBE === '1') {
  const input = JSON.parse(Buffer.from(process.argv[process.env.MONKEYSSH_USAGE_PROBE === '1' ? 1 : 2], 'base64').toString());
  Promise.all(Object.entries(input).map(async ([id, executable]) => {
    const result = await probe(id, executable);
    process.stdout.write('__monkeyssh_usage__=' + JSON.stringify({id, ...result}) + '\n');
  })).catch(() => {});
}
