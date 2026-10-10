import assert from "node:assert/strict";
import { test } from "node:test";

import type { TokenMessage } from "firebase-admin/messaging";

import { encodeBase64Url } from "../base64url";
import { handlePushNotify, type NotifyDeps, type NotifyLogEntry } from "../notify";
import { TokenBucketLimiter } from "../rateLimit";
import {
  maxTicketAgeSeconds,
  parseTicketKeys,
  sealTicket,
  type TicketKeys,
} from "../ticket";

const keys: TicketKeys = parseTicketKeys(
  JSON.stringify({
    current: "k1",
    keys: { k1: encodeBase64Url(Buffer.alloc(32, 7)) },
  }),
);
const token = "fcm-test-token:APA91bNotARealTokenButLongEnough";
const ticket = sealTicket(keys, {
  token,
  deviceId: "dev_test_device_00001",
  issuedAt: 1760000000,
  platform: "android",
});
const payload = encodeBase64Url(Buffer.alloc(80, 3));
const collapse = "0123456789abcdef0123456789abcdef";

interface Harness {
  deps: NotifyDeps;
  sent: TokenMessage[];
  logs: NotifyLogEntry[];
}

function harness(
  options: { sendError?: unknown; limiter?: TokenBucketLimiter } = {},
): Harness {
  const sent: TokenMessage[] = [];
  const logs: NotifyLogEntry[] = [];
  return {
    sent,
    logs,
    deps: {
      keys: () => keys,
      limiter:
        options.limiter ?? new TokenBucketLimiter({ burst: 5, refillPerHour: 30 }),
      send: async (message) => {
        if (options.sendError !== undefined) {
          throw options.sendError;
        }
        sent.push(message);
        return "projects/monkeyssh/messages/1";
      },
      log: (entry) => logs.push(entry),
      nowSeconds: () => 1760000000,
    },
  };
}

function post(body: unknown) {
  const raw = Buffer.from(JSON.stringify(body));
  return { method: "POST", rawBody: raw, body };
}

const valid = { ticket, kind: "permission", collapse, payload };

function assertLogsClean(logs: NotifyLogEntry[]) {
  const text = JSON.stringify(logs);
  for (const secret of [ticket, token, payload, collapse, "dev_test_device_00001"]) {
    assert.ok(!text.includes(secret), "log leaked a secret");
  }
}

test("a valid event is sent and answered with 202", async () => {
  const h = harness();
  const response = await handlePushNotify(post(valid), h.deps);
  assert.equal(response.status, 202);
  assert.deepEqual(response.body, { status: "sent" });
  assert.equal(h.sent.length, 1);
  const message = h.sent[0];
  assert.equal(message.token, token);
  assert.deepEqual(message.data, { v: "1", p: payload });
  assert.equal(message.notification?.title, "Approval needed");
  assert.equal(message.android?.priority, "high");
  assert.equal(message.android?.collapseKey, collapse);
  assert.equal(message.android?.notification?.channelId, "agent-attention");
  assert.equal(message.android?.notification?.tag, collapse);
  assert.equal(message.apns?.headers?.["apns-priority"], "10");
  assert.equal(message.apns?.headers?.["apns-collapse-id"], collapse);
  assert.equal(message.apns?.payload?.aps.mutableContent, true);
  assert.deepEqual(h.logs, [
    { outcome: "sent", kind: "permission", platform: "android" },
  ]);
  assertLogsClean(h.logs);
});

test("normal-priority kinds stay quiet", async () => {
  const h = harness();
  await handlePushNotify(post({ ...valid, kind: "finished" }), h.deps);
  const message = h.sent[0];
  assert.equal(message.android?.priority, "normal");
  // The channel decides sound on Android 8+, so routine kinds use a quiet one.
  assert.equal(message.android?.notification?.channelId, "agent-updates");
  assert.equal(message.apns?.headers?.["apns-priority"], "5");
  assert.equal(message.apns?.payload?.aps.sound, undefined);
  assert.equal(message.notification?.body, "An agent finished its turn.");
});

test("only POST is accepted", async () => {
  const h = harness();
  const response = await handlePushNotify(
    { method: "GET", body: undefined },
    h.deps,
  );
  assert.equal(response.status, 405);
  assert.equal(h.sent.length, 0);
});

test("bodies over 4 KB are rejected by their raw size", async () => {
  const h = harness();
  const response = await handlePushNotify(
    { method: "POST", rawBody: Buffer.alloc(4097, 32), body: valid },
    h.deps,
  );
  assert.equal(response.status, 413);
  assert.equal(h.sent.length, 0);
});

test("malformed events are answered with 400", async () => {
  const cases: unknown[] = [
    "not an object",
    [valid],
    { ...valid, kind: "chatty" },
    { ...valid, collapse: "has spaces" },
    { ...valid, collapse: "" },
    { ...valid, payload: "short" },
    { ...valid, payload: payload + "=" },
    { ...valid, payload: "a".repeat(3073) },
    { ...valid, ticket: 42 },
  ];
  for (const body of cases) {
    const h = harness();
    const response = await handlePushNotify(post(body), h.deps);
    assert.equal(response.status, 400, JSON.stringify(body).slice(0, 40));
    assert.equal(h.sent.length, 0);
  }
});

test("a forged or altered ticket is answered with 401", async () => {
  const altered = ticket.slice(0, -2) + (ticket.endsWith("A") ? "BB" : "AA");
  const otherKeys = parseTicketKeys(
    JSON.stringify({ current: "k1", keys: { k1: encodeBase64Url(Buffer.alloc(32, 9)) } }),
  );
  const forged = sealTicket(otherKeys, {
    token,
    deviceId: "dev_test_device_00001",
    issuedAt: 1,
  });
  for (const bad of [altered, forged, "v1.k1.", "nonsense"]) {
    const h = harness();
    const response = await handlePushNotify(post({ ...valid, ticket: bad }), h.deps);
    assert.equal(response.status, 401);
    assert.deepEqual(response.body, { error: "bad_ticket" });
    assert.equal(h.sent.length, 0);
    assertLogsClean(h.logs);
  }
});

test("an unregistered FCM token is answered with 410", async () => {
  for (const code of [
    "messaging/registration-token-not-registered",
    "messaging/invalid-registration-token",
    "messaging/installation-id-not-registered",
  ]) {
    const h = harness({ sendError: { code, message: `token ${token}` } });
    const response = await handlePushNotify(post(valid), h.deps);
    assert.equal(response.status, 410, code);
    assert.deepEqual(response.body, { error: "unregistered" });
    assertLogsClean(h.logs);
  }
});

test("FCM outages are answered with 503 and FCM throttling with 429", async () => {
  const unavailable = harness({ sendError: { code: "messaging/server-unavailable" } });
  assert.equal((await handlePushNotify(post(valid), unavailable.deps)).status, 503);
  const unknown = harness({ sendError: new Error("boom") });
  assert.equal((await handlePushNotify(post(valid), unknown.deps)).status, 503);
  const throttled = harness({
    sendError: { code: "messaging/device-message-rate-exceeded" },
  });
  const response = await handlePushNotify(post(valid), throttled.deps);
  assert.equal(response.status, 429);
  assert.equal(response.headers?.["Retry-After"], "60");
});

test("each ticket gets a burst of 5 and then 429 with Retry-After", async () => {
  let now = 0;
  const limiter = new TokenBucketLimiter({
    burst: 5,
    refillPerHour: 30,
    now: () => now,
  });
  const h = harness({ limiter });
  for (let index = 0; index < 5; index++) {
    assert.equal((await handlePushNotify(post(valid), h.deps)).status, 202);
  }
  const limited = await handlePushNotify(post(valid), h.deps);
  assert.equal(limited.status, 429);
  assert.equal(limited.headers?.["Retry-After"], "120");
  assert.equal(h.sent.length, 5);
  now += 120_000;
  assert.equal((await handlePushNotify(post(valid), h.deps)).status, 202);
  assertLogsClean(h.logs);
});

test("compressed bodies are refused", async () => {
  for (const encoding of ["gzip", "deflate", "br", "gzip, identity"]) {
    const h = harness();
    const response = await handlePushNotify(
      { ...post(valid), contentEncoding: encoding },
      h.deps,
    );
    assert.equal(response.status, 415, encoding);
    assert.equal(h.sent.length, 0);
  }
  const plain = harness();
  const response = await handlePushNotify(
    { ...post(valid), contentEncoding: "identity" },
    plain.deps,
  );
  assert.equal(response.status, 202);
});

test("project-side FCM errors keep registrations and are logged as errors", async () => {
  for (const code of [
    "messaging/mismatched-credential",
    "messaging/third-party-auth-error",
    "messaging/authentication-error",
  ]) {
    const h = harness({ sendError: { code, message: `token ${token}` } });
    const response = await handlePushNotify(post(valid), h.deps);
    assert.equal(response.status, 503, code);
    assert.equal(h.logs[0].severity, "error");
    assert.equal(h.logs[0].fcmCode, code.slice("messaging/".length));
    assertLogsClean(h.logs);
  }
  const odd = harness({ sendError: { code: "messaging/Some free text!" } });
  await handlePushNotify(post(valid), odd.deps);
  assert.equal(odd.logs[0].fcmCode, "unknown");
});

test("non-canonical spellings of a ticket share one bucket", async () => {
  let now = 0;
  const limiter = new TokenBucketLimiter({
    burst: 5,
    refillPerHour: 30,
    now: () => now,
  });
  const h = harness({ limiter });
  // The same token sealed again (as after a re-registration) is a new
  // ticket string but the same device.
  const resealed = sealTicket(keys, {
    token,
    deviceId: "dev_test_device_00001",
    issuedAt: 1760000001,
    platform: "android",
  });
  const spellings = [ticket, resealed];
  for (let index = 0; index < 5; index++) {
    const response = await handlePushNotify(
      post({ ...valid, ticket: spellings[index % 2] }),
      h.deps,
    );
    assert.equal(response.status, 202);
  }
  for (const spelling of spellings) {
    const response = await handlePushNotify(
      post({ ...valid, ticket: spelling }),
      h.deps,
    );
    assert.equal(response.status, 429);
  }
  // A ticket whose last character differs only in unused bits does not open.
  const lastIndex = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    .indexOf(ticket[ticket.length - 1]);
  const nonCanonical = ticket.slice(0, -1) +
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"[lastIndex ^ 1];
  const forged = await handlePushNotify(post({ ...valid, ticket: nonCanonical }), h.deps);
  assert.equal(forged.status, 401);
});

test("routine events cannot use up the approval budget", async () => {
  let now = 0;
  const limiter = new TokenBucketLimiter({
    burst: 5,
    refillPerHour: 30,
    now: () => now,
  });
  const h = harness({ limiter });
  for (let index = 0; index < 5; index++) {
    await handlePushNotify(post({ ...valid, kind: "finished" }), h.deps);
  }
  const limited = await handlePushNotify(post({ ...valid, kind: "alert" }), h.deps);
  assert.equal(limited.status, 429);
  const urgent = await handlePushNotify(post({ ...valid, kind: "permission" }), h.deps);
  assert.equal(urgent.status, 202);
});

test("a send that FCM could not take does not cost the ticket", async () => {
  let failures = 3;
  const sent: TokenMessage[] = [];
  const h = harness();
  const deps = {
    ...h.deps,
    send: async (message: TokenMessage) => {
      if (failures > 0) {
        failures--;
        throw { code: "messaging/server-unavailable" };
      }
      sent.push(message);
      return "ok";
    },
  };
  for (let index = 0; index < 3; index++) {
    assert.equal((await handlePushNotify(post(valid), deps)).status, 503);
  }
  for (let index = 0; index < 5; index++) {
    assert.equal((await handlePushNotify(post(valid), deps)).status, 202);
  }
  assert.equal(sent.length, 5);
});

test("expired and future-dated tickets are refused", async () => {
  for (const issuedAt of [1760000000 - maxTicketAgeSeconds - 1, 1760000000 + 2 * 86400]) {
    const stale = sealTicket(keys, {
      token,
      deviceId: "dev_test_device_00001",
      issuedAt,
    });
    const h = harness();
    const response = await handlePushNotify(post({ ...valid, ticket: stale }), h.deps);
    assert.equal(response.status, 401, String(issuedAt));
  }
});

test("test notifications cannot use up the approval budget", async () => {
  let now = 0;
  const limiter = new TokenBucketLimiter({
    burst: 5,
    refillPerHour: 30,
    now: () => now,
  });
  const h = harness({ limiter });
  for (let index = 0; index < 5; index++) {
    await handlePushNotify(post({ ...valid, kind: "test" }), h.deps);
  }
  const limited = await handlePushNotify(post({ ...valid, kind: "test" }), h.deps);
  assert.equal(limited.status, 429);
  const urgent = await handlePushNotify(post({ ...valid, kind: "permission" }), h.deps);
  assert.equal(urgent.status, 202);
});
