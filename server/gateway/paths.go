package main

import (
	"os/exec"
	"strings"
)

// Server paths, overridable in tests.
var (
	enrollStateDir           = "/var/lib/remote-everything-enrollment/requests"
	bootstrapFingerprintFile = "/etc/remote-everything-gateway/bootstrap-fingerprint"
	controlTokenFile         = "/etc/remote-everything-gateway/control-token"
	appsCacheFile            = "/var/lib/remote-everything-control/apps-cache.json"
	localControlURL          = "http://127.0.0.1:58628/__local_remote_control"
	approvedDir              = "/etc/remote-everything-gateway/approved-clients"
	bootstrapCAFile          = "/etc/remote-everything-gateway/bootstrap-ca.crt.pem"
	trustBundleFile          = "/etc/remote-everything-gateway/client-trust.pem"
	issuerKeyFile            = "/etc/remote-everything-gateway/device-issuer.key.pem"
	issuerCertFile           = "/etc/remote-everything-gateway/device-issuer.crt.pem"
	caddyConfigFile          = "/etc/caddy/Caddyfile"
	enrollUser               = "remote-everything-enroll"
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
