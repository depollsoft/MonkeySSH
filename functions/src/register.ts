import { randomBytes } from "node:crypto";

import { encodeBase64Url } from "./base64url";
import {
  isValidDeviceId,
  sealTicket,
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
  readonly log: (entry: { outcome: string; platform?: string }) => void;
}

/** What the app receives. */
export interface RegisterResult {
  readonly deviceId: string;
  readonly ticket: string;
}

// FCM tokens are printable ASCII without spaces; bound the size generously.
const tokenPattern = /^[\x21-\x7e]{16,4096}$/;

/**
 * Seals the caller's FCM token and device id into a ticket. App Check is
 * enforced by the callable options before this runs.
 */
export function handleRegisterPushDevice(
  data: unknown,
  deps: RegisterDeps,
): RegisterResult {
  if (typeof data !== "object" || data === null || Array.isArray(data)) {
    deps.log({ outcome: "malformed" });
    throw new RegisterError("invalid-argument", "Expected an object.");
  }
  const { token, platform, deviceId } = data as Record<string, unknown>;
  if (typeof token !== "string" || !tokenPattern.test(token)) {
    deps.log({ outcome: "malformed" });
    throw new RegisterError("invalid-argument", "Invalid token.");
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
    token,
    deviceId: resolvedDeviceId,
    issuedAt: deps.nowSeconds(),
    platform: platform as TicketPlatform,
  });
  deps.log({ outcome: "registered", platform });
  return { deviceId: resolvedDeviceId, ticket };
}
