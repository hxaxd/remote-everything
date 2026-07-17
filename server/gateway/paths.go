package main

import (
	"os/exec"
	"strings"
)

// Server paths, overridable in tests.
var (
	enrollStateDir           = "/var/lib/kimi-enrollment/requests"
	bootstrapFingerprintFile = "/etc/kimi-gateway/bootstrap-fingerprint"
	controlTokenFile         = "/etc/kimi-gateway/control-token"
	appsCacheFile            = "/var/lib/kimi-control/apps-cache.json"
	localControlURL          = "http://127.0.0.1:58628/__local_agent_control"
	approvedDir              = "/etc/kimi-gateway/approved-clients"
	bootstrapCAFile          = "/etc/kimi-gateway/bootstrap-ca.crt.pem"
	trustBundleFile          = "/etc/kimi-gateway/client-trust.pem"
	issuerKeyFile            = "/etc/kimi-gateway/device-issuer.key.pem"
	issuerCertFile           = "/etc/kimi-gateway/device-issuer.crt.pem"
	caddyConfigFile          = "/etc/caddy/Caddyfile"
	enrollUser               = "kimi-enroll"
)

// Injectable hooks so tests can replace platform behavior.
var (
	euidFunc  = platformEUID
	chownFunc = platformChownUser
	execFunc  = runChecked
)

func runChecked(name string, args ...string) error {
	command := exec.Command(name, args...)
	output, err := command.CombinedOutput()
	if err != nil {
		return &commandError{cmd: name + " " + strings.Join(args, " "), output: string(output), err: err}
	}
	return nil
}

type commandError struct {
	cmd    string
	output string
	err    error
}

func (e *commandError) Error() string {
	return e.cmd + ": " + e.err.Error() + ": " + strings.TrimSpace(e.output)
}
