package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/hxaxd/remote-everything/internal/entrance"
)

const lanUsage = "usage: remote-everything-lan-server init --state ABSOLUTE_PATH --node-address HOST:PORT --node-bootstrap ABSOLUTE_PATH --host HOST [--valid-days DAYS] | certificate renew --state ABSOLUTE_PATH [--valid-days DAYS] | ports repair --state ABSOLUTE_PATH | serve --state ABSOLUTE_PATH | device --state ABSOLUTE_PATH (list | revoke FINGERPRINT | invite --name NAME [--ttl DURATION] [--qr ABSOLUTE_PATH] | renew --name NAME [--ttl DURATION] [--qr ABSOLUTE_PATH] FINGERPRINT | invitation list | invitation cancel TOKEN_HASH)"

func main() {
	args := os.Args[1:]
	if len(args) > 0 && args[0] == "init" {
		if err := runLANInit(args[1:], os.Stdout); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	// The commands every gateway has: opening the state is what tells this one
	// apart from the other shape, and nothing after that does.
	open := func(root string) (entrance.Gateway, error) { return openLANService(root) }
	if handled, code := entrance.Run(args, open, os.Stdout, os.Stderr); handled {
		os.Exit(code)
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
