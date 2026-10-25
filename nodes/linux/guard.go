//go:build linux

package main

import (
	"errors"
	"flag"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"syscall"
	"time"
)

// runGuard owns one application's process group independently of the node.
// The application and its descendants inherit this group, so losing the node
// or the application's direct process ends every process left in the group.
func runGuard(parts []string) error {
	separator := -1
	for index, part := range parts {
		if part == "--" {
			separator = index
			break
		}
	}
	if separator < 0 || separator == len(parts)-1 {
		return errors.New("invalid guard arguments")
	}
	flags := flag.NewFlagSet("guard", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	parent := flags.Int("parent", 0, "")
	workdir := flags.String("workdir", "", "")
	if flags.Parse(parts[:separator]) != nil || flags.NArg() != 0 || *parent <= 1 || os.Getppid() != *parent || syscall.Getpgrp() != os.Getpid() {
		return errors.New("invalid guard parent or process group")
	}
	command := exec.Command(parts[separator+1], parts[separator+2:]...)
	command.Dir = *workdir
	command.Stdin = nil
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	if err := command.Start(); err != nil {
		return err
	}
	defer func() { _ = syscall.Kill(-os.Getpid(), syscall.SIGKILL) }()
	done := make(chan error, 1)
	go func() { done <- command.Wait() }()
	stopping := make(chan os.Signal, 1)
	signal.Notify(stopping, syscall.SIGTERM, syscall.SIGINT)
	defer signal.Stop(stopping)
	ticker := time.NewTicker(200 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case err := <-done:
			return err
		case <-stopping:
			return nil
		case <-ticker.C:
			if os.Getppid() != *parent {
				return errors.New("guard parent exited")
			}
		}
	}
}
