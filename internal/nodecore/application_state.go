package nodecore

import (
	"net"
	"os"
	"time"

	"github.com/hxaxd/remote-everything/internal/wire"
)

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

func (node *Node) currentApplicationState(app AppDefinition) wire.ApplicationState {
	enabled := node.isEnabled(app.ID)
	running := probeOpen(probeAddress(app))
	return wire.ApplicationState{
		ID:                app.ID,
		Name:              app.Name,
		Description:       app.Description,
		Icon:              app.Icon,
		Accent:            app.Accent,
		LaunchFragment:    app.LaunchFragment,
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
