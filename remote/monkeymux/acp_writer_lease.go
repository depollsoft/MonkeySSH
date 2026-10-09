package main

import (
	"bufio"
	"net"
	"regexp"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

// acpWriterLeaseCapability is advertised in every bridge hello. A client that
// lists it in its own hello is told who holds the input lease, can ask to take
// it over, and receives a `lease` frame when another client takes it.
const acpWriterLeaseCapability = "writer_lease"

const acpDeviceLabelMaxRunes = 48

// acpWriterStaleAfter bounds how long a writer may stay silent before another
// attach takes its lease without asking. Lease-aware clients send a heartbeat
// well inside it, so only a writer whose connection is gone (a sleeping device,
// a half-open TCP session) goes quiet this long. TCP keepalives on the SSH
// connection can take far longer to notice.
const acpWriterStaleAfter = 90 * time.Second

// acpLeaseLinger is how long the bridge keeps a connection that holds no lease
// open for the client to read its last frame and close it. Closing first could
// make the client see the channel drop before it reads the frame.
const acpLeaseLinger = 10 * time.Second

var acpClientTokenPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{16,128}$`)

// acpWriterInfo describes the client that holds the input lease. Label is the
// short device description that client supplied (for example "iPad"), never a
// hostname or user name. IdleSeconds counts from its last input, measured on
// the bridge so the reader needs no clock agreement with the host.
type acpWriterInfo struct {
	Label       string `json:"label,omitempty"`
	IdleSeconds int64  `json:"idleSeconds"`
}

// acpLeaseRequest is the lease part of an attach hello, already sanitized.
type acpLeaseRequest struct {
	aware    bool
	label    string
	token    string
	takeover bool
}

func acpLeaseRequestFromHello(hello acpWireMessage) acpLeaseRequest {
	request := acpLeaseRequest{label: sanitizeAcpDeviceLabel(hello.DeviceLabel)}
	for _, capability := range hello.Capabilities {
		if capability == acpWriterLeaseCapability {
			request.aware = true
			break
		}
	}
	if acpClientTokenPattern.MatchString(hello.ClientToken) {
		request.token = hello.ClientToken
	}
	// Only a client that can be told it lost the lease may take one over.
	request.takeover = request.aware && hello.Takeover
	return request
}

// sanitizeAcpDeviceLabel keeps a short single-line printable label and drops
// anything else, so a reader never displays arbitrary client data.
func sanitizeAcpDeviceLabel(label string) string {
	if !utf8.ValidString(label) {
		return ""
	}
	label = strings.Join(strings.Fields(label), " ")
	if utf8.RuneCountInString(label) > acpDeviceLabelMaxRunes {
		return ""
	}
	for _, r := range label {
		if !unicode.IsPrint(r) {
			return ""
		}
	}
	return label
}

func (b *acpBridge) clock() time.Time {
	if b.now != nil {
		return b.now()
	}
	return time.Now()
}

func (b *acpBridge) setWriterLocked(clientID string, now time.Time) {
	b.writerClientID = clientID
	b.writerLastInput = now
}

// claimWriterOnAttachLocked decides whether an attaching client takes the
// input lease and returns the writer it displaced, if any. The lease moves
// when it is free, when the client asks to take it over, when the same app
// process reattaches (its old connection may be half-open), or when the
// writer has been silent past acpWriterStaleAfter.
func (b *acpBridge) claimWriterOnAttachLocked(
	client *acpBridgeClient,
	request acpLeaseRequest,
	now time.Time,
) *acpBridgeClient {
	current := b.clients[b.writerClientID]
	switch {
	case current == nil:
	case request.takeover:
	case request.token != "" && request.token == current.token:
	case now.Sub(current.lastSeen) >= acpWriterStaleAfter:
	default:
		return nil
	}
	b.setWriterLocked(client.id, now)
	return current
}

// displaceWriterLocked detaches old, which just lost the lease to writer. It
// stops receiving output at once. A lease-aware client is then told who holds
// the lease; any other client is returned for the caller to disconnect after
// releasing b.mu, so it reattaches and learns the lease is held elsewhere.
// Pending provider requests and in-flight turns are bridge state, not client
// state, so they carry over to the new writer untouched.
func (b *acpBridge) displaceWriterLocked(
	old *acpBridgeClient,
	writer *acpBridgeClient,
) *acpBridgeClient {
	delete(b.clients, old.id)
	if old.leaseAware && tryEnqueueAcpClient(old, acpWireMessage{
		Version:  acpBridgeProtocolVersion,
		Type:     "lease",
		BridgeID: b.id,
		Writer:   &acpWriterInfo{Label: writer.label},
	}) {
		return nil
	}
	return old
}

// writerInfoLocked describes the attached writer, or nil when there is none.
func (b *acpBridge) writerInfoLocked(now time.Time) *acpWriterInfo {
	writer := b.clients[b.writerClientID]
	if writer == nil {
		return nil
	}
	idle := now.Sub(b.writerLastInput)
	if idle < 0 {
		idle = 0
	}
	return &acpWriterInfo{Label: writer.label, IdleSeconds: int64(idle / time.Second)}
}

// touchClient records that clientID is still alive, which keeps its lease
// from going stale.
func (b *acpBridge) touchClient(clientID string) {
	now := b.clock()
	b.mu.Lock()
	defer b.mu.Unlock()
	if client := b.clients[clientID]; client != nil {
		client.lastSeen = now
	}
}

// answerLeaseProbe tells a lease-aware client that cannot write who holds the
// lease, then waits for it to close. It is never registered as a reader: it
// reattaches with takeover to continue, and that attach replays any pending
// provider requests to it.
func answerLeaseProbe(conn net.Conn, reader *bufio.Reader, hello acpWireMessage) {
	_ = conn.SetDeadline(time.Now().Add(acpLeaseLinger))
	if writeAcpWireFrame(conn, hello) != nil {
		return
	}
	for {
		if _, err := readAcpWireFrame(reader); err != nil {
			return
		}
	}
}
