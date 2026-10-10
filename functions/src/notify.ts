import { createHash } from "node:crypto";

import type { TokenMessage } from "firebase-admin/messaging";

import { decodeBase64Url } from "./base64url";
import { budgetFor, buildFcmMessage, isPushKind, type PushKind } from "./message";
import type { TokenBucketLimiter } from "./rateLimit";
import { maxTicketLength, openTicket, type TicketKeys } from "./ticket";

/** Largest accepted request body. */
export const maxBodyBytes = 4096;
/** Largest accepted payload field, in base64url characters. */
export const maxPayloadLength = 3072;
/** Ephemeral key, nonce, tag and at least one plaintext byte. */
const minPayloadBytes = 32 + 12 + 16 + 1;
const collapsePattern = /^[A-Za-z0-9_-]{1,64}$/;

/** Structured outcome written to the function log. */
export interface NotifyLogEntry {
  readonly outcome: string;
  readonly kind?: PushKind;
  readonly platform?: string;
  /** The FCM error code (a fixed enum such as "third-party-auth-error"). */
  readonly fcmCode?: string;
  /** Project-side failures the owner must fix are logged as errors. */
  readonly severity?: "error";
}

/** Dependencies of [handlePushNotify], injected for tests. */
export interface NotifyDeps {
  readonly keys: () => TicketKeys;
  readonly limiter: TokenBucketLimiter;
  readonly send: (message: TokenMessage) => Promise<unknown>;
  readonly log: (entry: NotifyLogEntry) => void;
  readonly nowSeconds: () => number;
}

/** The parts of an HTTP request the handler reads. */
export interface NotifyRequest {
  readonly method: string;
  /** The Content-Encoding request header, if any. */
  readonly contentEncoding?: string;
  readonly rawBody?: Buffer;
  readonly body: unknown;
}

/** What the HTTP layer writes back. */
export interface NotifyResponse {
  readonly status: number;
  readonly body: Record<string, string>;
  readonly headers?: Record<string, string>;
}

// Only errors about the token itself make hosts delete the registration.
const unregisteredCodes = new Set([
  "registration-token-not-registered",
  "invalid-registration-token",
  "installation-id-not-registered",
]);
// Errors that mean this project is misconfigured (IAM, FCM API disabled,
// APNs key missing). Hosts retry later instead of deleting registrations.
const projectErrorCodes = new Set([
  "mismatched-credential",
  "third-party-auth-error",
  "authentication-error",
]);
const rateLimitedCodes = new Set([
  "device-message-rate-exceeded",
  "message-rate-exceeded",
]);
const malformedCodes = new Set([
  "invalid-argument",
  "invalid-payload",
  "invalid-data-payload-key",
  "payload-size-limit-exceeded",
  "invalid-options",
  "invalid-recipient",
]);

function messagingErrorCode(error: unknown): string {
  if (typeof error !== "object" || error === null) {
    return "unknown";
  }
  const code = (error as { code?: unknown }).code;
  if (typeof code !== "string") {
    return "unknown";
  }
  const bare = code.startsWith("messaging/")
    ? code.slice("messaging/".length)
    : code;
  // Only the fixed enum is ever logged, never free text.
  return /^[a-z0-9-]{1,64}$/.test(bare) ? bare : "unknown";
}

function respond(
  deps: NotifyDeps,
  status: number,
  body: Record<string, string>,
  log: NotifyLogEntry,
  headers?: Record<string, string>,
): NotifyResponse {
  deps.log(log);
  return { status, body, headers };
}

/**
 * Validates a host's event, opens its ticket, applies the rate limit and
 * forwards it to FCM. Never logs the ticket, token, collapse key or payload.
 */
export async function handlePushNotify(
  request: NotifyRequest,
  deps: NotifyDeps,
): Promise<NotifyResponse> {
  if (request.method !== "POST") {
    return respond(
      deps,
      405,
      { error: "method" },
      { outcome: "method_not_allowed" },
      { Allow: "POST" },
    );
  }
  const encoding = request.contentEncoding?.trim().toLowerCase();
  if (encoding !== undefined && encoding !== "" && encoding !== "identity") {
    return respond(
      deps,
      415,
      { error: "encoding" },
      { outcome: "unsupported_encoding" },
    );
  }
  if (request.rawBody !== undefined && request.rawBody.length > maxBodyBytes) {
    return respond(deps, 413, { error: "too_large" }, { outcome: "too_large" });
  }
  const body = request.body;
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return respond(deps, 400, { error: "malformed" }, { outcome: "malformed" });
  }
  const { ticket, kind, collapse, payload } = body as Record<string, unknown>;
  if (!isPushKind(kind)) {
    return respond(deps, 400, { error: "malformed" }, { outcome: "malformed" });
  }
  if (
    typeof ticket !== "string" ||
    ticket.length > maxTicketLength ||
    typeof collapse !== "string" ||
    !collapsePattern.test(collapse) ||
    typeof payload !== "string" ||
    payload.length > maxPayloadLength
  ) {
    return respond(
      deps,
      400,
      { error: "malformed" },
      { outcome: "malformed", kind },
    );
  }
  const payloadBytes = decodeBase64Url(payload);
  if (payloadBytes === null || payloadBytes.length < minPayloadBytes) {
    return respond(
      deps,
      400,
      { error: "malformed" },
      { outcome: "malformed", kind },
    );
  }
  const contents = openTicket(deps.keys(), ticket, deps.nowSeconds());
  if (contents === null) {
    return respond(
      deps,
      401,
      { error: "bad_ticket" },
      { outcome: "bad_ticket", kind },
    );
  }
  const platform = contents.platform ?? "unknown";
  // Keyed on the FCM token (not the ticket text, which has many spellings
  // across re-registrations) and split by urgency, so routine events can
  // never use up the allowance approval requests need.
  const bucket = `${createHash("sha256").update(contents.token).digest("hex")}:${budgetFor(kind)}`;
  const decision = deps.limiter.take(bucket);
  if (!decision.allowed) {
    return respond(
      deps,
      429,
      { error: "rate_limited" },
      { outcome: "rate_limited", kind, platform },
      { "Retry-After": String(decision.retryAfterSeconds) },
    );
  }
  const message = buildFcmMessage({
    token: contents.token,
    kind,
    collapse,
    payload,
    platform: contents.platform,
    nowSeconds: deps.nowSeconds(),
  });
  try {
    await deps.send(message);
  } catch (error) {
    const fcmCode = messagingErrorCode(error);
    if (unregisteredCodes.has(fcmCode)) {
      return respond(
        deps,
        410,
        { error: "unregistered" },
        { outcome: "unregistered", kind, platform, fcmCode },
      );
    }
    if (rateLimitedCodes.has(fcmCode)) {
      return respond(
        deps,
        429,
        { error: "rate_limited" },
        { outcome: "fcm_rate_limited", kind, platform, fcmCode },
        { "Retry-After": "60" },
      );
    }
    if (malformedCodes.has(fcmCode)) {
      return respond(
        deps,
        400,
        { error: "malformed" },
        { outcome: "fcm_rejected", kind, platform, fcmCode },
      );
    }
    // The message never reached a device, so the retry is free.
    deps.limiter.refund(bucket);
    if (projectErrorCodes.has(fcmCode)) {
      return respond(
        deps,
        503,
        { error: "unavailable" },
        {
          outcome: "fcm_project_error",
          kind,
          platform,
          fcmCode,
          severity: "error",
        },
      );
    }
    return respond(
      deps,
      503,
      { error: "unavailable" },
      { outcome: "fcm_unavailable", kind, platform, fcmCode },
    );
  }
  return respond(
    deps,
    202,
    { status: "sent" },
    { outcome: "sent", kind, platform },
  );
}
