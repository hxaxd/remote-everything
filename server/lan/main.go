package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

const lanUsage = "usage: remote-everything-lan-server init --state ABSOLUTE_PATH --node-address HOST:PORT --node-bootstrap ABSOLUTE_PATH --host HOST [--valid-days DAYS] | certificate renew --state ABSOLUTE_PATH [--valid-days DAYS] | ports repair --state ABSOLUTE_PATH | serve --state ABSOLUTE_PATH | device --state ABSOLUTE_PATH (list | revoke FINGERPRINT | invite --name NAME [--origin HTTPS_ORIGIN] [--ttl DURATION] [--qr ABSOLUTE_PATH] | renew --name NAME [--origin HTTPS_ORIGIN] [--ttl DURATION] [--qr ABSOLUTE_PATH] FINGERPRINT | invitation list | invitation cancel TOKEN_HASH)"

func main() {
	args := os.Args[1:]
	if len(args) > 0 && args[0] == "init" {
		if err := runLANInit(args[1:], os.Stdout); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	if len(args) > 0 && (args[0] == "serve" || args[0] == "device") {
		flags := flag.NewFlagSet(args[0], flag.ContinueOnError)
		flags.SetOutput(io.Discard)
		stateRoot := flags.String("state", "", "")
		if flags.Parse(args[1:]) == nil && filepath.IsAbs(*stateRoot) {
			service, openErr := openLANService(*stateRoot)
			if openErr != nil {
				fmt.Fprintln(os.Stderr, openErr)
				os.Exit(1)
			}
			if args[0] == "serve" && flags.NArg() == 0 {
				if err := service.serveGateway(); err != nil {
					fmt.Fprintln(os.Stderr, err)
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
		stateRoot := flags.String("state", "", "")
		if flags.Parse(args[2:]) == nil && flags.NArg() == 0 {
			if result, err := repairLANPorts(*stateRoot); err == nil {
				_ = json.NewEncoder(os.Stdout).Encode(result)
				return
			} else {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
		}
	}
	if len(args) > 1 && args[0] == "certificate" && args[1] == "renew" {
		flags := flag.NewFlagSet("certificate renew", flag.ContinueOnError)
		flags.SetOutput(io.Discard)
		stateRoot := flags.String("state", "", "")
		validDays := flags.Int("valid-days", 825, "")
		if flags.Parse(args[2:]) == nil && flags.NArg() == 0 {
			if result, err := renewLANCertificate(*stateRoot, *validDays); err == nil {
				_ = json.NewEncoder(os.Stdout).Encode(result)
				return
			} else {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
		}
	}
	fmt.Fprintln(os.Stderr, lanUsage)
	os.Exit(64)
}
