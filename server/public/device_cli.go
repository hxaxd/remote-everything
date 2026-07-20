package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"strings"
	"time"
)

func (service *publicService) runDeviceCLI(args []string, output io.Writer) error {
	if len(args) == 0 {
		return errors.New("missing device action")
	}
	switch args[0] {
	case "list":
		if len(args) != 1 {
			return errors.New("invalid device list arguments")
		}
		return service.deviceList(output)
	case "revoke":
		if len(args) != 2 {
			return errors.New("invalid device revoke arguments")
		}
		return service.deviceRevoke(args[1], output)
	case "approve":
		if len(args) != 2 {
			return errors.New("invalid device approve arguments")
		}
		return service.deviceApprove(args[1], output)
	case "invite":
		flags := flag.NewFlagSet("device invite", flag.ContinueOnError)
		flags.SetOutput(io.Discard)
		ttlText := flags.String("ttl", "10m", "")
		name := flags.String("name", "", "")
		origin := flags.String("origin", "", "")
		qrFile := flags.String("qr", "", "")
		if flags.Parse(args[1:]) != nil || flags.NArg() != 0 || strings.TrimSpace(*name) == "" || strings.TrimSpace(*origin) == "" {
			return errors.New("invalid device invite arguments")
		}
		ttl, err := time.ParseDuration(*ttlText)
		if err != nil {
			return fmt.Errorf("invalid invite ttl: %w", err)
		}
		return service.issueInvitation(ttl, *name, *origin, *qrFile, output)
	case "renew":
		flags := flag.NewFlagSet("device renew", flag.ContinueOnError)
		flags.SetOutput(io.Discard)
		ttlText := flags.String("ttl", "10m", "")
		name := flags.String("name", "", "")
		origin := flags.String("origin", "", "")
		qrFile := flags.String("qr", "", "")
		if flags.Parse(args[1:]) != nil || flags.NArg() != 1 || strings.TrimSpace(*name) == "" || strings.TrimSpace(*origin) == "" {
			return errors.New("invalid device renew arguments")
		}
		ttl, err := time.ParseDuration(*ttlText)
		if err != nil {
			return fmt.Errorf("invalid renewal ttl: %w", err)
		}
		return service.issueRenewalInvitation(ttl, *name, *origin, *qrFile, flags.Arg(0), output)
	case "invitation":
		if len(args) == 2 && args[1] == "list" {
			return service.invitationList(output)
		}
		if len(args) == 3 && args[1] == "cancel" {
			return service.invitationCancel(args[2], output)
		}
		return errors.New("invalid invitation arguments")
	default:
		return errors.New("unknown device action")
	}
}
