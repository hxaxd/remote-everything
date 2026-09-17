package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"runtime"

	"github.com/hxaxd/remote-everything/internal/entrance"
)

// requireLinux refuses to run this shape anywhere else. It is not only what is
// released for it that is Linux: the account a systemd unit runs it as owns its
// state, a systemd timer keeps its tunnel alive, and the 443 entrance in front
// of it is claimed and inspected through Linux. Elsewhere it would start and
// never be deployable, which is worse than not starting.
func requireLinux(goos string) error {
	if goos != "linux" {
		return fmt.Errorf("a public gateway runs on Linux, not on %s", goos)
	}
	return nil
}

const publicUsage = "usage: remote-everything-gateway init --state ABSOLUTE_PATH --origin HTTPS_ORIGIN | node add --state ABSOLUTE_PATH --name NAME --node-id NODE_ID --node-bootstrap ABSOLUTE_PATH | node list --state ABSOLUTE_PATH | node remove --state ABSOLUTE_PATH --node NODE | node token renew --state ABSOLUTE_PATH --node NODE --node-bootstrap ABSOLUTE_PATH | ports repair --state ABSOLUTE_PATH | tunnel renew --state ABSOLUTE_PATH --node-bootstrap ABSOLUTE_PATH | serve --state ABSOLUTE_PATH | device --state ABSOLUTE_PATH (list | approve FINGERPRINT | grant --node NODE FINGERPRINT | revoke [--node NODE] FINGERPRINT | invite --name NAME --node NODE [--ttl DURATION] [--qr ABSOLUTE_PATH] | renew --name NAME --node NODE [--ttl DURATION] [--qr ABSOLUTE_PATH] FINGERPRINT | invitation list | invitation cancel TOKEN_HASH)"

func main() {
	if err := requireLinux(runtime.GOOS); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	args := os.Args[1:]
	if len(args) > 0 && args[0] == "init" {
		if err := runPublicInit(args[1:], os.Stdout); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	if len(args) > 0 && args[0] == "node" {
		if err := runPublicNode(args[1:], os.Stdout); err != nil {
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
	fmt.Fprintln(os.Stderr, publicUsage)
	os.Exit(64)
}
