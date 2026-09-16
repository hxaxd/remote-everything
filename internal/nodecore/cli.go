package nodecore

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
)

const Usage = "usage: remote-everything-control init --state ABSOLUTE_PATH [--control-token-file ABSOLUTE_PATH | --bootstrap ABSOLUTE_PATH] | ports repair --state ABSOLUTE_PATH | serve --state ABSOLUTE_PATH | app list --state ABSOLUTE_PATH | app set --state ABSOLUTE_PATH --file FILE | app remove --state ABSOLUTE_PATH ID"

func runInit(parts []string, output io.Writer) error {
	flags := flag.NewFlagSet("init", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	state := flags.String("state", "", "")
	tokenFile := flags.String("control-token-file", "", "")
	bootstrapRoot := flags.String("bootstrap", "", "")
	if flags.Parse(parts) != nil || flags.NArg() != 0 || (*tokenFile != "" && *bootstrapRoot != "") {
		return errors.New("invalid init arguments")
	}
	var result InitResult
	var err error
	if *bootstrapRoot != "" {
		result, err = InitializeFromBootstrap(*state, *bootstrapRoot)
	} else {
		result, err = Initialize(*state, *tokenFile)
	}
	if err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(result)
}

func runApp(parts []string, platform Platform, output io.Writer) error {
	if len(parts) == 0 {
		return errors.New("missing app action")
	}
	flags := flag.NewFlagSet("app "+parts[0], flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	state := flags.String("state", "", "")
	definition := flags.String("file", "", "")
	if flags.Parse(parts[1:]) != nil {
		return errors.New("invalid app arguments")
	}
	node, err := Open(*state, platform)
	if err != nil {
		return err
	}
	switch parts[0] {
	case "list":
		if flags.NArg() != 0 || *definition != "" {
			return errors.New("invalid app list arguments")
		}
		return node.listRegistry(output)
	case "set":
		if flags.NArg() != 0 || *definition == "" {
			return errors.New("invalid app set arguments")
		}
		return node.setApp(*definition, output)
	case "remove":
		if flags.NArg() != 1 || *definition != "" {
			return errors.New("invalid app remove arguments")
		}
		return node.removeApp(flags.Arg(0), output)
	default:
		return errors.New("unknown app action")
	}
}

func runPorts(parts []string, output io.Writer) error {
	flags := flag.NewFlagSet("ports repair", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	state := flags.String("state", "", "")
	if len(parts) < 1 || parts[0] != "repair" || flags.Parse(parts[1:]) != nil || flags.NArg() != 0 {
		return errors.New("invalid ports repair arguments")
	}
	result, err := RepairPorts(*state)
	if err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(result)
}

func runServe(parts []string, platform Platform) error {
	flags := flag.NewFlagSet("serve", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	state := flags.String("state", "", "")
	if flags.Parse(parts) != nil || flags.NArg() != 0 {
		return errors.New("invalid serve arguments")
	}
	node, err := Open(*state, platform)
	if err != nil {
		return err
	}
	return node.Serve()
}

func Run(parts []string, platform Platform, stdout, stderr io.Writer) int {
	if len(parts) == 0 {
		fmt.Fprintln(stderr, Usage)
		return 64
	}
	var err error
	switch parts[0] {
	case "init":
		err = runInit(parts[1:], stdout)
	case "app":
		err = runApp(parts[1:], platform, stdout)
	case "ports":
		err = runPorts(parts[1:], stdout)
	case "serve":
		err = runServe(parts[1:], platform)
	default:
		fmt.Fprintln(stderr, Usage)
		return 64
	}
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	return 0
}
