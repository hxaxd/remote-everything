package nodecore

import (
	"context"
	"io"
	"time"
)

type ManagedProcess interface {
	Done() <-chan struct{}
	Started() time.Time
	PID() int
	Terminate()
}

type Platform interface {
	PrepareLifetime() (func(), error)
	RunCommand(context.Context, string, ...string) error
	Launch(AppDefinition, io.Writer) (ManagedProcess, error)
}
