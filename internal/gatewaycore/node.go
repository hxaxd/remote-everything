package gatewaycore

import "errors"

// DeliverNode records a node this gateway serves and writes the identity bundle
// the operator carries to that machine. It is the whole of what adding a node is:
// the state's own AddNode records it, this hands that machine what it needs. Both
// happen here because neither is useful without the other: a node recorded with no
// bundle never binds, and a bundle written for a node the gateway does not serve
// reaches nothing.
//
// The token is written before the bundle and is never replaced here, and saving the
// state is the caller's, so a delivery that fails partway leaves this gateway with
// one thing to repeat rather than a node it cannot reach: a token minted for a node
// that was not recorded is reused by the next attempt instead of thrown away.
func DeliverNode(gatewayRoot string, state State, node Node, bootstrapDir string) (State, error) {
	return deliver(gatewayRoot, state, node, bootstrapDir, false)
}

// DeliverRotatedNode is DeliverNode for a node whose control token is being
// replaced: it mints a new one and writes the bundle that carries it over the one
// already there. It replaces rather than refuses, because replacing a token is a
// deliberate act the operator asked for — and it is not complete until that machine
// is told, which is what the delivered bundle is for: until it replaces its binding
// with it, that node answers this gateway with the token it was given before.
func DeliverRotatedNode(gatewayRoot string, state State, node Node, bootstrapDir string) (State, error) {
	return deliver(gatewayRoot, state, node, bootstrapDir, true)
}

func deliver(gatewayRoot string, state State, node Node, bootstrapDir string, rotateToken bool) (State, error) {
	if !validToken.MatchString(node.ID) {
		return State{}, errors.New("invalid node id")
	}
	added, err := state.AddNode(node)
	if err != nil {
		return State{}, err
	}
	identity := Identity{InstallationID: state.InstallationID}
	if rotateToken {
		if identity.ControlToken, err = ReplaceNodeToken(gatewayRoot, node.ID); err != nil {
			return State{}, err
		}
		if err := identity.ReplaceBundle(bootstrapDir); err != nil {
			return State{}, err
		}
		return added, nil
	}
	if identity.ControlToken, err = EnsureNodeToken(gatewayRoot, node.ID); err != nil {
		return State{}, err
	}
	if err := identity.WriteBundle(bootstrapDir); err != nil {
		return State{}, err
	}
	return added, nil
}
