package devicecore

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/hxaxd/remote-everything/internal/gatewaycore"
)

func (service *Trust) runDeviceCLI(args []string, output io.Writer) error {
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
		flags := flag.NewFlagSet("device revoke", flag.ContinueOnError)
		flags.SetOutput(io.Discard)
		nodeValue := flags.String("node", "", "")
		if flags.Parse(args[1:]) != nil || flags.NArg() != 1 {
			return errors.New("invalid device revoke arguments")
		}
		nodeID := ""
		if *nodeValue != "" {
			node, err := service.resolveNode(*nodeValue)
			if err != nil {
				return err
			}
			nodeID = node.ID
		}
		return service.deviceRevoke(flags.Arg(0), nodeID, output)
	case "grant":
		flags := flag.NewFlagSet("device grant", flag.ContinueOnError)
		flags.SetOutput(io.Discard)
		nodeValue := flags.String("node", "", "")
		if flags.Parse(args[1:]) != nil || flags.NArg() != 1 || *nodeValue == "" {
			return errors.New("invalid device grant arguments")
		}
		node, err := service.resolveNode(*nodeValue)
		if err != nil {
			return err
		}
		return service.deviceGrant(flags.Arg(0), node.ID, output)
	case "approve":
		if len(args) != 2 {
			return errors.New("invalid device approve arguments")
		}
		// A gateway whose invitation is the approval has nothing waiting: the
		// operator who handed that invitation over admitted the device with it, and
		// saying so is better than reporting a device that is not there.
		if service.approveOnRedemption {
			return errors.New("this gateway admits the device its invitation was handed to, so there is nothing to approve")
		}
		return service.deviceApprove(args[1], output)
	case "invite":
		return service.inviteCLI(args[1:], output)
	case "renew":
		return service.renewCLI(args[1:], output)
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

// resolveNode finds the node an operator named. How a node is named — by the name
// it was given or by its id, because a name is what an operator types and a node id
// is 64 hex characters nobody reads out loud — is one rule with one home, and this
// is this gateway's nodes asked by it.
func (service *Trust) resolveNode(value string) (gatewaycore.Node, error) {
	return gatewaycore.ResolveNode(service.node.Nodes(), value)
}

// inviteCLI hands out an invitation to one node. The device name is the name the
// device will be recorded under, and the node is what the invitation opens: an
// invitation is for one machine, and redeeming it is what grants that device
// access to it.
func (service *Trust) inviteCLI(parts []string, output io.Writer) error {
	flags := flag.NewFlagSet("device invite", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	ttlText := flags.String("ttl", "10m", "")
	name := flags.String("name", "", "")
	nodeValue := flags.String("node", "", "")
	qrFile := flags.String("qr", "", "")
	if flags.Parse(parts) != nil || flags.NArg() != 0 || strings.TrimSpace(*name) == "" || *nodeValue == "" {
		return errors.New("invalid device invite arguments")
	}
	ttl, err := time.ParseDuration(*ttlText)
	if err != nil {
		return fmt.Errorf("invalid invite ttl: %w", err)
	}
	node, err := service.resolveNode(*nodeValue)
	if err != nil {
		return err
	}
	return service.issueInvitation(ttl, node, *name, *qrFile, output)
}

// renewCLI hands out an invitation that replaces an approved device's credential.
// It is for the same device and the same nodes, so the node it names is one the
// device already holds.
func (service *Trust) renewCLI(parts []string, output io.Writer) error {
	flags := flag.NewFlagSet("device renew", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	ttlText := flags.String("ttl", "10m", "")
	name := flags.String("name", "", "")
	nodeValue := flags.String("node", "", "")
	qrFile := flags.String("qr", "", "")
	if flags.Parse(parts) != nil || flags.NArg() != 1 || strings.TrimSpace(*name) == "" || *nodeValue == "" {
		return errors.New("invalid device renew arguments")
	}
	ttl, err := time.ParseDuration(*ttlText)
	if err != nil {
		return fmt.Errorf("invalid renewal ttl: %w", err)
	}
	node, err := service.resolveNode(*nodeValue)
	if err != nil {
		return err
	}
	return service.issueRenewalInvitation(ttl, node, *name, *qrFile, flags.Arg(0), output)
}
