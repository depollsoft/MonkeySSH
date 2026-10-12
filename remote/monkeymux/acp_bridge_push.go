package main

import (
	"bufio"
	"encoding/json"
	"net"
	"time"
)

// ACP methods that mean the agent is blocked on the user. Both are part of the
// ACP specification, so these signals are generic across agents.
const (
	acpPermissionRequestMethod = "session/request_permission"
	acpElicitationMethod       = "elicitation/create"
	acpPromptMethod            = "session/prompt"
	acpPushKindPermission      = "permission"
	acpPushKindInput           = "input"
)

// acpBridgePushSignals counts the bridge events push notifications care about.
// The counters only grow, so a poller that remembers the last values sees
// every event between two polls even when it misses the moment itself. All
// methods require the bridge mutex.
type acpBridgePushSignals struct {
	permissionRequests uint64
	inputRequests      uint64
	completedTurns     uint64
	// attention maps pending provider requests that wait on the user to their
	// kind. Entries whose request is no longer pending are pruned when counted.
	attention map[string]string
	// prompts holds in-flight client session/prompt request ids.
	prompts map[string]struct{}
	// delivered is the server-reported push delivery record; see
	// acpPushDeliveredCommand.
	delivered map[string]uint64
}

func (p *acpBridgePushSignals) trackClientRequestLocked(method string, id string) {
	if method != acpPromptMethod || id == "" {
		return
	}
	if p.prompts == nil {
		p.prompts = map[string]struct{}{}
	}
	p.prompts[id] = struct{}{}
}

func (p *acpBridgePushSignals) forgetClientRequestLocked(id string) {
	delete(p.prompts, id)
}

func (p *acpBridgePushSignals) observeProviderRequestLocked(method string, id string) {
	switch method {
	case acpPermissionRequestMethod:
		p.permissionRequests++
	case acpElicitationMethod:
		p.inputRequests++
	default:
		return
	}
	if p.attention == nil {
		p.attention = map[string]string{}
	}
	p.attention[id] = method
}

func (p *acpBridgePushSignals) observeProviderResponseLocked(id string) {
	if _, ok := p.prompts[id]; !ok {
		return
	}
	delete(p.prompts, id)
	p.completedTurns++
}

// pendingAttentionLocked counts permission and input requests that are still
// pending and forgets the ones that were answered or cancelled.
func (p *acpBridgePushSignals) pendingAttentionLocked(pending map[string]struct{}) (permission int, input int) {
	for id, method := range p.attention {
		if _, ok := pending[id]; !ok {
			delete(p.attention, id)
			continue
		}
		if method == acpPermissionRequestMethod {
			permission++
		} else {
			input++
		}
	}
	return permission, input
}

// acpPushDeliveredCommand records which pending request a server pushed to a
// device, so its successor does not push it again.
const acpPushDeliveredCommand = "push_delivered"

// acpPushDeliveredLimit bounds the per-bridge delivered map.
const acpPushDeliveredLimit = 128

type acpPushDeliveredRecord struct {
	DeviceID   string `json:"deviceId"`
	Kind       string `json:"kind"`
	Generation uint64 `json:"generation"`
}

func acpPushDeliveredKey(deviceID string, kind string) string {
	return deviceID + ":" + kind
}

func (p *acpBridgePushSignals) recordDeliveredLocked(record acpPushDeliveredRecord) {
	if p.delivered == nil {
		p.delivered = map[string]uint64{}
	}
	key := acpPushDeliveredKey(record.DeviceID, record.Kind)
	if _, known := p.delivered[key]; !known && len(p.delivered) >= acpPushDeliveredLimit {
		return
	}
	p.delivered[key] = record.Generation
}

func (p *acpBridgePushSignals) deliveredSnapshotLocked() map[string]uint64 {
	if len(p.delivered) == 0 {
		return nil
	}
	snapshot := make(map[string]uint64, len(p.delivered))
	for key, generation := range p.delivered {
		snapshot[key] = generation
	}
	return snapshot
}

func (b *acpBridge) handlePushDeliveredCommand(conn net.Conn, message acpWireMessage) {
	var record acpPushDeliveredRecord
	if json.Unmarshal(message.Data, &record) != nil ||
		!pushDeviceIDPattern.MatchString(record.DeviceID) ||
		(record.Kind != acpPushKindPermission && record.Kind != acpPushKindInput) {
		_ = writeAcpWireFrame(conn, acpWireMessage{
			Version: acpBridgeProtocolVersion,
			Type:    "error",
			Error:   "invalid push delivery record",
		})
		return
	}
	b.mu.Lock()
	b.push.recordDeliveredLocked(record)
	b.mu.Unlock()
	_ = writeAcpWireFrame(conn, acpWireMessage{
		Version: acpBridgeProtocolVersion,
		Type:    acpPushDeliveredCommand,
	})
}

// recordAcpBridgePushDelivered tells a bridge which generation of a pending
// request was pushed to a device.
func recordAcpBridgePushDelivered(bridgeID string, deviceID string, kind string, generation uint64) error {
	conn, err := dialAcpBridge(bridgeID)
	if err != nil {
		return err
	}
	defer conn.Close()
	if err := conn.SetDeadline(time.Now().Add(acpRequestTimeout)); err != nil {
		return err
	}
	data, err := json.Marshal(acpPushDeliveredRecord{DeviceID: deviceID, Kind: kind, Generation: generation})
	if err != nil {
		return err
	}
	if err := writeAcpWireFrame(conn, acpWireMessage{
		Version: acpBridgeProtocolVersion,
		Type:    "command",
		Command: acpPushDeliveredCommand,
		Data:    data,
	}); err != nil {
		return err
	}
	_, err = readAcpWireFrame(bufio.NewReader(conn))
	return err
}
