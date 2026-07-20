//go:build darwin

package main

import (
	"context"
	"errors"
	"flag"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/hxaxd/remote-everything/internal/nodecore"
)

type macPlatform struct{}

type macProcess struct {
	command *exec.Cmd
	done    chan struct{}
	started time.Time
}

func (macPlatform) PrepareLifetime() (func(), error) { return func() {}, nil }

func (macPlatform) RunCommand(ctx context.Context, name string, arguments ...string) error {
	command := exec.CommandContext(ctx, name, arguments...)
	command.Stdin = nil
	command.Stdout = io.Discard
	command.Stderr = io.Discard
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := command.Start(); err != nil {
		return err
	}
	err := command.Wait()
	_ = syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
	return err
}

func (macPlatform) Launch(app nodecore.AppDefinition, output io.Writer) (nodecore.ManagedProcess, error) {
	executable, err := os.Executable()
	if err != nil {
		return nil, err
	}
	arguments := []string{"guard", "--parent", strconv.Itoa(os.Getpid())}
	if app.WorkDir != "" {
		arguments = append(arguments, "--workdir", app.WorkDir)
	}
	arguments = append(arguments, "--", app.Command)
	arguments = append(arguments, app.Arguments...)
	command := exec.Command(executable, arguments...)
	command.Stdin = nil
	command.Stdout = output
	command.Stderr = output
	command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := command.Start(); err != nil {
		return nil, err
	}
	process := &macProcess{command: command, done: make(chan struct{}), started: time.Now()}
	go func() {
		_ = command.Wait()
		_ = syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
		close(process.done)
	}()
	return process, nil
}

func (process *macProcess) Done() <-chan struct{} { return process.done }
func (process *macProcess) Started() time.Time    { return process.started }
func (process *macProcess) PID() int              { return process.command.Process.Pid }
func (process *macProcess) Terminate() {
	_ = syscall.Kill(-process.command.Process.Pid, syscall.SIGTERM)
}

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
	if flags.Parse(parts[:separator]) != nil || flags.NArg() != 0 || *parent <= 1 || os.Getppid() != *parent {
		return errors.New("invalid guard parent")
	}
	command := exec.Command(parts[separator+1], parts[separator+2:]...)
	command.Dir = *workdir
	command.Stdin = nil
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	if err := command.Start(); err != nil {
		return err
	}
	terminate := func() { _ = syscall.Kill(-os.Getpid(), syscall.SIGKILL) }
	defer terminate()
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

func main() {
	if len(os.Args) > 1 && os.Args[1] == "guard" {
		if err := runGuard(os.Args[2:]); err != nil {
			_, _ = io.WriteString(os.Stderr, err.Error()+"\n")
			os.Exit(1)
		}
		return
	}
	os.Exit(nodecore.Run(os.Args[1:], macPlatform{}, os.Stdout, os.Stderr))
}
