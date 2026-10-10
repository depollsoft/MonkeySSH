/**
 * MonkeySSH push notification sender. See docs/push-notifications.md.
 *
 * .github/workflows/deploy-functions.yml deploys this on every push to main
 * that changes it. The PUSH_TICKET_KEYS secret must already exist.
 */
import { initializeApp } from "firebase-admin/app";
import { getMessaging } from "firebase-admin/messaging";
import { setGlobalOptions } from "firebase-functions";
import { HttpsError, onCall, onRequest } from "firebase-functions/https";
import * as logger from "firebase-functions/logger";
import { defineSecret } from "firebase-functions/params";

import { handlePushNotify } from "./notify";
import { TokenBucketLimiter } from "./rateLimit";
import { handleRegisterPushDevice, RegisterError } from "./register";
import { parseTicketKeys, type TicketKeys } from "./ticket";

/** Function region; hosts post to this region's URL. */
export const functionRegion = "us-central1";

/**
 * Runtime identity. It may send FCM messages, verify App Check tokens and read
 * PUSH_TICKET_KEYS, and nothing else; the default compute account is a
 * project Editor, too broad for a public endpoint. Spelled out in full:
 * firebase-tools 15 grants secret access to the literal `name@` shorthand,
 * which IAM rejects.
 */
export const functionServiceAccount =
  "push-functions@monkeyssh.iam.gserviceaccount.com";

// The hard bound on cost and abuse. Billing budgets alert but do not stop
// spending, so this is the real ceiling.
setGlobalOptions({
  region: functionRegion,
  maxInstances: 10,
  serviceAccount: functionServiceAccount,
});

initializeApp();

const ticketKeysSecret = defineSecret("PUSH_TICKET_KEYS");

let cachedKeys: { raw: string; keys: TicketKeys } | undefined;

function ticketKeys(): TicketKeys {
  const raw = ticketKeysSecret.value();
  if (cachedKeys === undefined || cachedKeys.raw !== raw) {
    cachedKeys = { raw, keys: parseTicketKeys(raw) };
  }
  return cachedKeys.keys;
}

const nowSeconds = (): number => Math.floor(Date.now() / 1000);

// Burst 5, 30 per hour, per ticket.
const limiter = new TokenBucketLimiter({ burst: 5, refillPerHour: 30 });

/** Issues a ticket for an App Check-attested app instance. */
export const registerPushDevice = onCall(
  {
    enforceAppCheck: true,
    // The app sends a limited-use token, so a captured token cannot be
    // replayed to mint more tickets.
    consumeAppCheckToken: true,
    secrets: [ticketKeysSecret],
    maxInstances: 5,
    invoker: "public",
  },
  (request) => {
    // consumeAppCheckToken marks a replayed token as alreadyConsumed but does
    // not reject it; a token may mint one ticket only.
    if (request.app?.alreadyConsumed === true) {
      logger.warn("register_push_device", { outcome: "app_check_replayed" });
      throw new HttpsError("unauthenticated", "App Check token already used.");
    }
    try {
      return handleRegisterPushDevice(request.data, {
        keys: ticketKeys,
        nowSeconds,
        log: (entry) => logger.info("register_push_device", entry),
      });
    } catch (error) {
      if (error instanceof RegisterError) {
        throw new HttpsError(error.code, error.message);
      }
      logger.error("register_push_device", { outcome: "internal_error" });
      throw new HttpsError("internal", "Push registration failed.");
    }
  },
);

/**
 * Accepts an encrypted event from a MonkeyMux host and sends it via FCM.
 *
 * The Functions Framework inflates and parses the body before this handler
 * runs, so a small compressed request can expand far past the 4 KB cap. One
 * request per instance keeps such a request from taking others down with it,
 * and the extra memory absorbs ordinary abuse; docs/push-notifications.md
 * describes the remaining exposure.
 */
export const pushNotify = onRequest(
  {
    secrets: [ticketKeysSecret],
    invoker: "public",
    cors: false,
    concurrency: 1,
    memory: "512MiB",
    timeoutSeconds: 15,
  },
  async (req, res) => {
    let keys: TicketKeys;
    try {
      keys = ticketKeys();
    } catch {
      logger.error("push_notify", { outcome: "keys_unavailable" });
      res.status(503).json({ error: "unavailable" });
      return;
    }
    const response = await handlePushNotify(
      {
        method: req.method,
        contentEncoding: req.get("content-encoding"),
        rawBody: req.rawBody,
        body: req.body,
      },
      {
        keys: () => keys,
        limiter,
        send: (message) => getMessaging().send(message),
        log: ({ severity, ...entry }) =>
          severity === "error"
            ? logger.error("push_notify", entry)
            : logger.info("push_notify", entry),
        nowSeconds,
      },
    );
    for (const [name, value] of Object.entries(response.headers ?? {})) {
      res.set(name, value);
    }
    res.status(response.status).json(response.body);
  },
);
