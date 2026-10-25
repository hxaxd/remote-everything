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
	// RunCommand waits for the helper and reaps its descendants on success,
	// failure or context cancellation before returning.
	RunCommand(context.Context, string, ...string) error
	Launch(AppDefinition, io.Writer) (ManagedProcess, error)
}
