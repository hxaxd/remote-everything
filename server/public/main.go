package main

import (
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
)

type errorResponse struct {
	OK   bool   `json:"ok"`
	Code string `json:"code"`
}

func errorBody(code string) errorResponse {
	return errorResponse{OK: false, Code: code}
}

func (service *publicService) serveGateway() error {
	statusServer, err := service.newStatusServer()
	if err != nil {
		return fmt.Errorf("load control token: %w", err)
	}
	pairingServer, err := service.newPairingServer()
	if err != nil {
		return fmt.Errorf("prepare pairing service: %w", err)
	}

	stopped := make(chan error, 2)
	start := func(name string, server *http.Server) {
		go func() {
			logLine(name, "info", "listening", "path", server.Addr)
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
					logLine("gateway", "error", "server stopped", "code", err.Error())
					os.Exit(1)
				}
				return
			}
			if args[0] == "device" {
				if err := service.runDeviceCLI(flags.Args(), os.Stdout); err != nil {
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
	fmt.Fprintln(os.Stderr, "usage: remote-everything-gateway init --state ABSOLUTE_PATH --node-bootstrap ABSOLUTE_PATH | ports repair --state ABSOLUTE_PATH | tunnel renew --state ABSOLUTE_PATH --node-bootstrap ABSOLUTE_PATH | serve --state ABSOLUTE_PATH | device --state ABSOLUTE_PATH (list | invite --name NAME --origin HTTPS_ORIGIN [--ttl DURATION] [--qr ABSOLUTE_PATH] | renew --name NAME --origin HTTPS_ORIGIN [--ttl DURATION] [--qr ABSOLUTE_PATH] FINGERPRINT | invitation list | invitation cancel TOKEN_HASH | revoke FINGERPRINT)")
	os.Exit(64)
}
