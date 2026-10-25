//go:build linux

package main

import (
	"testing"

	"github.com/hxaxd/remote-everything/internal/nodecore/testharness"
)

func TestCommandFixture(t *testing.T) { testharness.CommandFixture(t) }

func TestRunCommandCleansDescendants(t *testing.T) {
	testharness.RunCommandCleanup(t, (linuxPlatform{}).RunCommand)
}
