package main

import (
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"

	"github.com/hxaxd/remote-everything/internal/gatewaycore"
	"github.com/hxaxd/remote-everything/internal/logline"
)

// serveGateway serves the two listeners the 443 entrance forwards to: the status
// surface (device activation, admission, then the gateway) and the pairing
// surface an invitation is redeemed at.
func (service *publicService) serveGateway() error {
	statusServer := gatewaycore.NewServer(service.listen("status"), service.trust.StatusHandler())
	pairingServer := gatewaycore.NewServer(service.listen("pairing"), service.trust.PairHandler())

	stopped := make(chan error, 2)
	start := func(name string, server *http.Server) {
		go func() {
			logline.Log(name, "info", "listening", "path", server.Addr)
			stopped <- server.ListenAndServe()
		}()
	}
	start("status-server", statusServer)
	start("pairing-server", pairingServer)
	return <-stopped
}

func main() {
	args := os.Args[1:]
	if len(args) > 0 && args[0] == "init" {
		if err := runPublicInit(args[1:], os.Stdout); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	if len(args) > 0 && (args[0] == "serve" || args[0] == "device") {
		flags := flag.NewFlagSet(args[0], flag.ContinueOnError)
		flags.SetOutput(io.Discard)
		state := flags.String("state", "", "")
		if flags.Parse(args[1:]) == nil {
			service, openErr := openPublicService(*state)
			if openErr != nil {
				fmt.Fprintln(os.Stderr, openErr)
				os.Exit(1)
			}
			if args[0] == "serve" && flags.NArg() == 0 {
				if err := service.serveGateway(); err != nil {
					logline.Log("gateway", "error", "server stopped", "code", err.Error())
					os.Exit(1)
				}
				return
			}
			if args[0] == "device" {
				if err := service.trust.RunCLI(flags.Args(), os.Stdout); err != nil {
					fmt.Fprintln(os.Stderr, err)
					os.Exit(1)
				}
				return
			}
		}
	}
	if len(args) > 1 && args[0] == "ports" && args[1] == "repair" {
		flags := flag.NewFlagSet("ports repair", flag.ContinueOnError)
		flags.SetOutput(io.Discard)
		state := flags.String("state", "", "")
		if flags.Parse(args[2:]) == nil && flags.NArg() == 0 {
			if err := repairPublicPorts(*state, os.Stdout); err == nil {
				return
			} else {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
		}
	}
	if len(args) > 1 && args[0] == "tunnel" && args[1] == "renew" {
		flags := flag.NewFlagSet("tunnel renew", flag.ContinueOnError)
		flags.SetOutput(io.Discard)
		state := flags.String("state", "", "")
		nodeBootstrap := flags.String("node-bootstrap", "", "")
		if flags.Parse(args[2:]) == nil && flags.NArg() == 0 {
			if err := renewTunnelIdentity(*state, *nodeBootstrap, os.Stdout); err == nil {
				return
			} else {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
		}
	}
	fmt.Fprintln(os.Stderr, "usage: remote-everything-gateway init --state ABSOLUTE_PATH --node-bootstrap ABSOLUTE_PATH | ports repair --state ABSOLUTE_PATH | tunnel renew --state ABSOLUTE_PATH --node-bootstrap ABSOLUTE_PATH | serve --state ABSOLUTE_PATH | device --state ABSOLUTE_PATH (list | approve FINGERPRINT | invite --name NAME --origin HTTPS_ORIGIN [--ttl DURATION] [--qr ABSOLUTE_PATH] | renew --name NAME --origin HTTPS_ORIGIN [--ttl DURATION] [--qr ABSOLUTE_PATH] FINGERPRINT | invitation list | invitation cancel TOKEN_HASH | revoke FINGERPRINT)")
	os.Exit(64)
}
