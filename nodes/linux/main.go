//go:build linux

package main

import (
	"context"
	"io"
	"os"
	"os/exec"
	"syscall"
	"time"

	"github.com/hxaxd/remote-everything/internal/node/nodecore"
)

type linuxPlatform struct{}

type linuxProcess struct {
	command *exec.Cmd
	done    chan struct{}
	started time.Time
}

func (linuxPlatform) PrepareLifetime() (func(), error) { return func() {}, nil }

func (linuxPlatform) RunCommand(ctx context.Context, name string, arguments ...string) error {
	command := exec.CommandContext(ctx, name, arguments...)
	command.Stdin = nil
	command.Stdout = io.Discard
	command.Stderr = io.Discard
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true, Pdeathsig: syscall.SIGKILL}
	if err := command.Start(); err != nil {
		return err
	}
	err := command.Wait()
	_ = syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
	return err
}

func (linuxPlatform) Launch(app nodecore.AppDefinition, output io.Writer) (nodecore.ManagedProcess, error) {
	command := exec.Command(app.Command, app.Arguments...)
	command.Dir = app.WorkDir
	command.Stdin = nil
	command.Stdout = output
	command.Stderr = output
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true, Pdeathsig: syscall.SIGKILL}
	if err := command.Start(); err != nil {
		return nil, err
	}
	process := &linuxProcess{command: command, done: make(chan struct{}), started: time.Now()}
	go func() {
		_ = command.Wait()
		_ = syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
		close(process.done)
	}()
	return process, nil
}

func (process *linuxProcess) Done() <-chan struct{} { return process.done }
func (process *linuxProcess) Started() time.Time    { return process.started }
func (process *linuxProcess) PID() int              { return process.command.Process.Pid }
func (process *linuxProcess) Terminate() {
	_ = syscall.Kill(-process.command.Process.Pid, syscall.SIGKILL)
	_ = process.command.Process.Kill()
}

func main() {
	os.Exit(nodecore.Run(os.Args[1:], linuxPlatform{}, os.Stdout, os.Stderr))
}
