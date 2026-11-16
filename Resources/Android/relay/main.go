// In-guest ADB token injector. It is the container entrypoint only long enough
// to listen, then it replaces itself with the image command. No TCP listener.
package main

import (
	"encoding/json"
	"io"
	"net"
	"os"
	"os/exec"
	"syscall"
	"time"
)

type bridgeConfig struct {
	Socket       string `json:"socket"`
	Token        string `json:"token"`
	ListenSocket string `json:"listenSocket"`
}

func main() {
	if len(os.Args) == 3 && os.Args[1] == "--serve" {
		serve(os.Args[2])
		return
	}
	if len(os.Args) < 5 || os.Args[1] != "--config" || os.Args[3] != "--" {
		os.Exit(2)
	}
	config, command := os.Args[2], os.Args[4:]
	child := exec.Command(os.Args[0], "--serve", config)
	child.Stdout, child.Stderr = os.Stdout, os.Stderr
	if err := child.Start(); err != nil {
		os.Exit(1)
	}
	if err := waitReady(config); err != nil {
		_ = child.Process.Kill()
		os.Exit(1)
	}
	if err := syscall.Exec(command[0], command, os.Environ()); err != nil {
		_ = child.Process.Kill()
		os.Exit(1)
	}
}

func waitReady(path string) error {
	var cfg bridgeConfig
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(data, &cfg); err != nil || cfg.ListenSocket == "" {
		return io.ErrUnexpectedEOF
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("unix", cfg.ListenSocket, 200*time.Millisecond)
		if err == nil {
			conn.Close()
			return nil
		}
		time.Sleep(20 * time.Millisecond)
	}
	return io.ErrUnexpectedEOF
}

func serve(path string) {
	dieWithParent()
	var cfg bridgeConfig
	data, err := os.ReadFile(path)
	if err != nil {
		os.Exit(1)
	}
	if err := json.Unmarshal(data, &cfg); err != nil || cfg.Socket == "" || cfg.Token == "" || cfg.ListenSocket == "" {
		os.Exit(1)
	}
	_ = os.Remove(cfg.ListenSocket)
	listener, err := net.Listen("unix", cfg.ListenSocket)
	if err != nil {
		os.Exit(1)
	}
	defer listener.Close()
	for {
		client, err := listener.Accept()
		if err != nil {
			continue
		}
		go relay(client, cfg)
	}
}

func relay(client net.Conn, cfg bridgeConfig) {
	defer client.Close()
	upstream, err := net.DialTimeout("unix", cfg.Socket, 10*time.Second)
	if err != nil {
		return
	}
	defer upstream.Close()
	if _, err := upstream.Write([]byte(cfg.Token + "\n")); err != nil {
		return
	}
	done := make(chan struct{}, 2)
	go func() { _, _ = io.Copy(upstream, client); done <- struct{}{} }()
	go func() { _, _ = io.Copy(client, upstream); done <- struct{}{} }()
	<-done
}

func dieWithParent() {
	_, _, _ = syscall.RawSyscall(syscall.SYS_PRCTL, 1, uintptr(syscall.SIGTERM), 0)
	if os.Getppid() == 1 {
		os.Exit(0)
	}
}
