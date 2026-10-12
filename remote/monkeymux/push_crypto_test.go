package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/hkdf"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

type pushVectorFile struct {
	Payload struct {
		Info            string `json:"info"`
		DeviceLabel     string `json:"deviceLabel"`
		EphemeralLabel  string `json:"ephemeralLabel"`
		NonceLabel      string `json:"nonceLabel"`
		DevicePublic    string `json:"devicePublic"`
		EphemeralPublic string `json:"ephemeralPublic"`
		SharedDigest    string `json:"sharedDigest"`
		DerivedDigest   string `json:"derivedDigest"`
		Plaintext       string `json:"plaintext"`
		Payload         string `json:"payload"`
		Rejected        []struct {
			Reason  string `json:"reason"`
			Payload string `json:"payload"`
		} `json:"rejected"`
	} `json:"payload"`
}

// pushVectorBytes derives vector material from a public label: SHA-256 of the
// label, truncated to size. The shared file holds labels, never key bytes.
func pushVectorBytes(label string, size int) []byte {
	sum := sha256.Sum256([]byte(label))
	return sum[:size]
}

func pushDigest(value []byte) string {
	sum := sha256.Sum256(value)
	return hex.EncodeToString(sum[:])
}

func loadPushVectors(t *testing.T) pushVectorFile {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "docs", "push-notification-vectors.json"))
	if err != nil {
		t.Fatalf("read shared push vectors: %v", err)
	}
	var vectors pushVectorFile
	if err := json.Unmarshal(data, &vectors); err != nil {
		t.Fatal(err)
	}
	return vectors
}

func mustPushBytes(t *testing.T, value string) []byte {
	t.Helper()
	decoded, err := decodePushBase64(value)
	if err != nil {
		t.Fatalf("decode %q: %v", value, err)
	}
	return decoded
}

// openPushPayloadForTest is the device side of the payload format, used to
// check what the host sends.
func openPushPayloadForTest(t *testing.T, devicePrivate *ecdh.PrivateKey, payload string) []byte {
	t.Helper()
	sealed := mustPushBytes(t, payload)
	if len(sealed) < 32+12+16 {
		t.Fatalf("payload too short: %d", len(sealed))
	}
	ephemeral, err := ecdh.X25519().NewPublicKey(sealed[:32])
	if err != nil {
		t.Fatal(err)
	}
	shared, err := devicePrivate.ECDH(ephemeral)
	if err != nil {
		t.Fatal(err)
	}
	salt := append(append([]byte{}, sealed[:32]...), devicePrivate.PublicKey().Bytes()...)
	key, err := hkdf.Key(sha256.New, shared, salt, pushPayloadInfo, 32)
	if err != nil {
		t.Fatal(err)
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		t.Fatal(err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		t.Fatal(err)
	}
	plaintext, err := aead.Open(nil, sealed[32:44], sealed[44:], nil)
	if err != nil {
		t.Fatalf("open payload: %v", err)
	}
	return plaintext
}

func TestPushPayloadMatchesSharedVector(t *testing.T) {
	vector := loadPushVectors(t).Payload
	if vector.Info != pushPayloadInfo {
		t.Fatalf("info = %q, want %q", vector.Info, pushPayloadInfo)
	}
	device, err := ecdh.X25519().NewPrivateKey(pushVectorBytes(vector.DeviceLabel, 32))
	if err != nil {
		t.Fatal(err)
	}
	if got := base64.RawURLEncoding.EncodeToString(device.PublicKey().Bytes()); got != vector.DevicePublic {
		t.Fatalf("device public key = %s, want %s", got, vector.DevicePublic)
	}
	ephemeral, err := ecdh.X25519().NewPrivateKey(pushVectorBytes(vector.EphemeralLabel, 32))
	if err != nil {
		t.Fatal(err)
	}
	if got := base64.RawURLEncoding.EncodeToString(ephemeral.PublicKey().Bytes()); got != vector.EphemeralPublic {
		t.Fatalf("ephemeral public key = %s, want %s", got, vector.EphemeralPublic)
	}
	shared, err := ephemeral.ECDH(device.PublicKey())
	if err != nil {
		t.Fatal(err)
	}
	if got := pushDigest(shared); got != vector.SharedDigest {
		t.Fatalf("X25519 output digest = %s", got)
	}
	salt := append(append([]byte{}, ephemeral.PublicKey().Bytes()...), device.PublicKey().Bytes()...)
	derived, err := hkdf.Key(sha256.New, shared, salt, pushPayloadInfo, 32)
	if err != nil {
		t.Fatal(err)
	}
	if got := pushDigest(derived); got != vector.DerivedDigest {
		t.Fatalf("HKDF output digest = %s", got)
	}
	devicePublic, err := parsePushPublicKey(vector.DevicePublic)
	if err != nil {
		t.Fatal(err)
	}
	payload, err := encryptPushPayloadWith(
		devicePublic,
		[]byte(vector.Plaintext),
		ephemeral,
		pushVectorBytes(vector.NonceLabel, pushNonceBytes),
	)
	if err != nil {
		t.Fatal(err)
	}
	if payload != vector.Payload {
		t.Fatalf("payload = %s\nwant      %s", payload, vector.Payload)
	}
	if got := string(openPushPayloadForTest(t, device, payload)); got != vector.Plaintext {
		t.Fatalf("round trip = %s", got)
	}
}

func TestPushPayloadRandomizedRoundTripAndRejections(t *testing.T) {
	vectors := loadPushVectors(t)
	device, err := ecdh.X25519().NewPrivateKey(pushVectorBytes(vectors.Payload.DeviceLabel, 32))
	if err != nil {
		t.Fatal(err)
	}
	first, err := encryptPushPayload(device.PublicKey(), []byte(`{"v":1}`))
	if err != nil {
		t.Fatal(err)
	}
	second, err := encryptPushPayload(device.PublicKey(), []byte(`{"v":1}`))
	if err != nil {
		t.Fatal(err)
	}
	if first == second {
		t.Fatal("two payloads reused the ephemeral key or nonce")
	}
	if got := string(openPushPayloadForTest(t, device, first)); got != `{"v":1}` {
		t.Fatalf("round trip = %q", got)
	}
	for _, rejected := range vectors.Payload.Rejected {
		sealed, err := decodePushBase64(rejected.Payload)
		if err != nil {
			continue
		}
		if len(sealed) < 32+12+16 {
			continue
		}
		ephemeral, err := ecdh.X25519().NewPublicKey(sealed[:32])
		if err != nil {
			continue
		}
		shared, _ := device.ECDH(ephemeral)
		salt := append(append([]byte{}, sealed[:32]...), device.PublicKey().Bytes()...)
		key, _ := hkdf.Key(sha256.New, shared, salt, pushPayloadInfo, 32)
		block, _ := aes.NewCipher(key)
		aead, _ := cipher.NewGCM(block)
		if _, err := aead.Open(nil, sealed[32:44], sealed[44:], nil); err == nil {
			t.Fatalf("rejected vector opened: %s", rejected.Reason)
		}
	}
}

func TestPushPublicKeyValidation(t *testing.T) {
	for _, value := range []string{
		"",
		"short",
		base64.StdEncoding.EncodeToString(make([]byte, 32)),
		base64.RawURLEncoding.EncodeToString(make([]byte, 31)),
	} {
		if _, err := parsePushPublicKey(value); err == nil {
			t.Fatalf("accepted public key %q", value)
		}
	}
	// The all-zero point is a low-order key; the shared secret would be zero.
	zero, err := parsePushPublicKey(base64.RawURLEncoding.EncodeToString(make([]byte, 32)))
	if err == nil {
		if _, err := encryptPushPayload(zero, []byte("x")); err == nil {
			t.Fatal("encrypted to a low-order public key")
		}
	}
}

func TestPushCollapseKeyIsStableAndOpaque(t *testing.T) {
	salt := make([]byte, 32)
	first := pushCollapseKey(salt, "device-aaaaaaaaaaaaaaaa", "main", "@3")
	if first != pushCollapseKey(salt, "device-aaaaaaaaaaaaaaaa", "main", "@3") {
		t.Fatal("collapse key is not stable")
	}
	if len(first) != 32 {
		t.Fatalf("collapse key length = %d", len(first))
	}
	for _, other := range []string{
		pushCollapseKey(salt, "device-bbbbbbbbbbbbbbbb", "main", "@3"),
		pushCollapseKey(salt, "device-aaaaaaaaaaaaaaaa", "main", "@4"),
		pushCollapseKey(salt, "device-aaaaaaaaaaaaaaaa", "mai", "n@3"),
		pushCollapseKey([]byte("other"), "device-aaaaaaaaaaaaaaaa", "main", "@3"),
	} {
		if other == first {
			t.Fatal("collapse keys collided")
		}
	}
}
