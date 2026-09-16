package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/hxaxd/remote-everything/internal/entrance"
)

func main() {
	args := os.Args[1:]
	if len(args) > 0 && args[0] == "init" {
		if err := runPublicInit(args[1:], os.Stdout); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	// The commands every gateway has: opening the state is what tells this one
	// apart from the other shape, and nothing after that does.
	open := func(root string) (entrance.Gateway, error) { return openPublicService(root) }
	if handled, code := entrance.Run(args, open, os.Stdout, os.Stderr); handled {
		os.Exit(code)
	}
	if len(args) > 1 && args[0] == "ports" && args[1] == "repair" {
		flags := flag.NewFlagSet("ports repair", flag.ContinueOnError)
		flags.SetOutput(io.Discard)
		state := flags.String("state", "", "")
		if flags.Parse(args[2:]) == nil && flags.NArg() == 0 {
			if result, err := repairPublicPorts(*state); err == nil {
				_ = json.NewEncoder(os.Stdout).Encode(result)
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
			if result, err := renewTunnelIdentity(*state, *nodeBootstrap); err == nil {
				_ = json.NewEncoder(os.Stdout).Encode(result)
				return
			} else {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
		}
	}
	fmt.Fprintln(os.Stderr, "usage: remote-everything-gateway init --state ABSOLUTE_PATH --node-bootstrap ABSOLUTE_PATH --origin HTTPS_ORIGIN | ports repair --state ABSOLUTE_PATH | tunnel renew --state ABSOLUTE_PATH --node-bootstrap ABSOLUTE_PATH | serve --state ABSOLUTE_PATH | device --state ABSOLUTE_PATH (list | approve FINGERPRINT | invite --name NAME [--ttl DURATION] [--qr ABSOLUTE_PATH] | renew --name NAME [--ttl DURATION] [--qr ABSOLUTE_PATH] FINGERPRINT | invitation list | invitation cancel TOKEN_HASH | revoke FINGERPRINT)")
	os.Exit(64)
}
