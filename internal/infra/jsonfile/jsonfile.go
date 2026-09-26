// Package jsonfile reads and writes a state file that holds exactly one JSON
// document. Reads reject unknown fields and trailing content, so a state file
// cannot quietly grow a field the running code does not understand; writes
// replace the file atomically, so a reader never sees a partial document.
package jsonfile

import (
	"encoding/json"
	"errors"
	"io"
	"os"

	"github.com/hxaxd/remote-everything/internal/infra/atomicfile"
)

func Read(path string, output any) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	decoder := json.NewDecoder(file)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(output); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return errors.New("trailing JSON content")
	}
	return nil
}

func Write(path string, value any, mode os.FileMode) error {
	contents, err := json.Marshal(value)
	if err != nil {
		return err
	}
	return atomicfile.Write(path, append(contents, '\n'), mode)
}
