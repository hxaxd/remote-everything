package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"
)

const createNoWindow = 0x08000000

var (
	stateRoot        = filepath.Join(os.Getenv("LOCALAPPDATA"), "RemoteEverything")
	appsFile         = filepath.Join(stateRoot, "apps.json")
	enabledRoot      = filepath.Join(stateRoot, "enabled")
	logsRoot         = filepath.Join(stateRoot, "logs")
	controlTokenFile = filepath.Join(stateRoot, "control-token")
	validID          = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,63}$`)
)

const (
	maxLogBytes     = 4 << 20
	stableRunPeriod = 30 * time.Second
)

var (
	baseBackoff      = 2 * time.Second
	maxBackoff       = 5 * time.Minute
	stopWaitAttempts = 20
	stopWaitInterval = 200 * time.Millisecond
)

type appDefinition struct {
	ID          string   `json:"id"`
	Name        string   `json:"name"`
	Description string   `json:"description"`
	Icon        string   `json:"icon"`
	Accent      string   `json:"accent"`
	WebURL      string   `json:"web_url"`
	ProxyURL    string   `json:"proxy_url"`
	Command     string   `json:"command"`
	Arguments   []string `json:"arguments"`
	StopCommand string   `json:"stop_command"`
	StopArgs    []string `json:"stop_arguments"`
	Probe       string   `json:"probe"`
	WorkDir     string   `json:"workdir"`
}

type registry struct {
	Version int             `json:"version"`
	Apps    []appDefinition `json:"apps"`
}

type appState struct {
	ID                string `json:"id"`
	Name              string `json:"name"`
	Description       string `json:"description"`
	Icon              string `json:"icon"`
	Accent            string `json:"accent"`
	WebURL            string `json:"web_url"`
	ComputerConnected bool   `json:"computer_connected"`
	Enabled           bool   `json:"enabled"`
	Running           bool   `json:"running"`
	Code              string `json:"code"`
}

type response struct {
	OK                bool       `json:"ok"`
	Action            string     `json:"action,omitempty"`
	ComputerConnected bool       `json:"computer_connected,omitempty"`
	Enabled           bool       `json:"enabled,omitempty"`
	Running           bool       `json:"running,omitempty"`
	Code              string     `json:"code"`
	App               *appState  `json:"app,omitempty"`
	Apps              []appState `json:"apps,omitempty"`
}

type managedProcess struct {
	command *exec.Cmd
	done    chan struct{}
	started time.Time
}

type controlRequest struct {
	Action string `json:"action"`
	ID     string `json:"id,omitempty"`
}

func validWorkDir(value string) bool {
	if value == "" {
		return true
	}
	if !filepath.IsAbs(value) {
		return false
	}
	info, err := os.Stat(value)
	return err == nil && info.IsDir()
}

func loadRegistry() (registry, error) {
	contents, err := os.ReadFile(appsFile)
	if err != nil {
		return registry{}, err
	}
	var value registry
	if err := json.Unmarshal(contents, &value); err != nil {
		return registry{}, err
	}
	seen := map[string]bool{}
	for _, app := range value.Apps {
		target, targetError := url.Parse(app.ProxyURL)
		if !validID.MatchString(app.ID) || app.Name == "" || app.Command == "" || app.Probe == "" || seen[app.ID] || targetError != nil || target.Scheme != "http" || (target.Hostname() != "127.0.0.1" && target.Hostname() != "localhost") || !validWorkDir(app.WorkDir) {
			return registry{}, errors.New("invalid application registry")
		}
		seen[app.ID] = true
	}
	return value, nil
}

func findApp(id string) (appDefinition, error) {
	value, err := loadRegistry()
	if err != nil {
		return appDefinition{}, err
	}
	for _, app := range value.Apps {
		if app.ID == id {
			return app, nil
		}
	}
	return appDefinition{}, os.ErrNotExist
}

func enabledPath(id string) string {
	return filepath.Join(enabledRoot, id)
}

func isEnabled(id string) bool {
	_, err := os.Stat(enabledPath(id))
	return err == nil
}

func probeOpen(address string) bool {
	connection, err := net.DialTimeout("tcp", address, 500*time.Millisecond)
	if err != nil {
		return false
	}
	_ = connection.Close()
	return true
}

func currentAppState(app appDefinition) appState {
	enabled := isEnabled(app.ID)
	running := probeOpen(app.Probe)
	code := "stopped"
	if running {
		code = "ready"
	} else if enabled {
		code = "starting"
	}
	return appState{
		ID:                app.ID,
		Name:              app.Name,
		Description:       app.Description,
		Icon:              app.Icon,
		Accent:            app.Accent,
		WebURL:            app.WebURL,
		ComputerConnected: true,
		Enabled:           enabled,
		Running:           running,
		Code:              code,
	}
}

func stateResponse(app appDefinition, action string) response {
	state := currentAppState(app)
	return response{
		OK:                true,
		Action:            action,
		ComputerConnected: true,
		Enabled:           state.Enabled,
		Running:           state.Running,
		Code:              state.Code,
		App:               &state,
	}
}

func listApps() response {
	value, err := loadRegistry()
	if err != nil {
		return response{OK: false, ComputerConnected: true, Code: "registry_unavailable"}
	}
	apps := make([]appState, 0, len(value.Apps))
	for _, app := range value.Apps {
		apps = append(apps, currentAppState(app))
	}
	return response{OK: true, ComputerConnected: true, Code: "ready", Apps: apps}
}

func runHidden(timeout time.Duration, name string, args ...string) {
	if name == "" {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	command := exec.CommandContext(ctx, name, args...)
	command.Stdin = nil
	command.Stdout = io.Discard
	command.Stderr = io.Discard
	command.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow}
	_ = command.Run()
}

func startApp(id string) response {
	app, err := findApp(id)
	if err != nil {
		return response{OK: false, Action: "start", ComputerConnected: true, Code: "app_not_found"}
	}
	if err := os.MkdirAll(enabledRoot, 0o700); err != nil {
		return response{OK: false, Action: "start", ComputerConnected: true, Code: "state_update_failed"}
	}
	if err := os.WriteFile(enabledPath(id), []byte("enabled\n"), 0o600); err != nil {
		return response{OK: false, Action: "start", ComputerConnected: true, Code: "state_update_failed"}
	}
	time.Sleep(800 * time.Millisecond)
	return stateResponse(app, "start")
}

func stopApp(id string) response {
	app, err := findApp(id)
	if err != nil {
		return response{OK: false, Action: "stop", ComputerConnected: true, Code: "app_not_found"}
	}
	err = os.Remove(enabledPath(id))
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return response{OK: false, Action: "stop", ComputerConnected: true, Code: "state_update_failed"}
	}
	runHidden(10*time.Second, app.StopCommand, app.StopArgs...)
	for attempt := 0; attempt < stopWaitAttempts && probeOpen(app.Probe); attempt++ {
		time.Sleep(stopWaitInterval)
	}
	result := stateResponse(app, "stop")
	if result.Running {
		result.Code = "stopping"
		if result.App != nil {
			result.App.Code = "stopping"
		}
	}
	return result
}

func statusApp(id string) response {
	app, err := findApp(id)
	if err != nil {
		return response{OK: false, Action: "status", ComputerConnected: true, Code: "app_not_found"}
	}
	return stateResponse(app, "status")
}

func openLogFile(path string) (*os.File, error) {
	if info, err := os.Stat(path); err == nil && info.Size() > maxLogBytes {
		_ = os.Remove(path + ".old")
		_ = os.Rename(path, path+".old")
	}
	return os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
}

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

func controlLog(format string, args ...any) {
	file, err := openLogFile(filepath.Join(logsRoot, "control.log"))
	if err != nil {
		return
	}
	defer file.Close()
	_, _ = fmt.Fprintf(file, "%s %s\n", time.Now().Format("2006-01-02 15:04:05"), fmt.Sprintf(format, args...))
}

func launch(app appDefinition) (*managedProcess, error) {
	if err := os.MkdirAll(logsRoot, 0o700); err != nil {
		return nil, err
	}
	logFile, err := openLogFile(filepath.Join(logsRoot, app.ID+".log"))
	if err != nil {
		return nil, err
	}
	command := exec.Command(app.Command, app.Arguments...)
	if app.WorkDir != "" {
		command.Dir = app.WorkDir
	}
	command.Stdin = nil
	command.Stdout = logFile
	command.Stderr = logFile
	command.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow}
	if err := command.Start(); err != nil {
		_ = logFile.Close()
		return nil, err
	}
	controlLog("app %s launched pid=%d", app.ID, command.Process.Pid)
	managed := &managedProcess{command: command, done: make(chan struct{}), started: time.Now()}
	go func() {
		_ = command.Wait()
		_ = logFile.Close()
		close(managed.done)
	}()
	return managed, nil
}

func supervise() {
	_ = os.MkdirAll(enabledRoot, 0o700)
	processes := map[string]*managedProcess{}
	failures := map[string]int{}
	retryAfter := map[string]time.Time{}
	for {
		value, err := loadRegistry()
		if err == nil {
			known := map[string]bool{}
			for _, app := range value.Apps {
				known[app.ID] = true
				managed := processes[app.ID]
				if managed != nil {
					select {
					case <-managed.done:
						delete(processes, app.ID)
						if time.Since(managed.started) < stableRunPeriod {
							failures[app.ID]++
							delay := backoff(failures[app.ID])
							retryAfter[app.ID] = time.Now().Add(delay)
							controlLog("app %s exited early (failures=%d), retry in %s", app.ID, failures[app.ID], delay)
						} else {
							failures[app.ID] = 0
							delete(retryAfter, app.ID)
							controlLog("app %s exited", app.ID)
						}
						managed = nil
					default:
					}
				}
				if !isEnabled(app.ID) {
					if managed != nil && managed.command.Process != nil {
						controlLog("app %s disabled, killing pid=%d", app.ID, managed.command.Process.Pid)
						_ = managed.command.Process.Kill()
					}
					continue
				}
				if !probeOpen(app.Probe) && managed == nil && time.Now().After(retryAfter[app.ID]) {
					if started, startError := launch(app); startError == nil {
						processes[app.ID] = started
					} else {
						failures[app.ID]++
						delay := backoff(failures[app.ID])
						retryAfter[app.ID] = time.Now().Add(delay)
						controlLog("app %s launch failed (failures=%d), retry in %s: %v", app.ID, failures[app.ID], delay, startError)
					}
				}
			}
			for id, managed := range processes {
				if !known[id] && managed.command.Process != nil {
					controlLog("app %s removed from registry, killing pid=%d", id, managed.command.Process.Pid)
					_ = managed.command.Process.Kill()
					delete(processes, id)
				}
			}
		}
		time.Sleep(2 * time.Second)
	}
}

func selectedApplication(request *http.Request) (appDefinition, error) {
	cookie, err := request.Cookie("RemoteEverythingApp")
	if err != nil || !validID.MatchString(cookie.Value) {
		return appDefinition{}, os.ErrNotExist
	}
	return findApp(cookie.Value)
}

func removeRoutingCookie(request *http.Request) {
	values := make([]string, 0)
	for _, cookie := range request.Cookies() {
		if cookie.Name != "RemoteEverythingApp" {
			values = append(values, cookie.Name+"="+cookie.Value)
		}
	}
	request.Header.Del("Cookie")
	if len(values) > 0 {
		request.Header.Set("Cookie", strings.Join(values, "; "))
	}
}

func gatewayMessage(writer http.ResponseWriter, status int, title string, detail string) {
	body := "<!doctype html><html lang=\"zh-CN\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><meta name=\"color-scheme\" content=\"dark\"><title>" + title + "</title><style>body{margin:0;min-height:100vh;display:grid;place-items:center;padding:24px;box-sizing:border-box;background:#020617;color:#f8fafc;font:16px system-ui}main{max-width:520px;padding:30px;border:1px solid #1e293b;border-radius:22px;background:#0f172a}h1{font-size:28px}p{color:#94a3b8;line-height:1.7}</style><main><h1>" + title + "</h1><p>" + detail + "</p></main></html>"
	writer.Header().Set("Content-Type", "text/html; charset=utf-8")
	writer.Header().Set("Cache-Control", "no-store")
	writer.WriteHeader(status)
	_, _ = writer.Write([]byte(body))
}

func gatewayHandler(writer http.ResponseWriter, request *http.Request) {
	if request.URL.Path == "/__local_remote_control" {
		localControlHandler(writer, request)
		return
	}
	app, err := selectedApplication(request)
	if err != nil {
		gatewayMessage(writer, http.StatusOK, "尚未选择远程应用", "请从 远程万物手机客户端的应用目录进入。")
		return
	}
	target, err := url.Parse(app.ProxyURL)
	if err != nil {
		gatewayMessage(writer, http.StatusBadGateway, "应用配置不可用", "远程应用的代理地址无效。")
		return
	}
	removeRoutingCookie(request)
	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.ErrorHandler = func(responseWriter http.ResponseWriter, _ *http.Request, _ error) {
		gatewayMessage(responseWriter, http.StatusBadGateway, app.Name+" 尚未运行", "请返回应用目录启动它，然后重新进入。")
	}
	proxy.ServeHTTP(writer, request)
}

func localControlHandler(writer http.ResponseWriter, request *http.Request) {
	token, err := os.ReadFile(controlTokenFile)
	expected := "Bearer " + strings.TrimSpace(string(token))
	if err != nil || len(expected) < 40 || subtle.ConstantTimeCompare([]byte(request.Header.Get("Authorization")), []byte(expected)) != 1 {
		controlLog("control auth failed remote=%s", request.RemoteAddr)
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
	if decoder.Decode(&input) != nil {
		writer.WriteHeader(http.StatusBadRequest)
		return
	}
	result := response{OK: false, Code: "command_not_allowed"}
	switch input.Action {
	case "list":
		if input.ID == "" {
			result = listApps()
		}
	case "status":
		if validID.MatchString(input.ID) {
			result = statusApp(input.ID)
		}
	case "start":
		if validID.MatchString(input.ID) {
			result = startApp(input.ID)
		}
	case "stop":
		if validID.MatchString(input.ID) {
			result = stopApp(input.ID)
		}
	}
	controlLog("control action=%s id=%s code=%s", input.Action, input.ID, result.Code)
	writer.Header().Set("Content-Type", "application/json; charset=utf-8")
	writer.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(writer).Encode(result)
}

func serveAll() {
	go supervise()
	server := &http.Server{
		Addr:              "127.0.0.1:58627",
		Handler:           http.HandlerFunc(gatewayHandler),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       90 * time.Second,
	}
	if err := server.ListenAndServe(); err != nil {
		os.Exit(1)
	}
}

func main() {
	parts := os.Args[1:]
	if len(parts) == 1 && parts[0] == "serve" {
		serveAll()
		return
	}
	if len(parts) == 1 && parts[0] == "files" {
		serveFiles()
		return
	}
	result := response{OK: false, Code: "command_not_allowed"}
	exitCode := 0
	if len(parts) == 1 && parts[0] == "list" {
		result = listApps()
	} else if len(parts) >= 1 && len(parts) <= 2 {
		id := "kimi"
		if len(parts) == 2 && validID.MatchString(parts[1]) {
			id = parts[1]
		}
		switch parts[0] {
		case "status":
			result = statusApp(id)
		case "start":
			result = startApp(id)
		case "stop":
			result = stopApp(id)
		default:
			exitCode = 64
		}
	} else {
		exitCode = 64
	}
	if !result.OK && result.Code == "command_not_allowed" {
		exitCode = 64
	}
	_ = json.NewEncoder(os.Stdout).Encode(result)
	os.Exit(exitCode)
}
