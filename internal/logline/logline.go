// Package logline writes what a gateway reports: one JSON object per line, so
// an operator can tail it and a tool can read it.
package logline

import (
	"encoding/json"
	"io"
	"os"
	"sync"
	"time"
)

var (
	mutex    sync.Mutex
	logOut   io.Writer = os.Stdout
	auditOut io.Writer = os.Stderr
)

// Line writes one structured line to a stream. Callers must never pass tokens,
// passwords, private keys or PKCS#12 material as values.
func Line(writer io.Writer, component, level, message string, keyValues ...string) {
	entry := map[string]string{
		"ts":        time.Now().UTC().Format("2006-01-02T15:04:05.000Z"),
		"level":     level,
		"component": component,
		"msg":       message,
	}
	for index := 0; index+1 < len(keyValues); index += 2 {
		entry[keyValues[index]] = keyValues[index+1]
	}
	data, err := json.Marshal(entry)
	if err != nil {
		return
	}
	mutex.Lock()
	defer mutex.Unlock()
	_, _ = writer.Write(append(data, '\n'))
}

// Log writes one operational line where the rest of a command's output goes.
func Log(component, level, message string, keyValues ...string) {
	Line(logOut, component, level, message, keyValues...)
}

// Audit writes one line of the device audit trail beside rather than among a
// command's output, so a JSON document on stdout stays parseable on its own.
func Audit(message string, keyValues ...string) {
	Line(auditOut, "device", "info", message, keyValues...)
}
