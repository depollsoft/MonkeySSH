import assert from "node:assert/strict";
import {
  createDecipheriv,
  createHash,
  createPrivateKey,
  createPublicKey,
  diffieHellman,
  hkdfSync,
} from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { test } from "node:test";

import { decodeBase64Url, encodeBase64Url } from "../base64url";
import { openTicket, parseTicketKeys, sealTicket } from "../ticket";

interface Vectors {
  payload: {
    info: string;
    deviceLabel: string;
    ephemeralLabel: string;
    nonceLabel: string;
    devicePublic: string;
    ephemeralPublic: string;
    sharedDigest: string;
    derivedDigest: string;
    plaintext: string;
    payload: string;
    rejected: { reason: string; payload: string }[];
  };
  ticket: {
    keyId: string;
    sealingLabel: string;
    nonceLabel: string;
    aad: string;
    plaintext: string;
    ticket: string;
    rejected: { reason: string; ticket: string; extraKeyId?: string }[];
  };
}

/**
 * Vector material is derived from public labels (SHA-256, truncated), so the
 * shared file holds no key bytes.
 */
function fromLabel(label: string, size: number): Buffer {
  return createHash("sha256").update(label, "utf8").digest().subarray(0, size);
}

function digest(value: Uint8Array): string {
  return createHash("sha256").update(value).digest("hex");
}

/** The ticket keys secret for the vector, built from its label. */
function vectorKeysSecret(extraKeyId?: string): string {
  const { ticket } = vectors;
  const encoded = encodeBase64Url(fromLabel(ticket.sealingLabel, 32));
  const keyMap: Record<string, string> = { [ticket.keyId]: encoded };
  if (extraKeyId !== undefined) {
    keyMap[extraKeyId] = encoded;
  }
  return JSON.stringify({ current: ticket.keyId, keys: keyMap });
}

const vectors = JSON.parse(
  readFileSync(
    resolve(__dirname, "../../../docs/push-notification-vectors.json"),
    "utf8",
  ),
) as Vectors;

function bytes(value: string): Buffer {
  const decoded = decodeBase64Url(value);
  assert.ok(decoded, `not base64url: ${value}`);
  return decoded;
}

function x25519PrivateKey(privateKey: Buffer, publicKey: Buffer) {
  return createPrivateKey({
    key: {
      kty: "OKP",
      crv: "X25519",
      d: encodeBase64Url(privateKey),
      x: encodeBase64Url(publicKey),
    },
    format: "jwk",
  });
}

function x25519PublicKey(publicKey: Buffer) {
  return createPublicKey({
    key: { kty: "OKP", crv: "X25519", x: encodeBase64Url(publicKey) },
    format: "jwk",
  });
}

test("ticket vector seals to the pinned ticket", () => {
  const { ticket } = vectors;
  const keys = parseTicketKeys(vectorKeysSecret());
  const expected = JSON.parse(ticket.plaintext) as {
    t: string;
    d: string;
    i: number;
    p: "ios" | "android";
  };
  const sealed = sealTicket(
    keys,
    { token: expected.t, deviceId: expected.d, issuedAt: expected.i, platform: expected.p },
    fromLabel(ticket.nonceLabel, 12),
  );
  assert.equal(sealed, ticket.ticket);
});

test("ticket vector opens to its contents", () => {
  const { ticket } = vectors;
  const keys = parseTicketKeys(vectorKeysSecret());
  assert.deepEqual(openTicket(keys, ticket.ticket), {
    token: "fcm-vector-token:APA91bExampleTokenForTestVectorsOnly",
    deviceId: "pX7cQe2LrV0sNw4yJk9aTg",
    issuedAt: 1760000000,
    platform: "ios",
  });
});

test("rejected ticket vectors do not open", () => {
  const { ticket } = vectors;
  for (const rejected of ticket.rejected) {
    const keys = parseTicketKeys(vectorKeysSecret(rejected.extraKeyId));
    assert.equal(openTicket(keys, rejected.ticket), null, rejected.reason);
  }
});

test("payload vector decrypts with Node's own X25519, HKDF and AES-GCM", () => {
  const { payload } = vectors;
  const devicePrivate = fromLabel(payload.deviceLabel, 32);
  const devicePublic = bytes(payload.devicePublic);
  const sealed = bytes(payload.payload);
  const ephemeralPublic = sealed.subarray(0, 32);
  assert.deepEqual(ephemeralPublic, bytes(payload.ephemeralPublic));

  const derivedPublic = createPublicKey(
    x25519PrivateKey(devicePrivate, devicePublic),
  ).export({ format: "jwk" }).x;
  assert.equal(derivedPublic, payload.devicePublic);

  const shared = diffieHellman({
    privateKey: x25519PrivateKey(devicePrivate, devicePublic),
    publicKey: x25519PublicKey(ephemeralPublic),
  });
  assert.equal(digest(shared), payload.sharedDigest);
  const key = Buffer.from(
    hkdfSync(
      "sha256",
      shared,
      Buffer.concat([ephemeralPublic, devicePublic]),
      Buffer.from(payload.info, "utf8"),
      32,
    ),
  );
  assert.equal(digest(key), payload.derivedDigest);
  const nonce = sealed.subarray(32, 44);
  assert.deepEqual(nonce, fromLabel(payload.nonceLabel, 12));
  const decipher = createDecipheriv("aes-256-gcm", key, nonce);
  decipher.setAuthTag(sealed.subarray(sealed.length - 16));
  const plaintext = Buffer.concat([
    decipher.update(sealed.subarray(44, sealed.length - 16)),
    decipher.final(),
  ]);
  assert.equal(plaintext.toString("utf8"), payload.plaintext);
});

test("strict base64url rejects padding and standard alphabet", () => {
  assert.equal(decodeBase64Url("YQ=="), null);
  assert.equal(decodeBase64Url("a+b/"), null);
  assert.equal(decodeBase64Url("a b"), null);
  assert.equal(decodeBase64Url("abcde"), null);
  assert.deepEqual(decodeBase64Url("YQ"), Buffer.from("a"));
  // Same byte, unused trailing bits set: not the canonical spelling.
  for (const variant of ["YR", "YS", "YT"]) {
    assert.equal(decodeBase64Url(variant), null, variant);
  }
});
