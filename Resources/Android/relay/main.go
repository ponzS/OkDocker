// ADB transport and application supervisor. Both live in the same container.
// Bind and verify the relay BEFORE starting the workload; never exec away from
// a Go process with a PR_SET_PDEATHSIG child (exec can kill that child's parent
// thread). There is no separate relay child, TCP listener, or workload restart.
package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const relayVersion = "2"
const probePrefix = "host:okdocker-relay:"

type bridgeConfig struct {
	Socket       string `json:"socket"`
	Token        string `json:"token"`
	ListenSocket string `json:"listenSocket"`
}

func main() {
	if len(os.Args) == 3 && os.Args[1] == "--check" {
		if err := checkRelay(os.Args[2]); err != nil {
			fmt.Fprintln(os.Stderr, "OkDocker ADB transport is not ready:", err)
			os.Exit(1)
		}
		return
	}
	if len(os.Args) < 5 || os.Args[1] != "--config" || os.Args[3] != "--" {
		fmt.Fprintln(os.Stderr, "Usage: adb-relay --config FILE -- COMMAND [ARG...] | --check FILE")
		os.Exit(2)
	}
	os.Exit(supervise(os.Args[2], os.Args[4:]))
}

func loadConfig(path string) (bridgeConfig, error) {
	var cfg bridgeConfig
	data, err := os.ReadFile(path)
	if err == nil {
		err = json.Unmarshal(data, &cfg)
	}
	if err != nil || cfg.Socket == "" || cfg.Token == "" || cfg.ListenSocket == "" || strings.ContainsAny(cfg.Token, "\r\n") {
		return cfg, errors.New("invalid bridge configuration") // never log tokens
	}
	return cfg, nil
}

// Accept the ready listener before starting the workload. A persisted dead
// socket (or a local adb fallback from the broken release) is unlinked here.
// Once started, this process owns it until the application exits.
func startRelay(path string) (net.Listener, <-chan error, error) {
	cfg, err := loadConfig(path)
	if err != nil {
		return nil, nil, err
	}
	if err = os.Remove(cfg.ListenSocket); err != nil && !os.IsNotExist(err) {
		return nil, nil, errors.New("cannot remove stale relay socket")
	}
	listener, err := net.Listen("unix", cfg.ListenSocket)
	if err != nil {
		return nil, nil, errors.New("cannot bind relay socket")
	}
	if err := os.Chmod(cfg.ListenSocket, 0o600); err != nil {
		listener.Close()
		return nil, nil, err
	}
	failed := make(chan error, 1)
	go func() {
		for {
			client, err := listener.Accept()
			if err != nil {
				failed <- err
				return
			}
			go relay(client, path)
		}
	}()
	return listener, failed, nil
}

func supervise(path string, command []string) int {
	listener, failed, err := startRelay(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, "OkDocker ADB relay startup failed:", err)
		return 1
	}
	defer listener.Close()
	deadline := time.Now().Add(8 * time.Second)
	for {
		if err = checkRelay(path); err == nil {
			break
		}
		if time.Now().After(deadline) {
			fmt.Fprintln(os.Stderr, "OkDocker ADB relay could not reach the host bridge; application not started")
			return 1
		}
		time.Sleep(100 * time.Millisecond)
	}

	// Subscribe before Start, so a concurrent TERM cannot leave an orphan app.
	signals := make(chan os.Signal, 8)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP, syscall.SIGQUIT)
	defer signal.Stop(signals)
	child := exec.Command(command[0], command[1:]...)
	child.Stdin, child.Stdout, child.Stderr = os.Stdin, os.Stdout, os.Stderr
	child.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := child.Start(); err != nil {
		fmt.Fprintln(os.Stderr, "OkDocker application start failed:", err)
		return 1
	}
	done := make(chan error, 1)
	go func() { done <- child.Wait() }()
	for {
		select {
		case sig := <-signals:
			if value, ok := sig.(syscall.Signal); ok {
				_ = syscall.Kill(-child.Process.Pid, value)
			}
		case <-failed:
			// A dead transport must not be reported as a healthy app with zero
			// phones. Stop this workload, not the shared Mac ADB server.
			_ = syscall.Kill(-child.Process.Pid, syscall.SIGKILL)
			<-done
			fmt.Fprintln(os.Stderr, "OkDocker ADB listener stopped; application stopped")
			return 1
		case err := <-done:
			_ = syscall.Kill(-child.Process.Pid, syscall.SIGKILL)
			if err == nil {
				return 0
			}
			var exit *exec.ExitError
			if errors.As(err, &exit) {
				if status, ok := exit.Sys().(syscall.WaitStatus); ok && status.Signaled() {
					return 128 + int(status.Signal())
				}
				return exit.ExitCode()
			}
			return 1
		}
	}
}

func readFrame(reader io.Reader) ([]byte, error) {
	header := make([]byte, 4)
	if _, err := io.ReadFull(reader, header); err != nil {
		return nil, err
	}
	n, err := strconv.ParseUint(string(header), 16, 16)
	if err != nil || n == 0 {
		return nil, errors.New("invalid ADB frame")
	}
	body := make([]byte, int(n))
	_, err = io.ReadFull(reader, body)
	return body, err
}

func writeFrame(writer io.Writer, body []byte) error {
	_, err := fmt.Fprintf(writer, "%04x%s", len(body), body)
	return err
}

func relay(client net.Conn, path string) {
	defer client.Close()
	_ = client.SetDeadline(time.Now().Add(5 * time.Second))
	request, err := readFrame(client)
	if err != nil {
		return
	}
	if strings.HasPrefix(string(request), probePrefix) {
		_, _ = client.Write([]byte("OKAY"))
		_ = writeFrame(client, []byte(relayVersion+":"+strings.TrimPrefix(string(request), probePrefix)))
		return
	}
	// Atomic config replacement by the Mac is picked up for each new client.
	// Do not cache a token across a host bridge restart.
	cfg, err := loadConfig(path)
	if err != nil {
		return
	}
	upstream, err := net.DialTimeout("unix", cfg.Socket, 3*time.Second)
	if err != nil {
		return
	}
	defer upstream.Close()
	_ = upstream.SetWriteDeadline(time.Now().Add(3 * time.Second))
	if _, err := upstream.Write([]byte(cfg.Token + "\n")); err != nil {
		return
	}
	if err := writeFrame(upstream, request); err != nil {
		return
	}
	_ = client.SetDeadline(time.Time{})
	_ = upstream.SetDeadline(time.Time{})

	// Preserve a request's half-close until the response has drained. Do not
	// close both directions just because the sender finished sending.
	var copies sync.WaitGroup
	copies.Add(2)
	pump := func(dst, src net.Conn) {
		defer copies.Done()
		_, err := io.Copy(dst, src)
		if unix, ok := dst.(*net.UnixConn); ok {
			_ = unix.CloseWrite()
		}
		if err != nil {
			_ = src.SetDeadline(time.Now())
			_ = dst.SetDeadline(time.Now())
		} else {
			_ = dst.SetReadDeadline(time.Now().Add(3 * time.Second))
		}
	}
	go pump(upstream, client)
	go pump(client, upstream)
	copies.Wait()
}

func query(path, request string) ([]byte, error) {
	conn, err := net.DialTimeout("unix", path, time.Second)
	if err != nil {
		return nil, errors.New("relay socket unavailable")
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
	if err = writeFrame(conn, []byte(request)); err != nil {
		return nil, err
	}
	var status [4]byte
	if _, err = io.ReadFull(conn, status[:]); err != nil || string(status[:]) != "OKAY" {
		return nil, errors.New("bridge did not accept ADB request")
	}
	return readFrame(conn)
}

func checkRelay(path string) error {
	cfg, err := loadConfig(path)
	if err != nil {
		return err
	}
	var bytes [16]byte
	if _, err := rand.Read(bytes[:]); err != nil {
		return err
	}
	nonce := hex.EncodeToString(bytes[:])
	body, err := query(cfg.ListenSocket, probePrefix+nonce)
	if err != nil || string(body) != relayVersion+":"+nonce {
		return errors.New("socket is not a compatible OkDocker relay")
	}
	body, err = query(cfg.ListenSocket, "host:version")
	if err != nil {
		return err
	}
	if _, err := strconv.ParseUint(string(body), 16, 32); err != nil {
		return errors.New("invalid host ADB version response")
	}
	return nil
}
