const base64UrlPattern = /^[A-Za-z0-9_-]*$/;

/** Encodes bytes as unpadded base64url. */
export function encodeBase64Url(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString("base64url");
}

/**
 * Decodes strict unpadded base64url, returning null for padding, standard
 * base64 characters, whitespace, an impossible length, or non-zero unused
 * trailing bits. Only the canonical spelling of each byte string decodes, as
 * with Go's RawURLEncoding.Strict().
 */
export function decodeBase64Url(value: string): Buffer | null {
  if (!base64UrlPattern.test(value) || value.length % 4 === 1) {
    return null;
  }
  const decoded = Buffer.from(value, "base64url");
  return encodeBase64Url(decoded) === value ? decoded : null;
}
