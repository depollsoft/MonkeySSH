import assert from "node:assert/strict";
import { test } from "node:test";

// Importing the entry point initializes firebase-admin without credentials,
// which is fine as long as nothing calls Google.
process.env.GCLOUD_PROJECT ??= "monkeyssh";

interface FakeResponse {
  statusCode: number;
  body: unknown;
  headers: Record<string, string>;
}

function fakeResponse(done: () => void): FakeResponse & Record<string, unknown> {
  const response: FakeResponse & Record<string, unknown> = {
    statusCode: 200,
    body: undefined,
    headers: {},
  };
  response.status = (code: number) => {
    response.statusCode = code;
    return response;
  };
  response.set = (name: string, value: string) => {
    response.headers[name.toLowerCase()] = value;
    return response;
  };
  response.setHeader = response.set;
  response.getHeader = (name: string) => response.headers[name.toLowerCase()];
  response.on = () => response;
  response.json = (body: unknown) => {
    response.body = body;
    done();
    return response;
  };
  response.send = (body: unknown) => {
    response.body = body;
    done();
    return response;
  };
  response.end = () => {
    done();
    return response;
  };
  return response;
}

test("registerPushDevice rejects callers without an App Check token", async () => {
  const { registerPushDevice } = await import("../index");
  const request = {
    method: "POST",
    url: "/",
    header: (name: string) =>
      name.toLowerCase() === "content-type" ? "application/json" : undefined,
    get: (name: string) =>
      name.toLowerCase() === "content-type" ? "application/json" : undefined,
    headers: { "content-type": "application/json" },
    body: { data: { token: "fcm-test-token:APA91bNotARealToken", platform: "ios" } },
    rawBody: Buffer.from("{}"),
  };
  const response = await new Promise<FakeResponse>((resolve) => {
    const res = fakeResponse(() => resolve(res));
    void (registerPushDevice as unknown as (req: unknown, res: unknown) => unknown)(
      request,
      res,
    );
  });
  assert.equal(response.statusCode, 401);
  assert.match(JSON.stringify(response.body), /UNAUTHENTICATED/);
});

test("registerPushDevice refuses an App Check token that was already used", async () => {
  process.env.PUSH_TICKET_KEYS = JSON.stringify({
    current: "k1",
    keys: { k1: Buffer.alloc(32, 1).toString("base64url") },
  });
  const { registerPushDevice } = await import("../index");
  const run = (registerPushDevice as unknown as {
    run: (request: unknown) => unknown;
  }).run;
  const data = { token: "fcm-test-token:APA91bNotARealTokenButLong", platform: "ios" };
  await assert.rejects(
    async () =>
      run({
        data,
        app: { appId: "app", token: {}, alreadyConsumed: true },
        rawRequest: {},
        acceptsStreaming: false,
      }),
    (error: unknown) =>
      (error as { code?: string }).code === "unauthenticated",
  );
  // A fresh token still registers.
  const result = (await run({
    data,
    app: { appId: "app", token: {}, alreadyConsumed: false },
    rawRequest: {},
    acceptsStreaming: false,
  })) as { deviceId: string; ticket: string };
  assert.ok(result.ticket.startsWith("v1.k1."));
});
