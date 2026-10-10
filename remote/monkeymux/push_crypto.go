package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
)

// pushPayloadInfo is the HKDF info string pinned by docs/push-notifications.md.
const pushPayloadInfo = "monkeyssh-push-v1"

const (
	pushPublicKeyBytes = 32
	pushNonceBytes     = 12
)

var errPushPublicKey = errors.New("invalid push public key")

// decodePushBase64 decodes strict unpadded base64url.
func decodePushBase64(value string) ([]byte, error) {
	return base64.RawURLEncoding.Strict().DecodeString(value)
}

// parsePushPublicKey validates a device's X25519 public key.
func parsePushPublicKey(value string) (*ecdh.PublicKey, error) {
	raw, err := decodePushBase64(value)
	if err != nil || len(raw) != pushPublicKeyBytes {
		return nil, errPushPublicKey
	}
	key, err := ecdh.X25519().NewPublicKey(raw)
	if err != nil {
		return nil, errPushPublicKey
	}
	return key, nil
}

// encryptPushPayload seals plaintext to a device public key with a fresh
// ephemeral key and nonce:
// base64url(ephemeralPublic || nonce || ciphertext || tag).
func encryptPushPayload(devicePublic *ecdh.PublicKey, plaintext []byte) (string, error) {
	ephemeral, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return "", err
	}
	nonce := make([]byte, pushNonceBytes)
	if _, err := rand.Read(nonce); err != nil {
		return "", err
	}
	return encryptPushPayloadWith(devicePublic, plaintext, ephemeral, nonce)
}

// encryptPushPayloadWith is encryptPushPayload with caller-chosen randomness,
// so the shared test vectors can pin the output.
func encryptPushPayloadWith(
	devicePublic *ecdh.PublicKey,
	plaintext []byte,
	ephemeral *ecdh.PrivateKey,
	nonce []byte,
) (string, error) {
	if devicePublic == nil || ephemeral == nil || len(nonce) != pushNonceBytes {
		return "", errPushPublicKey
	}
	// crypto/ecdh rejects an all-zero shared secret (a low-order public key).
	shared, err := ephemeral.ECDH(devicePublic)
	if err != nil {
		return "", err
	}
	ephemeralPublic := ephemeral.PublicKey().Bytes()
	salt := make([]byte, 0, 2*pushPublicKeyBytes)
	salt = append(salt, ephemeralPublic...)
	salt = append(salt, devicePublic.Bytes()...)
	key, err := hkdf.Key(sha256.New, shared, salt, pushPayloadInfo, 32)
	if err != nil {
		return "", err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return "", err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}
	out := make([]byte, 0, len(ephemeralPublic)+len(nonce)+len(plaintext)+aead.Overhead())
	out = append(out, ephemeralPublic...)
	out = append(out, nonce...)
	out = aead.Seal(out, nonce, plaintext, nil)
	return base64.RawURLEncoding.EncodeToString(out), nil
}

// pushCollapseKey derives the opaque per-device, per-window collapse key.
func pushCollapseKey(salt []byte, deviceID string, session string, windowID string) string {
	mac := hmac.New(sha256.New, salt)
	mac.Write([]byte(deviceID))
	mac.Write([]byte{'\n'})
	mac.Write([]byte(session))
	mac.Write([]byte{'\n'})
	mac.Write([]byte(windowID))
	return hex.EncodeToString(mac.Sum(nil))[:32]
}
