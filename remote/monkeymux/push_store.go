package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

const (
	pushStateSchemaVersion   = 1
	pushStateFileMode        = 0o600
	pushStateDirMode         = 0o700
	pushMaxDevices           = 8
	pushMaxRecordsPerDevice  = 4
	pushMaxTicketLength      = 2048
	pushStoreRecheckInterval = time.Second
	// A registration the app has not refreshed in this long belongs to a
	// saved host it no longer uses (the app re-registers on every attach).
	pushRecordTTL = 30 * 24 * time.Hour
	// Rejected tickets are remembered so a fresh attach that offers the same
	// ticket is told to fetch a new one instead of reinstalling it.
	pushRejectedLimit       = 32
	pushRejectedTTL         = 30 * 24 * time.Hour
	pushStateLockTimeout    = 2 * time.Second
	pushStateLockRetryDelay = 10 * time.Millisecond
)

// Why a ticket was rejected, as the app is told on its next push_register.
const (
	pushRejectedBadTicket    = "bad_ticket"
	pushRejectedUnregistered = "unregistered"
)

var (
	pushDeviceIDPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{16,64}$`)
	pushHostRefPattern  = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)
	pushTicketPattern   = regexp.MustCompile(`^v1\.[A-Za-z0-9_-]{1,32}\.[A-Za-z0-9_-]+$`)

	errPushInvalidDeviceID = errors.New("invalid push device id")
	errPushInvalidTicket   = errors.New("invalid push ticket")
	errPushInvalidHostRef  = errors.New("invalid push host reference")
	errPushStateVersion    = errors.New("push registrations were written by a newer MonkeyMux")
	errPushStateLocked     = errors.New("push registrations are locked by another MonkeyMux")
)

// pushDeviceRecord is one registration: a device, as reached through one of
// the app's saved hosts. Two saved hosts that reach the same machine user
// register separately and can be turned off separately.
type pushDeviceRecord struct {
	DeviceID     string `json:"deviceId"`
	Ticket       string `json:"ticket"`
	PublicKey    string `json:"publicKey"`
	HostRef      string `json:"hostRef"`
	RegisteredAt int64  `json:"registeredAt"`
	UpdatedAt    int64  `json:"updatedAt"`
}

// pushRejectedTicket remembers a ticket the function refused for good.
type pushRejectedTicket struct {
	DeviceID   string `json:"deviceId"`
	TicketHash string `json:"ticketHash"`
	Reason     string `json:"reason"`
	At         int64  `json:"at"`
}

type pushStateFile struct {
	Version  int                  `json:"version"`
	Salt     string               `json:"salt,omitempty"`
	Devices  []pushDeviceRecord   `json:"devices"`
	Rejected []pushRejectedTicket `json:"rejected,omitempty"`
}

// pushStatePath is the per-user registration file shared by every server.
var pushStatePath = func() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".monkeyssh", "state", "push-devices.json"), nil
}

func pushTicketHash(ticket string) string {
	sum := sha256.Sum256([]byte(ticket))
	return hex.EncodeToString(sum[:16])
}

func validatePushRecord(record pushDeviceRecord) error {
	if !pushDeviceIDPattern.MatchString(record.DeviceID) {
		return errPushInvalidDeviceID
	}
	if len(record.Ticket) > pushMaxTicketLength || !pushTicketPattern.MatchString(record.Ticket) {
		return errPushInvalidTicket
	}
	if _, err := parsePushPublicKey(record.PublicKey); err != nil {
		return err
	}
	if !pushHostRefPattern.MatchString(record.HostRef) {
		return errPushInvalidHostRef
	}
	return nil
}

// prunePushState drops invalid and expired entries in place.
func prunePushState(state *pushStateFile, now time.Time) {
	devices := state.Devices[:0]
	for _, record := range state.Devices {
		if validatePushRecord(record) != nil ||
			now.Sub(time.Unix(record.UpdatedAt, 0)) > pushRecordTTL {
			continue
		}
		devices = append(devices, record)
	}
	state.Devices = devices
	rejected := state.Rejected[:0]
	for _, entry := range state.Rejected {
		if now.Sub(time.Unix(entry.At, 0)) > pushRejectedTTL {
			continue
		}
		rejected = append(rejected, entry)
	}
	state.Rejected = rejected
}

// upsertPushRecord adds or refreshes record and enforces the device caps.
func upsertPushRecord(state *pushStateFile, record pushDeviceRecord, now time.Time) {
	record.UpdatedAt = now.Unix()
	record.RegisteredAt = record.UpdatedAt
	replaced := false
	for index := range state.Devices {
		existing := state.Devices[index]
		if existing.DeviceID != record.DeviceID {
			continue
		}
		if existing.HostRef == record.HostRef {
			record.RegisteredAt = existing.RegisteredAt
			state.Devices[index] = record
			replaced = true
			continue
		}
		// One device has one ticket and key; keep its other saved hosts on
		// the newest ones.
		state.Devices[index].Ticket = record.Ticket
		state.Devices[index].PublicKey = record.PublicKey
	}
	if !replaced {
		state.Devices = append(state.Devices, record)
	}
	// The device now holds a ticket that was not rejected, so its older
	// rejections no longer matter.
	kept := state.Rejected[:0]
	for _, entry := range state.Rejected {
		if entry.DeviceID != record.DeviceID {
			kept = append(kept, entry)
		}
	}
	state.Rejected = kept
	enforcePushCaps(state)
}

func enforcePushCaps(state *pushStateFile) {
	// Records per device: drop that device's least recently updated ones.
	byDevice := map[string][]int{}
	for index, record := range state.Devices {
		byDevice[record.DeviceID] = append(byDevice[record.DeviceID], index)
	}
	drop := map[int]bool{}
	for _, indexes := range byDevice {
		if len(indexes) <= pushMaxRecordsPerDevice {
			continue
		}
		sort.Slice(indexes, func(a, b int) bool {
			return state.Devices[indexes[a]].UpdatedAt < state.Devices[indexes[b]].UpdatedAt
		})
		for _, index := range indexes[:len(indexes)-pushMaxRecordsPerDevice] {
			drop[index] = true
		}
	}
	// Devices: drop whole devices, least recently updated first.
	type deviceAge struct {
		id      string
		updated int64
	}
	ages := make([]deviceAge, 0, len(byDevice))
	for id, indexes := range byDevice {
		latest := int64(0)
		for _, index := range indexes {
			if state.Devices[index].UpdatedAt > latest {
				latest = state.Devices[index].UpdatedAt
			}
		}
		ages = append(ages, deviceAge{id, latest})
	}
	sort.Slice(ages, func(a, b int) bool { return ages[a].updated < ages[b].updated })
	evicted := map[string]bool{}
	for len(ages)-len(evicted) > pushMaxDevices {
		evicted[ages[len(evicted)].id] = true
	}
	kept := state.Devices[:0]
	for index, record := range state.Devices {
		if drop[index] || evicted[record.DeviceID] {
			continue
		}
		kept = append(kept, record)
	}
	state.Devices = kept
}

// rejectPushTicket removes every registration carrying ticket and records why.
func rejectPushTicket(state *pushStateFile, deviceID string, ticket string, reason string, now time.Time) bool {
	changed := false
	kept := state.Devices[:0]
	for _, record := range state.Devices {
		if record.DeviceID == deviceID && record.Ticket == ticket {
			changed = true
			continue
		}
		kept = append(kept, record)
	}
	state.Devices = kept
	hash := pushTicketHash(ticket)
	for _, entry := range state.Rejected {
		if entry.DeviceID == deviceID && entry.TicketHash == hash {
			return changed
		}
	}
	state.Rejected = append(state.Rejected, pushRejectedTicket{
		DeviceID:   deviceID,
		TicketHash: hash,
		Reason:     reason,
		At:         now.Unix(),
	})
	for len(state.Rejected) > pushRejectedLimit {
		state.Rejected = state.Rejected[1:]
	}
	return true
}

// pushRejectionFor reports why ticket was rejected for deviceID, if it was.
func pushRejectionFor(state pushStateFile, deviceID string, ticket string) string {
	hash := pushTicketHash(ticket)
	for _, entry := range state.Rejected {
		if entry.DeviceID == deviceID && entry.TicketHash == hash {
			return entry.Reason
		}
	}
	return ""
}

// pushStore reads and writes the registration file. Every server for the user
// shares it, so each read and each read-modify-write holds an exclusive lock
// on a sidecar file. Readers reload when the file changed, checking at most
// once per pushStoreRecheckInterval.
type pushStore struct {
	mu         sync.Mutex
	now        func() time.Time
	loaded     bool
	modTime    time.Time
	size       int64
	lastCheck  time.Time
	state      pushStateFile
	hasRecords atomic.Bool
}

// lockPushState takes the cross-process lock for the registration file.
func lockPushState(statePath string) (func(), error) {
	dir := filepath.Dir(statePath)
	if err := os.MkdirAll(dir, pushStateDirMode); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(statePath+".lock", os.O_RDWR|os.O_CREATE, pushStateFileMode)
	if err != nil {
		return nil, err
	}
	deadline := time.Now().Add(pushStateLockTimeout)
	for {
		locked, err := tryLockPushStateFile(file)
		if locked {
			return func() {
				unlockPushStateFile(file)
				_ = file.Close()
			}, nil
		}
		if err != nil || time.Now().After(deadline) {
			_ = file.Close()
			if err == nil {
				err = errPushStateLocked
			}
			return nil, err
		}
		time.Sleep(pushStateLockRetryDelay)
	}
}

// readPushStateFile reads and parses the file. A missing file is empty state;
// a file from a newer schema is reported so it is never overwritten.
func readPushStateFile(path string) (pushStateFile, error) {
	empty := pushStateFile{Version: pushStateSchemaVersion}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return empty, nil
	}
	if err != nil {
		return empty, err
	}
	var parsed pushStateFile
	if json.Unmarshal(data, &parsed) != nil {
		// A corrupt file holds nothing worth keeping.
		return empty, nil
	}
	if parsed.Version > pushStateSchemaVersion {
		return empty, errPushStateVersion
	}
	if parsed.Version != pushStateSchemaVersion {
		return empty, nil
	}
	return parsed, nil
}

func (st *pushStore) setStateLocked(state pushStateFile) {
	st.state = state
	st.hasRecords.Store(len(state.Devices) > 0)
}

func (st *pushStore) refreshLocked() {
	now := st.now()
	if st.loaded && now.Sub(st.lastCheck) < pushStoreRecheckInterval {
		return
	}
	st.lastCheck = now
	path, err := pushStatePath()
	if err != nil {
		return
	}
	info, err := os.Stat(path)
	if err != nil {
		st.loaded = true
		st.modTime = time.Time{}
		st.size = 0
		st.setStateLocked(pushStateFile{Version: pushStateSchemaVersion})
		return
	}
	if st.loaded && info.ModTime().Equal(st.modTime) && info.Size() == st.size {
		// Expiry still applies to an unchanged file.
		state := st.state
		prunePushState(&state, now)
		st.setStateLocked(state)
		return
	}
	unlock, err := lockPushState(path)
	if err != nil {
		return
	}
	defer unlock()
	state, _ := readPushStateFile(path)
	if info, err := os.Stat(path); err == nil {
		st.modTime = info.ModTime()
		st.size = info.Size()
	}
	st.loaded = true
	prunePushState(&state, now)
	st.setStateLocked(state)
}

// snapshot returns the live registrations and the collapse-key salt.
func (st *pushStore) snapshot() ([]pushDeviceRecord, []byte) {
	st.mu.Lock()
	defer st.mu.Unlock()
	st.refreshLocked()
	devices := append([]pushDeviceRecord(nil), st.state.Devices...)
	salt, _ := decodePushBase64(st.state.Salt)
	return devices, salt
}

// rejection reports whether ticket was rejected for deviceID.
func (st *pushStore) rejection(deviceID string, ticket string) string {
	st.mu.Lock()
	defer st.mu.Unlock()
	st.refreshLocked()
	return pushRejectionFor(st.state, deviceID, ticket)
}

// hasDevices refreshes the cache and reports whether anything is registered.
func (st *pushStore) hasDevices() bool {
	st.mu.Lock()
	defer st.mu.Unlock()
	st.refreshLocked()
	return len(st.state.Devices) > 0
}

// mayHaveDevices is a lock-free hint for hot paths; it lags the file by at
// most one refresh.
func (st *pushStore) mayHaveDevices() bool {
	return st.hasRecords.Load()
}

// mutate reads the file under the cross-process lock, applies change, and
// writes the result back when change reports a modification.
func (st *pushStore) mutate(change func(state *pushStateFile, now time.Time) bool) error {
	st.mu.Lock()
	defer st.mu.Unlock()
	path, err := pushStatePath()
	if err != nil {
		return err
	}
	unlock, err := lockPushState(path)
	if err != nil {
		return err
	}
	defer unlock()
	now := st.now()
	state, err := readPushStateFile(path)
	if err != nil {
		return err
	}
	prunePushState(&state, now)
	if !change(&state, now) {
		st.loaded = true
		st.lastCheck = now
		if info, err := os.Stat(path); err == nil {
			st.modTime = info.ModTime()
			st.size = info.Size()
		}
		st.setStateLocked(state)
		return nil
	}
	state.Version = pushStateSchemaVersion
	if salt, err := decodePushBase64(state.Salt); err != nil || len(salt) != 32 {
		fresh := make([]byte, 32)
		if _, err := rand.Read(fresh); err != nil {
			return err
		}
		state.Salt = base64.RawURLEncoding.EncodeToString(fresh)
	}
	if err := writePushStateFile(path, state); err != nil {
		return err
	}
	info, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("push registrations written but unreadable: %w", err)
	}
	st.loaded = true
	st.lastCheck = now
	st.modTime = info.ModTime()
	st.size = info.Size()
	st.setStateLocked(state)
	return nil
}

func writePushStateFile(path string, state pushStateFile) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, pushStateDirMode); err != nil {
		return err
	}
	_ = os.Chmod(dir, pushStateDirMode)
	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}
	temp, err := os.CreateTemp(dir, ".push-devices-*.json")
	if err != nil {
		return err
	}
	tempPath := temp.Name()
	defer func() { _ = os.Remove(tempPath) }()
	if err := temp.Chmod(pushStateFileMode); err != nil && !errors.Is(err, errors.ErrUnsupported) {
		_ = temp.Close()
		return err
	}
	if _, err := temp.Write(append(data, '\n')); err != nil {
		_ = temp.Close()
		return err
	}
	if err := temp.Sync(); err != nil {
		_ = temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	return os.Rename(tempPath, path)
}
