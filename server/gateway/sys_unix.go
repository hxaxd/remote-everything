//go:build unix

package main

import (
	"os"
	"os/user"
	"strconv"
)

func platformEUID() int {
	return os.Geteuid()
}

func platformChownUser(path, name string) error {
	account, err := user.Lookup(name)
	if err != nil {
		return err
	}
	uid, err := strconv.Atoi(account.Uid)
	if err != nil {
		return err
	}
	gid, err := strconv.Atoi(account.Gid)
	if err != nil {
		return err
	}
	return os.Chown(path, uid, gid)
}

// replaceFile is an atomic os.Rename on unix.
func replaceFile(temporary, target string) error {
	return os.Rename(temporary, target)
}
