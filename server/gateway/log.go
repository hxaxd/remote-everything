package main

import (
	"encoding/json"
	"io"
	"os"
	"sync"
	"time"
)

var (
	logMu    sync.Mutex
	logOut   io.Writer = os.Stdout
	auditOut io.Writer = os.Stderr
)

func writeLogLine(writer io.Writer, component, level, msg string, kv ...string) {
	entry := map[string]string{
		"ts":        time.Now().UTC().Format("2006-01-02T15:04:05.000Z"),
		"level":     level,
		"component": component,
		"msg":       msg,
	}
	for index := 0; index+1 < len(kv); index += 2 {
		entry[kv[index]] = kv[index+1]
	}
	data, err := json.Marshal(entry)
	if err != nil {
		return
	}
	logMu.Lock()
	defer logMu.Unlock()
	_, _ = writer.Write(append(data, '\n'))
}

// auditLine mirrors the enrollment CLI audit trail to stderr so the JSON
// document on stdout stays parseable on its own. Never log secrets here.
func auditLine(msg string, kv ...string) {
	writeLogLine(auditOut, "enroll", "info", msg, kv...)
}

// logLine writes one structured JSON line. Callers must never pass tokens,
// passwords, private keys, or PKCS#12 material as values.
func logLine(component, level, msg string, kv ...string) {
	writeLogLine(logOut, component, level, msg, kv...)
}
