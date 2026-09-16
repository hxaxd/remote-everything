package nodecore

import (
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/hxaxd/remote-everything/internal/nodeadapter"
)

const (
	stableRunPeriod = 30 * time.Second
	baseBackoff     = 2 * time.Second
	maxBackoff      = 5 * time.Minute
)

func backoff(failures int) time.Duration {
	delay := baseBackoff
	for attempt := 1; attempt < failures; attempt++ {
		delay *= 2
		if delay >= maxBackoff {
			return maxBackoff
		}
	}
	return delay
}

// appProcess tracks a running app's process, its log file and adapter.
type appProcess struct {
	proc     ManagedProcess
	logPath  string
	logStart int64 // log length when this run started
	started  bool  // whether OnStart has been called
}

// startupOutputLimit bounds how much startup output an onStart hook may read.
const startupOutputLimit = 64 * 1024

// readStartupOutput returns what one run of an app wrote to its log file, which
// is where the launched process sends stdout and stderr.
//
// The log file is handed to the OS layer as a real *os.File on purpose: giving
// exec a wrapped writer makes it fall back to an os.Pipe whose copier holds Wait
// back until every descendant holding the write end exits, and the platform's
// process-group teardown runs only after Wait returns. A wrapped writer left a
// detached descendant alive for good on Linux.
//
// The log is appended to across restarts, so only the slice from the offset this
// run started at is returned; otherwise a hook would read the previous run's
// output, which for a per-launch credential is worse than reading nothing.
func readStartupOutput(path string, offset int64) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	if _, err := file.Seek(offset, io.SeekStart); err != nil {
		return nil, err
	}
	return io.ReadAll(io.LimitReader(file, startupOutputLimit))
}

func (node *Node) launch(app AppDefinition) (*appProcess, error) {
	logPath := filepath.Join(node.logsRoot, app.ID+".log")
	logFile, err := node.openLogFile(logPath)
	if err != nil {
		return nil, err
	}
	var logStart int64
	if info, statErr := logFile.Stat(); statErr == nil {
		logStart = info.Size()
	}
	process, err := node.platform.Launch(app, logFile)
	if err != nil {
		_ = logFile.Close()
		return nil, err
	}
	node.log("app %s launched pid=%d", app.ID, process.PID())
	// Create adapter if the app has one
	adapter := nodeadapter.New(app.Adapter, node.log)
	node.adaptersMu.Lock()
	node.adapters[app.ID] = adapter
	node.adaptersMu.Unlock()
	go func() {
		<-process.Done()
		_ = logFile.Close()
	}()
	return &appProcess{proc: process, logPath: logPath, logStart: logStart}, nil
}

// appPort returns the app's loopback port for adapter onStart hooks; 0 when the
// probe address does not carry a usable port.
func (node *Node) appPort(app AppDefinition) int {
	_, portStr, err := net.SplitHostPort(probeAddress(app))
	if err != nil {
		return 0
	}
	port, _ := strconv.Atoi(portStr)
	return port
}

func (node *Node) supervise() {
	processes := map[string]*appProcess{}
	failures := map[string]int{}
	retryAfter := map[string]time.Time{}
	for {
		value, err := node.loadRegistry()
		if err == nil {
			known := map[string]bool{}
			for _, app := range value.Apps {
				known[app.ID] = true
				entry := processes[app.ID]
				managed := entry
				if managed != nil {
					select {
					case <-managed.proc.Done():
						delete(processes, app.ID)
						node.adaptersMu.Lock()
						delete(node.adapters, app.ID)
						node.adaptersMu.Unlock()
						if time.Since(managed.proc.Started()) < stableRunPeriod {
							failures[app.ID]++
							delay := backoff(failures[app.ID])
							retryAfter[app.ID] = time.Now().Add(delay)
							node.log("app %s exited early; retry in %s", app.ID, delay)
						} else {
							failures[app.ID] = 0
							delete(retryAfter, app.ID)
						}
						managed = nil
					default:
					}
				}
				// Detect adapter source change: terminate so it restarts with new adapter
				if managed != nil {
					node.adaptersMu.RLock()
					adapter := node.adapters[app.ID]
					node.adaptersMu.RUnlock()
					if adapter != nil && adapter.Source() != app.Adapter {
						node.log("app %s adapter changed; restarting", app.ID)
						adapter.OnStop(app.ID)
						managed.proc.Terminate()
						delete(processes, app.ID)
						node.adaptersMu.Lock()
						delete(node.adapters, app.ID)
						node.adaptersMu.Unlock()
						managed = nil
					}
				}
				if !node.isEnabled(app.ID) {
					if managed != nil {
						node.adaptersMu.RLock()
						adapter := node.adapters[app.ID]
						node.adaptersMu.RUnlock()
						if adapter != nil {
							adapter.OnStop(app.ID)
						}
						managed.proc.Terminate()
						delete(processes, app.ID)
						node.adaptersMu.Lock()
						delete(node.adapters, app.ID)
						node.adaptersMu.Unlock()
					}
					continue
				}
				if !probeOpen(probeAddress(app)) && managed == nil && time.Now().After(retryAfter[app.ID]) {
					entry, startErr := node.launch(app)
					if startErr == nil {
						processes[app.ID] = entry
					} else {
						failures[app.ID]++
						delay := backoff(failures[app.ID])
						retryAfter[app.ID] = time.Now().Add(delay)
						node.log("app %s launch failed; retry in %s: %v", app.ID, delay, startErr)
					}
				}
				// Call OnStart when port first opens
				if managed != nil && !managed.started && probeOpen(probeAddress(app)) {
					managed.started = true
					node.adaptersMu.RLock()
					adapter := node.adapters[app.ID]
					node.adaptersMu.RUnlock()
					if adapter != nil {
						stdout, readErr := readStartupOutput(managed.logPath, managed.logStart)
						if readErr != nil {
							node.log("app %s startup output unavailable: %v", app.ID, readErr)
						}
						adapter.OnStart(stdout, node.appPort(app), app.ID)
					}
				}
			}
			for id, entry := range processes {
				if !known[id] {
					node.adaptersMu.RLock()
					adapter := node.adapters[id]
					node.adaptersMu.RUnlock()
					if adapter != nil {
						adapter.OnStop(id)
					}
					entry.proc.Terminate()
					delete(processes, id)
					node.adaptersMu.Lock()
					delete(node.adapters, id)
					node.adaptersMu.Unlock()
				}
			}
		}
		time.Sleep(2 * time.Second)
	}
}
