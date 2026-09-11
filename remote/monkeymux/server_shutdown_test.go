package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"testing"
	"time"
)

func TestSendServerShutdownWaitsForAcknowledgement(t *testing.T) {
	for _, result := range []string{"ok", "rejected", "disconnected", "unexpected"} {
		t.Run(result, func(t *testing.T) {
			client, server := net.Pipe()
			defer client.Close()
			defer server.Close()
			_ = server.SetDeadline(time.Now().Add(5 * time.Second))
			serverDone := make(chan error, 1)
			go func() {
				serverDone <- func() error {
					defer server.Close()
					dec := json.NewDecoder(server)
					enc := json.NewEncoder(server)
					var hello controlMessage
					if err := dec.Decode(&hello); err != nil {
						return err
					}
					if hello.Role != "control" || hello.Session != "upgrade" {
						return fmt.Errorf("unexpected hello: %#v", hello)
					}
					if err := enc.Encode(controlResponse{Type: "hello", Status: "ok"}); err != nil {
						return err
					}
					var request controlMessage
					if err := dec.Decode(&request); err != nil {
						return err
					}
					if request.Type != "shutdown" || request.Session != "upgrade" || request.ID == "" {
						return fmt.Errorf("unexpected request: %#v", request)
					}
					// A Unix socket can buffer the request while handleControl is
					// still preparing its initial window_list. Reading it here gives
					// net.Pipe that ordering without depending on socket buffering or
					// metadata refresh timing. Closing after the write loses shutdown
					// when the server's greeting fails before its request scanner runs.
					for _, response := range []controlResponse{
						{Type: "window_list", Status: "ok", Windows: []windowSnapshot{{ID: "@1"}, {ID: "@2"}, {ID: "@3"}}},
						{Type: "window_updated", Status: "ok"},
						{ID: "another-request", Type: "shutdown", Status: "ok"},
					} {
						if err := enc.Encode(response); err != nil {
							return fmt.Errorf("client closed before shutdown acknowledgement: %w", err)
						}
					}
					response := controlResponse{ID: request.ID, Type: "shutdown", Status: "ok"}
					switch result {
					case "rejected":
						response.Type, response.Status, response.Error = "error", "error", "shutdown refused"
					case "disconnected":
						return nil
					case "unexpected":
						response.Type = "pong"
					}
					return enc.Encode(response)
				}()
			}()

			err := sendServerShutdown(client, "upgrade")
			// requestServerShutdown owns the connection and closes it on return.
			_ = client.Close()
			if serverErr := <-serverDone; serverErr != nil {
				t.Fatal(serverErr)
			}
			switch result {
			case "ok":
				if err != nil {
					t.Fatal(err)
				}
			case "rejected":
				if err == nil || !strings.Contains(err.Error(), "shutdown refused") {
					t.Fatalf("error = %v, want shutdown refusal", err)
				}
			case "disconnected":
				if !errors.Is(err, io.EOF) {
					t.Fatalf("error = %v, want EOF before acknowledgement", err)
				}
			case "unexpected":
				if err == nil {
					t.Fatal("accepted an unrelated response as shutdown acknowledgement")
				}
			}
		})
	}
}
