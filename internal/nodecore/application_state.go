package nodecore

import (
	"net"
	"os"
	"time"
)

type applicationState struct {
	ID                string `json:"id"`
	Name              string `json:"name"`
	Description       string `json:"description"`
	Icon              string `json:"icon"`
	Accent            string `json:"accent"`
	ComputerConnected bool   `json:"computer_connected"`
	Enabled           bool   `json:"enabled"`
	Running           bool   `json:"running"`
	Code              string `json:"code"`
}

func probeAddress(app AppDefinition) string {
	address, _ := proxyAddress(app.ProxyURL)
	return address
}

func probeOpen(address string) bool {
	connection, err := net.DialTimeout("tcp4", address, 500*time.Millisecond)
	if err != nil {
		return false
	}
	_ = connection.Close()
	return true
}

func (node *Node) isEnabled(id string) bool {
	_, err := os.Stat(node.enabledPath(id))
	return err == nil
}

func (node *Node) currentApplicationState(app AppDefinition) applicationState {
	enabled := node.isEnabled(app.ID)
	running := probeOpen(probeAddress(app))
	return applicationState{
		ID:                app.ID,
		Name:              app.Name,
		Description:       app.Description,
		Icon:              app.Icon,
		Accent:            app.Accent,
		ComputerConnected: true,
		Enabled:           enabled,
		Running:           running,
		Code:              applicationStateCode(enabled, running),
	}
}

func applicationStateCode(enabled, running bool) string {
	if enabled {
		if running {
			return "ready"
		}
		return "starting"
	}
	if running {
		return "stopping"
	}
	return "stopped"
}
