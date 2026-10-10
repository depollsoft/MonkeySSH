import assert from "node:assert/strict";
import { test } from "node:test";

import { encodeBase64Url } from "../base64url";
import { handleRegisterPushDevice, RegisterError, type RegisterDeps } from "../register";
import { openTicket, parseTicketKeys, TicketKeyConfigError } from "../ticket";

const keys = parseTicketKeys(
  JSON.stringify({
    current: "k2",
    keys: {
      k1: encodeBase64Url(Buffer.alloc(32, 1)),
      k2: encodeBase64Url(Buffer.alloc(32, 2)),
    },
  }),
);
const token = "fcm-test-token:APA91bNotARealTokenButLongEnough";

function deps(overrides: Partial<RegisterDeps> = {}): {
  deps: RegisterDeps;
  logs: unknown[];
} {
  const logs: unknown[] = [];
  return {
    logs,
    deps: {
      keys: () => keys,
      nowSeconds: () => 1760000123,
      randomBytes: (size) => Buffer.alloc(size, 0xab),
      log: (entry) => logs.push(entry),
      ...overrides,
    },
  };
}

test("registration seals the token and a new device id under the current key", () => {
  const { deps: d, logs } = deps();
  const result = handleRegisterPushDevice({ token, platform: "ios" }, d);
  assert.equal(result.deviceId, encodeBase64Url(Buffer.alloc(16, 0xab)));
  assert.ok(result.ticket.startsWith("v1.k2."));
  assert.ok(!result.ticket.includes(token));
  assert.deepEqual(openTicket(keys, result.ticket), {
    token,
    deviceId: result.deviceId,
    issuedAt: 1760000123,
    platform: "ios",
  });
  assert.ok(!JSON.stringify(logs).includes(token));
});

test("an existing device id is kept across re-registration", () => {
  const { deps: d } = deps();
  const result = handleRegisterPushDevice(
    { token, platform: "android", deviceId: "keepThisDeviceId_123" },
    d,
  );
  assert.equal(result.deviceId, "keepThisDeviceId_123");
});

test("tickets under a dropped key id stop opening", () => {
  const { deps: d } = deps();
  const result = handleRegisterPushDevice({ token, platform: "ios" }, d);
  const rotated = parseTicketKeys(
    JSON.stringify({ current: "k1", keys: { k1: encodeBase64Url(Buffer.alloc(32, 1)) } }),
  );
  assert.equal(openTicket(rotated, result.ticket), null);
});

test("bad requests are invalid-argument", () => {
  const cases: unknown[] = [
    null,
    "token",
    { platform: "ios" },
    { token: "short", platform: "ios" },
    { token: `${token} space`, platform: "ios" },
    { token, platform: "web" },
    { token, platform: "ios", deviceId: "bad id" },
  ];
  for (const data of cases) {
    const { deps: d } = deps();
    assert.throws(
      () => handleRegisterPushDevice(data, d),
      (error: unknown) =>
        error instanceof RegisterError && error.code === "invalid-argument",
    );
  }
});

test("missing keys are an internal error", () => {
  const { deps: d } = deps({
    keys: () => {
      throw new TicketKeyConfigError("missing");
    },
  });
  assert.throws(
    () => handleRegisterPushDevice({ token, platform: "ios" }, d),
    (error: unknown) => error instanceof RegisterError && error.code === "internal",
  );
});

test("the keys secret is validated", () => {
  for (const raw of [
    undefined,
    "",
    "{",
    "[]",
    JSON.stringify({ current: "k1", keys: {} }),
    JSON.stringify({ current: "k1", keys: { k1: "c2hvcnQ" } }),
    JSON.stringify({ current: "bad id", keys: {} }),
  ]) {
    assert.throws(() => parseTicketKeys(raw), TicketKeyConfigError);
  }
});
