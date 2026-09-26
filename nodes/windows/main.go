//go:build windows

package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"github.com/hxaxd/remote-everything/internal/node/nodecore"
)

const (
	createNoWindow               = 0x08000000
	createSuspended              = 0x00000004
	jobObjectExtendedLimitInfo   = 9
	jobObjectLimitKillOnJobClose = 0x00002000
	processSetQuota              = 0x00000100
	processSuspendResume         = 0x00000800
)

var (
	kernel32                 = syscall.NewLazyDLL("kernel32.dll")
	createJobObjectW         = kernel32.NewProc("CreateJobObjectW")
	setInformationJobObject  = kernel32.NewProc("SetInformationJobObject")
	assignProcessToJobObject = kernel32.NewProc("AssignProcessToJobObject")
	ntResumeProcess          = syscall.NewLazyDLL("ntdll.dll").NewProc("NtResumeProcess")
)

type jobObjectBasicLimitInformation struct {
	PerProcessUserTimeLimit int64
	PerJobUserTimeLimit     int64
	LimitFlags              uint32
	MinimumWorkingSetSize   uintptr
	MaximumWorkingSetSize   uintptr
	ActiveProcessLimit      uint32
	Affinity                uintptr
	PriorityClass           uint32
	SchedulingClass         uint32
}

type ioCounters struct {
	ReadOperationCount  uint64
	WriteOperationCount uint64
	OtherOperationCount uint64
	ReadTransferCount   uint64
	WriteTransferCount  uint64
	OtherTransferCount  uint64
}

type jobObjectExtendedLimitInformation struct {
	BasicLimitInformation jobObjectBasicLimitInformation
	IOInfo                ioCounters
	ProcessMemoryLimit    uintptr
	JobMemoryLimit        uintptr
	PeakProcessMemoryUsed uintptr
	PeakJobMemoryUsed     uintptr
}

func createKillOnCloseJob() (syscall.Handle, error) {
	rawJob, _, callError := createJobObjectW.Call(0, 0)
	if rawJob == 0 {
		return 0, fmt.Errorf("create job object: %w", callError)
	}
	job := syscall.Handle(rawJob)
	limits := jobObjectExtendedLimitInformation{}
	limits.BasicLimitInformation.LimitFlags = jobObjectLimitKillOnJobClose
	result, _, callError := setInformationJobObject.Call(rawJob, jobObjectExtendedLimitInfo, uintptr(unsafe.Pointer(&limits)), unsafe.Sizeof(limits))
	if result == 0 {
		_ = syscall.CloseHandle(job)
		return 0, fmt.Errorf("configure job object: %w", callError)
	}
	return job, nil
}

func assignProcessToJob(job syscall.Handle, process syscall.Handle) error {
	result, _, callError := assignProcessToJobObject.Call(uintptr(job), uintptr(process))
	if result == 0 {
		return fmt.Errorf("assign process to job object: %w", callError)
	}
	return nil
}

type windowsPlatform struct{}

type windowsProcess struct {
	command *exec.Cmd
	done    chan struct{}
	started time.Time
	job     syscall.Handle
	close   sync.Once
}

func (windowsPlatform) PrepareLifetime() (func(), error) {
	job, err := createKillOnCloseJob()
	if err != nil {
		return nil, err
	}
	current, err := syscall.GetCurrentProcess()
	if err != nil {
		_ = syscall.CloseHandle(job)
		return nil, err
	}
	if err := assignProcessToJob(job, current); err != nil {
		_ = syscall.CloseHandle(job)
		return nil, err
	}
	return func() { _ = syscall.CloseHandle(job) }, nil
}

func (windowsPlatform) RunCommand(ctx context.Context, name string, arguments ...string) error {
	command := exec.CommandContext(ctx, name, arguments...)
	command.Stdin = nil
	command.Stdout = io.Discard
	command.Stderr = io.Discard
	command.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow}
	return command.Run()
}

func (windowsPlatform) Launch(app nodecore.AppDefinition, output io.Writer) (nodecore.ManagedProcess, error) {
	command := exec.Command(app.Command, app.Arguments...)
	command.Dir = app.WorkDir
	command.Stdin = nil
	command.Stdout = output
	command.Stderr = output
	command.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow | createSuspended}
	if err := command.Start(); err != nil {
		return nil, err
	}
	job, err := createKillOnCloseJob()
	if err != nil {
		_ = command.Process.Kill()
		_ = command.Wait()
		return nil, err
	}
	processHandle, err := syscall.OpenProcess(processSetQuota|processSuspendResume|syscall.PROCESS_TERMINATE, false, uint32(command.Process.Pid))
	if err == nil {
		err = assignProcessToJob(job, processHandle)
	}
	if err == nil {
		status, _, _ := ntResumeProcess.Call(uintptr(processHandle))
		if status != 0 {
			err = fmt.Errorf("resume application process: NTSTATUS 0x%x", status)
		}
	}
	if processHandle != 0 {
		_ = syscall.CloseHandle(processHandle)
	}
	if err != nil {
		_ = syscall.CloseHandle(job)
		_ = command.Process.Kill()
		_ = command.Wait()
		return nil, err
	}
	process := &windowsProcess{command: command, done: make(chan struct{}), started: time.Now(), job: job}
	go func() {
		_ = command.Wait()
		process.closeJob()
		close(process.done)
	}()
	return process, nil
}

func (process *windowsProcess) closeJob() {
	process.close.Do(func() { _ = syscall.CloseHandle(process.job) })
}

func (process *windowsProcess) Done() <-chan struct{} { return process.done }
func (process *windowsProcess) Started() time.Time    { return process.started }
func (process *windowsProcess) PID() int              { return process.command.Process.Pid }
func (process *windowsProcess) Terminate() {
	process.closeJob()
	_ = process.command.Process.Kill()
}

func main() {
	os.Exit(nodecore.Run(os.Args[1:], windowsPlatform{}, os.Stdout, os.Stderr))
}
