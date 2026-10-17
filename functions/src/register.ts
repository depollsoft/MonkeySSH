import { randomBytes } from "node:crypto";

import { encodeBase64Url } from "./base64url";
import {
  isValidDeviceId,
  sealTicket,
  type PushTarget,
  type TicketKeys,
  type TicketPlatform,
} from "./ticket";

/** Callable error codes the register handler can raise. */
export type RegisterErrorCode = "invalid-argument" | "internal";

/** A rejection the HTTP layer turns into a callable error. */
export class RegisterError extends Error {
  constructor(
    readonly code: RegisterErrorCode,
    message: string,
  ) {
    super(message);
  }
}

/** Dependencies of [handleRegisterPushDevice], injected for tests. */
export interface RegisterDeps {
  readonly keys: () => TicketKeys;
  readonly nowSeconds: () => number;
  readonly randomBytes?: (size: number) => Buffer;
  readonly log: (entry: {
    outcome: string;
    platform?: string;
    target?: "fid" | "token";
  }) => void;
}

/** What the app receives. */
export interface RegisterResult {
  readonly deviceId: string;
  readonly ticket: string;
}

// Firebase Installation IDs are 22 base64url characters. FCM validates the
// value itself, so this only bounds it; FCM tokens contain ":" and never match.
const fidPattern = /^[A-Za-z0-9_-]{16,64}$/;
// FCM tokens are printable ASCII without spaces; bound the size generously.
const tokenPattern = /^[\x21-\x7e]{16,4096}$/;

/**
 * The FID the app registered with FCM, or the FCM token an app build from
 * before FID registration sends instead. Exactly one must be present.
 */
function targetOf(fid: unknown, token: unknown): PushTarget | null {
  if (fid !== undefined) {
    return token === undefined && typeof fid === "string" && fidPattern.test(fid)
      ? { fid }
      : null;
  }
  return typeof token === "string" && tokenPattern.test(token) ? { token } : null;
}

/**
 * Seals the caller's FCM registration (its FID, or a token from an older
 * build) and device id into a ticket. App Check is enforced by the callable
 * options before this runs.
 */
export function handleRegisterPushDevice(
  data: unknown,
  deps: RegisterDeps,
): RegisterResult {
  if (typeof data !== "object" || data === null || Array.isArray(data)) {
    deps.log({ outcome: "malformed" });
    throw new RegisterError("invalid-argument", "Expected an object.");
  }
  const { fid, token, platform, deviceId, appNotifications } = data as Record<
    string,
    unknown
  >;
  const target = targetOf(fid, token);
  if (target === null) {
    deps.log({ outcome: "malformed" });
    throw new RegisterError("invalid-argument", "Invalid FID or token.");
  }
  if (platform !== "ios" && platform !== "android") {
    deps.log({ outcome: "malformed" });
    throw new RegisterError("invalid-argument", "Invalid platform.");
  }
  if (deviceId !== undefined && deviceId !== null && !isValidDeviceId(deviceId)) {
    deps.log({ outcome: "malformed", platform });
    throw new RegisterError("invalid-argument", "Invalid device id.");
  }
  let keys: TicketKeys;
  try {
    keys = deps.keys();
  } catch {
    deps.log({ outcome: "keys_unavailable", platform });
    throw new RegisterError("internal", "Push registration is unavailable.");
  }
  const random = deps.randomBytes ?? randomBytes;
  const resolvedDeviceId = isValidDeviceId(deviceId)
    ? deviceId
    : encodeBase64Url(random(16));
  const ticket = sealTicket(keys, {
    target,
    deviceId: resolvedDeviceId,
    issuedAt: deps.nowSeconds(),
    platform: platform as TicketPlatform,
    ...(appNotifications === true ? { appNotifications: true } : {}),
  });
  deps.log({
    outcome: "registered",
    platform,
    target: "fid" in target ? "fid" : "token",
  });
  return { deviceId: resolvedDeviceId, ticket };
}
