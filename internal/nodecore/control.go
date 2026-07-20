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
)

type catalogResponse struct {
	OK                bool               `json:"ok"`
	ComputerConnected bool               `json:"computer_connected"`
	Code              string             `json:"code"`
	Apps              []applicationState `json:"apps"`
}

type actionResponse struct {
	OK                bool              `json:"ok"`
	Action            string            `json:"action,omitempty"`
	ComputerConnected bool              `json:"computer_connected"`
	Enabled           bool              `json:"enabled"`
	Running           bool              `json:"running"`
	Code              string            `json:"code"`
	App               *applicationState `json:"app,omitempty"`
	ErrorCode         string            `json:"error_code,omitempty"`
}

type controlErrorResponse struct {
	OK   bool   `json:"ok"`
	Code string `json:"code"`
}

type controlRequest struct {
	Action string `json:"action"`
	ID     string `json:"id,omitempty"`
}

func (node *Node) stateResponse(app AppDefinition, action string) actionResponse {
	state := node.currentApplicationState(app)
	return actionResponse{OK: true, Action: action, ComputerConnected: true, Enabled: state.Enabled, Running: state.Running, Code: state.Code, App: &state}
}

func (node *Node) listApps() catalogResponse {
	value, err := node.loadRegistry()
	if err != nil {
		return catalogResponse{OK: false, ComputerConnected: true, Code: "registry_unavailable", Apps: []applicationState{}}
	}
	apps := make([]applicationState, 0, len(value.Apps))
	for _, app := range value.Apps {
		apps = append(apps, node.currentApplicationState(app))
	}
	return catalogResponse{OK: true, ComputerConnected: true, Code: "ready", Apps: apps}
}

func (node *Node) startApp(id string) actionResponse {
	app, err := node.findApp(id)
	if err != nil {
		return actionResponse{OK: false, Action: "start", ComputerConnected: true, Code: "app_not_found"}
	}
	if err := os.WriteFile(node.enabledPath(id), []byte("enabled\n"), 0o600); err != nil {
		return actionResponse{OK: false, Action: "start", ComputerConnected: true, Code: "state_update_failed"}
	}
	time.Sleep(800 * time.Millisecond)
	return node.stateResponse(app, "start")
}

func (node *Node) stopApp(id string) actionResponse {
	app, err := node.findApp(id)
	if err != nil {
		return actionResponse{OK: false, Action: "stop", ComputerConnected: true, Code: "app_not_found"}
	}
	if err := os.Remove(node.enabledPath(id)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return actionResponse{OK: false, Action: "stop", ComputerConnected: true, Code: "state_update_failed"}
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
	if result.Running {
		result.Code = "stopping"
		result.App.Code = "stopping"
	}
	if stopErr != nil {
		result.OK = false
		result.ErrorCode = "stop_command_failed"
	}
	return result
}

func (node *Node) statusApp(id string) actionResponse {
	app, err := node.findApp(id)
	if err != nil {
		return actionResponse{OK: false, Action: "status", ComputerConnected: true, Code: "app_not_found"}
	}
	return node.stateResponse(app, "status")
}

func (node *Node) localControlHandler(writer http.ResponseWriter, request *http.Request) {
	token, err := os.ReadFile(node.controlTokenFile)
	expected := "Bearer " + strings.TrimSpace(string(token))
	if err != nil || !validToken.MatchString(strings.TrimSpace(string(token))) || subtle.ConstantTimeCompare([]byte(request.Header.Get("Authorization")), []byte(expected)) != 1 {
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
		if validID.MatchString(input.ID) {
			result = node.statusApp(input.ID)
		}
	case "start":
		if validID.MatchString(input.ID) {
			result = node.startApp(input.ID)
		}
	case "stop":
		if validID.MatchString(input.ID) {
			result = node.stopApp(input.ID)
		}
	}
	writer.Header().Set("Content-Type", "application/json; charset=utf-8")
	writer.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(writer).Encode(result)
}
