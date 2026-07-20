package nodecore

import (
	"path/filepath"
	"time"
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

func (node *Node) launch(app AppDefinition) (ManagedProcess, error) {
	logFile, err := node.openLogFile(filepath.Join(node.logsRoot, app.ID+".log"))
	if err != nil {
		return nil, err
	}
	process, err := node.platform.Launch(app, logFile)
	if err != nil {
		_ = logFile.Close()
		return nil, err
	}
	node.log("app %s launched pid=%d", app.ID, process.PID())
	go func() {
		<-process.Done()
		_ = logFile.Close()
	}()
	return process, nil
}

func (node *Node) supervise() {
	processes := map[string]ManagedProcess{}
	failures := map[string]int{}
	retryAfter := map[string]time.Time{}
	for {
		value, err := node.loadRegistry()
		if err == nil {
			known := map[string]bool{}
			for _, app := range value.Apps {
				known[app.ID] = true
				managed := processes[app.ID]
				if managed != nil {
					select {
					case <-managed.Done():
						delete(processes, app.ID)
						if time.Since(managed.Started()) < stableRunPeriod {
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
				if !node.isEnabled(app.ID) {
					if managed != nil {
						managed.Terminate()
					}
					continue
				}
				if !probeOpen(probeAddress(app)) && managed == nil && time.Now().After(retryAfter[app.ID]) {
					started, startErr := node.launch(app)
					if startErr == nil {
						processes[app.ID] = started
					} else {
						failures[app.ID]++
						delay := backoff(failures[app.ID])
						retryAfter[app.ID] = time.Now().Add(delay)
						node.log("app %s launch failed; retry in %s: %v", app.ID, delay, startErr)
					}
				}
			}
			for id, managed := range processes {
				if !known[id] {
					managed.Terminate()
					delete(processes, id)
				}
			}
		}
		time.Sleep(2 * time.Second)
	}
}
