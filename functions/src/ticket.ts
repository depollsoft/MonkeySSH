import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";

import { decodeBase64Url, encodeBase64Url } from "./base64url";

/** Ticket keys loaded from the PUSH_TICKET_KEYS secret. */
export interface TicketKeys {
  /** Key id used for newly issued tickets. */
  readonly current: string;
  /** Every key id that may still open a ticket. */
  readonly keys: ReadonlyMap<string, Buffer>;
}

/** Platforms a ticket may name. */
export type TicketPlatform = "ios" | "android";

/** The sealed contents of a ticket. */
export interface TicketContents {
  readonly token: string;
  readonly deviceId: string;
  readonly issuedAt: number;
  readonly platform?: TicketPlatform;
}

const ticketVersion = "v1";
const keyIdPattern = /^[A-Za-z0-9_-]{1,32}$/;
const deviceIdPattern = /^[A-Za-z0-9_-]{16,64}$/;
const nonceBytes = 12;
const tagBytes = 16;
const keyBytes = 32;
/**
 * Tickets older than this stop opening. The app fetches a new one at least
 * weekly and hosts receive it on their next attach, so only a host the user
 * has not attached to for this long loses its registration.
 */
export const maxTicketAgeSeconds = 90 * 24 * 60 * 60;
/** Allowed clock skew for a ticket issued "in the future". */
const ticketClockSkewSeconds = 24 * 60 * 60;
/** Upper bound on a ticket the host may send back. */
export const maxTicketLength = 2048;

/** Thrown when PUSH_TICKET_KEYS is missing or malformed. */
export class TicketKeyConfigError extends Error {}

/** Parses the PUSH_TICKET_KEYS secret. */
export function parseTicketKeys(raw: string | undefined): TicketKeys {
  if (raw === undefined || raw.trim() === "") {
    throw new TicketKeyConfigError("ticket keys are not configured");
  }
  let decoded: unknown;
  try {
    decoded = JSON.parse(raw);
  } catch {
    throw new TicketKeyConfigError("ticket keys are not valid JSON");
  }
  if (typeof decoded !== "object" || decoded === null) {
    throw new TicketKeyConfigError("ticket keys must be an object");
  }
  const { current, keys } = decoded as { current?: unknown; keys?: unknown };
  if (typeof current !== "string" || !keyIdPattern.test(current)) {
    throw new TicketKeyConfigError("ticket keys need a valid current key id");
  }
  if (typeof keys !== "object" || keys === null) {
    throw new TicketKeyConfigError("ticket keys need a keys object");
  }
  const parsed = new Map<string, Buffer>();
  for (const [keyId, value] of Object.entries(keys)) {
    if (!keyIdPattern.test(keyId) || typeof value !== "string") {
      throw new TicketKeyConfigError("ticket key ids and values are invalid");
    }
    const key = decodeBase64Url(value);
    if (key === null || key.length !== keyBytes) {
      throw new TicketKeyConfigError("ticket keys must be 32 bytes");
    }
    parsed.set(keyId, key);
  }
  if (!parsed.has(current)) {
    throw new TicketKeyConfigError("the current ticket key is missing");
  }
  return { current, keys: parsed };
}

function aadFor(keyId: string): Buffer {
  return Buffer.from(`${ticketVersion}.${keyId}`, "ascii");
}

/** Seals [contents] under the current key. [nonce] is only for test vectors. */
export function sealTicket(
  keys: TicketKeys,
  contents: TicketContents,
  nonce: Buffer = randomBytes(nonceBytes),
): string {
  const key = keys.keys.get(keys.current);
  if (key === undefined) {
    throw new TicketKeyConfigError("the current ticket key is missing");
  }
  const plaintext = Buffer.from(
    JSON.stringify({
      t: contents.token,
      d: contents.deviceId,
      i: contents.issuedAt,
      ...(contents.platform === undefined ? {} : { p: contents.platform }),
    }),
    "utf8",
  );
  const cipher = createCipheriv("aes-256-gcm", key, nonce, {
    authTagLength: tagBytes,
  });
  cipher.setAAD(aadFor(keys.current));
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const sealed = Buffer.concat([nonce, ciphertext, cipher.getAuthTag()]);
  return `${ticketVersion}.${keys.current}.${encodeBase64Url(sealed)}`;
}

/**
 * Opens a ticket, returning null for anything forged, altered, revoked, or
 * issued more than [maxTicketAgeSeconds] before [nowSeconds].
 */
export function openTicket(
  keys: TicketKeys,
  ticket: unknown,
  nowSeconds?: number,
): TicketContents | null {
  if (typeof ticket !== "string" || ticket.length > maxTicketLength) {
    return null;
  }
  const parts = ticket.split(".");
  if (parts.length !== 3 || parts[0] !== ticketVersion) {
    return null;
  }
  const [, keyId, body] = parts;
  if (!keyIdPattern.test(keyId)) {
    return null;
  }
  const key = keys.keys.get(keyId);
  const sealed = decodeBase64Url(body);
  if (
    key === undefined ||
    sealed === null ||
    sealed.length <= nonceBytes + tagBytes
  ) {
    return null;
  }
  let plaintext: Buffer;
  try {
    const decipher = createDecipheriv(
      "aes-256-gcm",
      key,
      sealed.subarray(0, nonceBytes),
      { authTagLength: tagBytes },
    );
    decipher.setAAD(aadFor(keyId));
    decipher.setAuthTag(sealed.subarray(sealed.length - tagBytes));
    plaintext = Buffer.concat([
      decipher.update(sealed.subarray(nonceBytes, sealed.length - tagBytes)),
      decipher.final(),
    ]);
  } catch {
    return null;
  }
  let decoded: unknown;
  try {
    decoded = JSON.parse(plaintext.toString("utf8"));
  } catch {
    return null;
  }
  if (typeof decoded !== "object" || decoded === null) {
    return null;
  }
  const { t, d, i, p } = decoded as Record<string, unknown>;
  if (
    typeof t !== "string" ||
    t.length === 0 ||
    typeof d !== "string" ||
    !deviceIdPattern.test(d) ||
    typeof i !== "number" ||
    !Number.isSafeInteger(i)
  ) {
    return null;
  }
  if (
    nowSeconds !== undefined &&
    (nowSeconds - i > maxTicketAgeSeconds ||
      i - nowSeconds > ticketClockSkewSeconds)
  ) {
    return null;
  }
  const platform = p === "ios" || p === "android" ? p : undefined;
  return { token: t, deviceId: d, issuedAt: i, platform };
}

/** Whether [value] is an acceptable device id. */
export function isValidDeviceId(value: unknown): value is string {
  return typeof value === "string" && deviceIdPattern.test(value);
}
