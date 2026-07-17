//go:build windows

package main

import "os"

func platformEUID() int {
	return -1
}

func platformChownUser(path, name string) error {
	return nil
}

// Windows cannot rename over an existing file; tests run there only.
func replaceFile(temporary, target string) error {
	if err := os.Rename(temporary, target); err != nil {
		if removeErr := os.Remove(target); removeErr != nil {
			return err
		}
		return os.Rename(temporary, target)
	}
	return nil
}
