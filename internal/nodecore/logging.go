package nodecore

import (
	"fmt"
	"os"
	"path/filepath"
	"time"
)

const maxLogBytes = 4 << 20

func (node *Node) openLogFile(path string) (*os.File, error) {
	if info, err := os.Stat(path); err == nil && info.Size() > maxLogBytes {
		_ = os.Remove(path + ".old")
		_ = os.Rename(path, path+".old")
	}
	return os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
}

func (node *Node) log(format string, args ...any) {
	node.logMu.Lock()
	defer node.logMu.Unlock()
	file, err := node.openLogFile(filepath.Join(node.logsRoot, "control.log"))
	if err != nil {
		return
	}
	defer file.Close()
	_, _ = fmt.Fprintf(file, "%s %s\n", time.Now().UTC().Format(time.RFC3339), fmt.Sprintf(format, args...))
}
