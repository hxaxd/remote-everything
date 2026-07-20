package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/hxaxd/remote-everything/internal/gatewaycore"
)

func setupStatusTest(t *testing.T) (*publicService, string, *httptest.Server) {
	t.Helper()
	service := setupPublicTest(t)
	token := strings.Repeat("01", 32)
	fingerprint := strings.Repeat("ab", 32)
	if err := service.writeDeviceRecord(deviceRecord{
		Schema: recordSchema, DeviceName: "Phone", CertificateFingerprint: fingerprint,
		Status: "approved", CreatedAt: isoUTC(time.Now()), CertificateExpiresAt: isoUTC(time.Now().Add(825 * 24 * time.Hour)), ActivatedAt: isoUTC(time.Now()),
	}); err != nil {
		t.Fatal(err)
	}
	node := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path == "/__local_remote_control" {
			var input map[string]string
			_ = json.NewDecoder(request.Body).Decode(&input)
			if input["action"] == "list" {
				_, _ = io.WriteString(writer, `{"ok":true,"computer_connected":true,"code":"ready","apps":[{"id":"fixture","name":"Fixture","description":"","icon":"F","accent":"#2563eb","computer_connected":true,"enabled":true,"running":true,"code":"ready"}]}`)
				return
			}
			_, _ = io.WriteString(writer, `{"ok":true,"action":"`+input["action"]+`","computer_connected":true,"enabled":true,"running":true,"code":"ready","app":{"id":"fixture","name":"Fixture","description":"","icon":"F","accent":"#2563eb","computer_connected":true,"enabled":true,"running":true,"code":"ready"}}`)
			return
		}
		if request.Header.Get(clientFingerprintHeader) != "" || request.Header.Get("Authorization") != "" || request.Header.Get("X-Remote-Everything-Control-Token") != "" {
			writer.WriteHeader(http.StatusBadRequest)
			return
		}
		_, _ = io.WriteString(writer, "proxied")
	}))
	service.gateway, _ = gatewaycore.New(node.URL, token)
	return service, fingerprint, node
}

func statusRequest(service *publicService, method, target, fingerprint string) *httptest.ResponseRecorder {
	request := httptest.NewRequest(method, target, nil)
	if fingerprint != "" {
		request.Header.Set(clientFingerprintHeader, fingerprint)
	}
	recorder := httptest.NewRecorder()
	service.statusHTTPHandler(recorder, request)
	return recorder
}

func TestStatusAuthorizationAndRoutes(t *testing.T) {
	service, fingerprint, node := setupStatusTest(t)
	defer node.Close()
	if result := statusRequest(service, http.MethodGet, "/healthz", ""); result.Code != http.StatusOK {
		t.Fatalf("health status = %d", result.Code)
	}
	if result := statusRequest(service, http.MethodGet, "/__remote_everything/apps", ""); result.Code != http.StatusUnauthorized {
		t.Fatalf("unauthorized apps status = %d", result.Code)
	}
	if result := statusRequest(service, http.MethodGet, "/__remote_everything/apps", fingerprint); result.Code != http.StatusOK || !strings.Contains(result.Body.String(), "fixture") {
		t.Fatalf("apps response = %d %s", result.Code, result.Body.String())
	}
	if result := statusRequest(service, http.MethodGet, "/__remote_everything/open/fixture", fingerprint); result.Code != http.StatusFound {
		t.Fatalf("open status = %d", result.Code)
	}
	if result := statusRequest(service, http.MethodPost, "/__remote_everything/apps/fixture/start", fingerprint); result.Code != http.StatusOK {
		t.Fatalf("start status = %d", result.Code)
	}
}

func TestApplicationProxyStripsInternalHeaders(t *testing.T) {
	service, fingerprint, node := setupStatusTest(t)
	defer node.Close()
	request := httptest.NewRequest(http.MethodGet, "/page", nil)
	request.Header.Set(clientFingerprintHeader, fingerprint)
	request.Header.Set("Authorization", "secret")
	request.Header.Set("X-Remote-Everything-Control-Token", "secret")
	recorder := httptest.NewRecorder()
	service.statusHTTPHandler(recorder, request)
	if recorder.Code != http.StatusOK || recorder.Body.String() != "proxied" {
		t.Fatalf("proxy response = %d %q", recorder.Code, recorder.Body.String())
	}
}
