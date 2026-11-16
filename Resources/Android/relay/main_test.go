package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func writeConfig(t *testing.T, path string, cfg bridgeConfig) {
	t.Helper()
	data, err := json.Marshal(cfg)
	if err != nil {
		t.Fatal(err)
	}
	temp := path + ".next"
	if err := os.WriteFile(temp, data, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(temp, path); err != nil {
		t.Fatal(err)
	}
}

func fixture(t *testing.T) (string, bridgeConfig) {
	t.Helper()
	// Keep Unix socket paths short on macOS.
	dir, err := os.MkdirTemp("/tmp", "okadb-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	cfg := bridgeConfig{Socket: filepath.Join(dir, "host.sock"), Token: "test-token", ListenSocket: filepath.Join(dir, "client.sock")}
	path := filepath.Join(dir, "bridge.json")
	writeConfig(t, path, cfg)
	return path, cfg
}

func upstream(t *testing.T, path, token string) func() {
	t.Helper()
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				conn.SetDeadline(time.Now().Add(5 * time.Second))
				reader := bufio.NewReader(conn)
				line, err := reader.ReadString('\n')
				if err != nil || line != token+"\n" {
					return
				}
				req, err := readFrame(reader)
				if err != nil {
					return
				}
				conn.Write([]byte("OKAY"))
				switch string(req) {
				case "host:version":
					writeFrame(conn, []byte("0029"))
				case "host:devices-l":
					writeFrame(conn, []byte("test-device device\n"))
				case "test:delayed-response":
					time.Sleep(100 * time.Millisecond)
					writeFrame(conn, []byte(strings.Repeat("a", 65535)))
				}
			}()
		}
	}()
	return func() { listener.Close() }
}

func TestRelayProtocolAndConfigRotation(t *testing.T) {
	path, cfg := fixture(t)
	stopHost := upstream(t, cfg.Socket, cfg.Token)
	listener, _, err := startRelay(path)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	if err := checkRelay(path); err != nil {
		t.Fatal(err)
	}
	body, err := query(cfg.ListenSocket, "host:devices-l")
	if err != nil || string(body) != "test-device device\n" {
		t.Fatalf("devices: %q %v", body, err)
	}
	stopHost()
	cfg.Token = "replacement-token"
	stopHost = upstream(t, cfg.Socket, cfg.Token)
	defer stopHost()
	writeConfig(t, path, cfg)
	if err := checkRelay(path); err != nil {
		t.Fatalf("token not reloaded: %v", err)
	}
}

func TestHealthRejectsOrdinaryEmptyADBServer(t *testing.T) {
	path, cfg := fixture(t)
	// An ordinary ADB server can return OKAY + an empty devices list. It must
	// not be mistaken for OkDocker merely because its Unix socket accepts.
	listener, err := net.Listen("unix", cfg.ListenSocket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			func() {
				defer conn.Close()
				request, err := readFrame(conn)
				if err != nil {
					return
				}
				switch string(request) {
				case "host:version":
					conn.Write([]byte("OKAY00040029"))
				case "host:devices-l":
					conn.Write([]byte("OKAY0000"))
				default:
					conn.Write([]byte("FAIL000bunsupported"))
				}
			}()
		}
	}()
	if body, err := query(cfg.ListenSocket, "host:version"); err != nil || string(body) != "0029" {
		t.Fatalf("fake ADB server is not serving: %q %v", body, err)
	}
	if err := checkRelay(path); err == nil {
		t.Fatal("accepted an ordinary ADB server instead of the relay")
	}
}

func TestRelayDrainsResponseAfterClientHalfClose(t *testing.T) {
	path, cfg := fixture(t)
	stop := upstream(t, cfg.Socket, cfg.Token)
	defer stop()
	listener, _, err := startRelay(path)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	conn, err := net.DialUnix("unix", nil, &net.UnixAddr{Name: cfg.ListenSocket, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(3 * time.Second))
	writeFrame(conn, []byte("test:delayed-response"))
	conn.CloseWrite()
	var status [4]byte
	if _, err = io.ReadFull(conn, status[:]); err != nil || string(status[:]) != "OKAY" {
		t.Fatalf("status: %s %v", status, err)
	}
	body, err := readFrame(conn)
	if err != nil || len(body) != 65535 {
		t.Fatalf("response truncated: %d %v", len(body), err)
	}
}

func TestRelayOwnsStaleSocketBeforeWorkloadStarts(t *testing.T) {
	path, cfg := fixture(t)
	stop := upstream(t, cfg.Socket, cfg.Token)
	defer stop()
	stale, err := net.ListenUnix("unix", &net.UnixAddr{Name: cfg.ListenSocket, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	stale.SetUnlinkOnClose(false)
	stale.Close()
	listener, _, err := startRelay(path)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	if err := checkRelay(path); err != nil {
		t.Fatal(err)
	}
}

func TestSupervisorRepeatedStartImmediateADBAndTERM(t *testing.T) {
	path, cfg := fixture(t)
	stop := upstream(t, cfg.Socket, cfg.Token)
	defer stop()
	for attempt := 0; attempt < 5; attempt++ {
		t.Run(strconv.Itoa(attempt), func(t *testing.T) {
			marker := filepath.Join(filepath.Dir(path), fmt.Sprintf("ready-%d", attempt))
			cmd := exec.Command(os.Args[0], "-test.run=TestRelayHelperProcess", "--", "supervisor", path, marker)
			var output bytes.Buffer
			cmd.Stdout, cmd.Stderr = &output, &output
			if err := cmd.Start(); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = cmd.Process.Kill() })
			deadline := time.Now().Add(5 * time.Second)
			for {
				if _, err := os.Stat(marker); err == nil {
					break
				}
				if time.Now().After(deadline) {
					t.Fatal("workload did not start with ADB ready")
				}
				time.Sleep(20 * time.Millisecond)
			}
			if err := checkRelay(path); err != nil {
				t.Fatal(err)
			}
			cmd.Process.Signal(syscall.SIGTERM)
			done := make(chan error, 1)
			go func() { done <- cmd.Wait() }()
			select {
			case err := <-done:
				if err != nil {
					t.Fatalf("supervisor exit: %v: %s", err, &output)
				}
			case <-time.After(3 * time.Second):
				t.Fatal("supervisor did not forward TERM")
			}
			if _, err := os.Stat(marker + ".terminated"); err != nil {
				t.Fatal("application did not receive TERM")
			}
			if err := checkRelay(path); err == nil {
				t.Fatal("relay outlived application exit")
			}
		})
	}
}

func TestRelayHelperProcess(t *testing.T) {
	args := os.Args
	for len(args) > 0 && args[0] != "--" {
		args = args[1:]
	}
	if len(args) != 4 {
		return
	}
	mode, path, marker := args[1], args[2], args[3]
	if mode == "supervisor" {
		os.Exit(supervise(path, []string{os.Args[0], "-test.run=TestRelayHelperProcess", "--", "workload", path, marker}))
	}
	if mode == "workload" {
		signals := make(chan os.Signal, 1)
		signal.Notify(signals, syscall.SIGTERM)
		if err := checkRelay(path); err != nil {
			os.Exit(3)
		}
		os.WriteFile(marker, []byte("ready"), 0o600)
		<-signals
		os.WriteFile(marker+".terminated", []byte("TERM"), 0o600)
		os.Exit(0)
	}
}
