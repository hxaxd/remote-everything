//go:build darwin

package main

import (
	"testing"

	"github.com/hxaxd/remote-everything/internal/node/nodecore/testharness"
)

func TestCommandFixture(t *testing.T) { testharness.CommandFixture(t) }

func TestRunCommandCleansDescendants(t *testing.T) {
	testharness.RunCommandCleanup(t, (macPlatform{}).RunCommand)
}
