//go:build !windows

package atomicfile

import (
	"os"
	"path/filepath"
	"syscall"
)

// MatchDirectoryOwner sets path ownership to match its parent directory.
// Root-run CLI helpers otherwise leave 0600 files the service user cannot read.
func MatchDirectoryOwner(path string) error {
	info, err := os.Stat(filepath.Dir(path))
	if err != nil {
		return err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return nil
	}
	return os.Chown(path, int(stat.Uid), int(stat.Gid))
}
