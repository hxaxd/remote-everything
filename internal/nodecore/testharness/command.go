// Package testharness provides native process-lifecycle checks shared by nodes.
package testharness

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"testing"
	"time"
)

type commandChild struct {
	PID     int    `json:"pid"`
	Address string `json:"address"`
}

func readChildren(path string) ([]commandChild, error) {
	var children []commandChild
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	err = json.Unmarshal(data, &children)
	return children, err
}

func waitChildren(path string) ([]commandChild, error) {
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if children, err := readChildren(path); err == nil && len(children) > 0 {
			return children, nil
		}
		time.Sleep(10 * time.Millisecond)
	}
	return nil, fmt.Errorf("command descendants did not report readiness: %s", path)
}

func fixtureArguments(mode, ready string, depth int) []string {
	return []string{"-test.run=^TestCommandFixture$", "--", "--command-fixture", mode, ready, strconv.Itoa(depth)}
}

// CommandFixture is called by TestCommandFixture in each native node package.
// It runs only in subprocesses carrying the explicit fixture marker.
func CommandFixture(t *testing.T) {
	t.Helper()
	marker := -1
	for index, argument := range os.Args {
		if argument == "--command-fixture" {
			marker = index
			break
		}
	}
	if marker < 0 {
		return
	}
	if len(os.Args) != marker+4 {
		t.Fatal("invalid command fixture arguments")
	}
	mode, ready := os.Args[marker+1], os.Args[marker+2]
	depth, err := strconv.Atoi(os.Args[marker+3])
	if err != nil || depth < 1 {
		t.Fatal("invalid fixture depth")
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	var listener net.Listener
	children := []commandChild{}
	if mode == "worker" {
		listener, err = net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		defer listener.Close()
		children = append(children, commandChild{PID: os.Getpid(), Address: listener.Addr().String()})
	}
	if mode != "worker" || depth > 1 {
		childReady := ready + ".child"
		child := exec.Command(executable, fixtureArguments("worker", childReady, depth-1)...)
		child.Stdout, child.Stderr = os.Stdout, os.Stderr
		if err := child.Start(); err != nil {
			t.Fatal(err)
		}
		descendants, err := waitChildren(childReady)
		if err != nil {
			_ = child.Process.Kill()
			t.Fatal(err)
		}
		children = append(children, descendants...)
	}
	data, err := json.Marshal(children)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(ready, data, 0o600); err != nil {
		t.Fatal(err)
	}
	switch mode {
	case "success":
		return
	case "failure":
		os.Exit(23)
	case "wait":
		for {
			time.Sleep(time.Hour)
		}
	case "worker":
		for {
			connection, err := listener.Accept()
			if err != nil {
				t.Fatal(err)
			}
			_ = connection.Close()
		}
	default:
		t.Fatal("unknown command fixture mode")
	}
}

func childListening(child commandChild) bool {
	connection, err := net.DialTimeout("tcp", child.Address, 100*time.Millisecond)
	if err == nil {
		_ = connection.Close()
		return true
	}
	return false
}

// RunCommandCleanup checks real child and grandchild listeners for each exit
// path. A helper's exit status must survive cleanup of its process tree.
func RunCommandCleanup(t *testing.T, run func(context.Context, string, ...string) error) {
	t.Helper()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	for _, mode := range []string{"success", "failure", "wait"} {
		t.Run(mode, func(t *testing.T) {
			ready := filepath.Join(t.TempDir(), "ready.json")
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			finished := make(chan error, 1)
			go func() { finished <- run(ctx, executable, fixtureArguments(mode, ready, 3)...) }()
			t.Cleanup(func() {
				cancel()
				// Clean up a regression's test descendants without relying on the
				// platform implementation under test to have killed them.
				children, _ := readChildren(ready)
				for _, child := range children {
					if childListening(child) {
						if process, err := os.FindProcess(child.PID); err == nil {
							_ = process.Kill()
							_, _ = process.Wait()
							_ = process.Release()
						}
					}
				}
			})
			children, err := waitChildren(ready)
			if err != nil {
				t.Fatal(err)
			}
			if len(children) != 2 {
				t.Fatalf("fixture created %d descendants, want child and grandchild", len(children))
			}
			if mode == "wait" {
				for _, child := range children {
					if !childListening(child) {
						t.Fatal("descendant was not alive before cancellation")
					}
				}
				cancel()
			}
			select {
			case err := <-finished:
				var exit *exec.ExitError
				if mode == "success" && err != nil || mode == "failure" && (!errors.As(err, &exit) || exit.ExitCode() != 23) || mode == "wait" && err == nil {
					t.Fatalf("%s command result: %v", mode, err)
				}
			case <-time.After(10 * time.Second):
				t.Fatal("command did not return after exit or cancellation")
			}
			for _, child := range children {
				deadline := time.Now().Add(2 * time.Second)
				for childListening(child) && time.Now().Before(deadline) {
					time.Sleep(10 * time.Millisecond)
				}
				if childListening(child) {
					t.Errorf("command descendant %d still listening at %s", child.PID, child.Address)
				}
			}
		})
	}
}
