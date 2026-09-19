// Package wire is the protocol the node and the gateway share on one line:
// the types a node answers its catalog and its app actions with, and the
// shape of the application id everything on that line names an application
// by. There is one of each, because the two sides of one line cannot afford
// two answers — a field the node writes and the gateway does not read is a
// catalog the gateway refuses, and an id one side allows and the other
// cannot serve is an application half of the deployment cannot open.
package wire

import "regexp"

// ApplicationState is one application of one node as the protocol carries
// it: what a node says it runs, what a client shows, and where that
// application stands right now.
type ApplicationState struct {
	ID                string `json:"id"`
	Name              string `json:"name"`
	Description       string `json:"description"`
	Icon              string `json:"icon"`
	Accent            string `json:"accent"`
	LaunchFragment    string `json:"launch_fragment"`
	ComputerConnected bool   `json:"computer_connected"`
	Enabled           bool   `json:"enabled"`
	Running           bool   `json:"running"`
	Code              string `json:"code"`
}

// Catalog is what a node answers "what do you run" with.
type Catalog struct {
	OK                bool               `json:"ok"`
	ComputerConnected bool               `json:"computer_connected"`
	Code              string             `json:"code"`
	Apps              []ApplicationState `json:"apps"`
}

// Action is what a node answers a status, a start or a stop with.
type Action struct {
	OK                bool              `json:"ok"`
	Action            string            `json:"action,omitempty"`
	ComputerConnected bool              `json:"computer_connected"`
	Enabled           bool              `json:"enabled"`
	Running           bool              `json:"running"`
	Code              string            `json:"code"`
	App               *ApplicationState `json:"app,omitempty"`
	ErrorCode         string            `json:"error_code,omitempty"`
}

// AppIDPattern is ValidAppID as a regular-expression fragment, for a route
// that matches an application id in a path. It is exported so a route and
// this rule cannot disagree about what passes.
const AppIDPattern = `[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?`

var validAppID = regexp.MustCompile(`^` + AppIDPattern + `$`)

// ValidAppID is the shape of an application id: what a node's catalog
// carries, what an application host names, and what picks out the
// application an origin serves. It is one hostname label, and no more than
// that: a public gateway serves an application at a host built under its own
// domain, the id is that host's first label, and an id that could not be a
// label would name an application no host could carry. It is one rule with
// one home, because a catalog, a host and a route all have to agree about
// which ids exist.
func ValidAppID(value string) bool {
	return validAppID.MatchString(value)
}
