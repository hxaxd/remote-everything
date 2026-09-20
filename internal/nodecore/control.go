package nodecore

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/hxaxd/remote-everything/internal/wire"
)

type controlErrorResponse struct {
	OK   bool   `json:"ok"`
	Code string `json:"code"`
}

type controlRequest struct {
	Action string `json:"action"`
	ID     string `json:"id,omitempty"`
}

func (node *Node) stateResponse(app AppDefinition, action string) wire.Action {
	state := node.currentApplicationState(app)
	return wire.Action{OK: true, Action: action, ComputerConnected: true, Enabled: state.Enabled, Running: state.Running, Code: state.Code, App: &state}
}

func (node *Node) listApps() wire.Catalog {
	value, err := node.loadRegistry()
	if err != nil {
		return wire.Catalog{OK: false, ComputerConnected: true, Code: "registry_unavailable", Apps: []wire.ApplicationState{}}
	}
	apps := make([]wire.ApplicationState, 0, len(value.Apps))
	for _, app := range value.Apps {
		apps = append(apps, node.currentApplicationState(app))
	}
	return wire.Catalog{OK: true, ComputerConnected: true, Code: "ready", Apps: apps}
}

func (node *Node) startApp(id string) wire.Action {
	app, err := node.findApp(id)
	if err != nil {
		return wire.Action{OK: false, Action: "start", ComputerConnected: true, Code: "app_not_found"}
	}
	if err := os.WriteFile(node.enabledPath(id), []byte("enabled\n"), 0o600); err != nil {
		return wire.Action{OK: false, Action: "start", ComputerConnected: true, Code: "state_update_failed"}
	}
	// Give the supervisor (2s poll cycle) a window to notice the enabled flag and
	// either relaunch the process or confirm the port is already open, so the
	// response reflects a starting/ready state instead of always stopped.
	time.Sleep(800 * time.Millisecond)
	return node.stateResponse(app, "start")
}

func (node *Node) stopApp(id string) wire.Action {
	app, err := node.findApp(id)
	if err != nil {
		return wire.Action{OK: false, Action: "stop", ComputerConnected: true, Code: "app_not_found"}
	}
	if err := os.Remove(node.enabledPath(id)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return wire.Action{OK: false, Action: "stop", ComputerConnected: true, Code: "state_update_failed"}
	}
	var stopErr error
	if app.StopCommand != "" {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		stopErr = node.platform.RunCommand(ctx, app.StopCommand, app.StopArgs...)
		cancel()
		if stopErr != nil {
			node.log("app %s stop command failed: %v", id, stopErr)
		}
	}
	for attempt := 0; attempt < 20 && probeOpen(probeAddress(app)); attempt++ {
		time.Sleep(200 * time.Millisecond)
	}
	result := node.stateResponse(app, "stop")
	if stopErr != nil {
		result.OK = false
		result.ErrorCode = "stop_command_failed"
	}
	return result
}

func (node *Node) statusApp(id string) wire.Action {
	app, err := node.findApp(id)
	if err != nil {
		return wire.Action{OK: false, Action: "status", ComputerConnected: true, Code: "app_not_found"}
	}
	return node.stateResponse(app, "status")
}

func (node *Node) authorize(request *http.Request) bool {
	auth := request.Header.Get("Authorization")
	state, err := node.currentState()
	if err != nil {
		node.log("control auth state unavailable: %v", err)
		return false
	}
	for _, binding := range state.Bindings {
		contents, err := os.ReadFile(binding.ControlTokenFile)
		if err != nil {
			continue
		}
		expected := strings.TrimSpace(string(contents))
		if validToken.MatchString(expected) && subtle.ConstantTimeCompare([]byte(auth), []byte("Bearer "+expected)) == 1 {
			return true
		}
	}
	return false
}

func (node *Node) localControlHandler(writer http.ResponseWriter, request *http.Request) {
	if !node.authorize(request) {
		node.log("control auth failed remote=%s", request.RemoteAddr)
		writer.WriteHeader(http.StatusUnauthorized)
		return
	}
	if request.Method != http.MethodPost {
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	var input controlRequest
	decoder := json.NewDecoder(io.LimitReader(request.Body, 4096))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&input) != nil || decoder.Decode(&struct{}{}) != io.EOF {
		writer.WriteHeader(http.StatusBadRequest)
		return
	}
	var result any = controlErrorResponse{OK: false, Code: "command_not_allowed"}
	switch input.Action {
	case "list":
		if input.ID == "" {
			result = node.listApps()
		}
	case "status":
		if wire.ValidAppID(input.ID) {
			result = node.statusApp(input.ID)
		}
	case "start":
		if wire.ValidAppID(input.ID) {
			result = node.startApp(input.ID)
		}
	case "stop":
		if wire.ValidAppID(input.ID) {
			result = node.stopApp(input.ID)
		}
	}
	writer.Header().Set("Content-Type", "application/json; charset=utf-8")
	writer.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(writer).Encode(result)
}
