package main

import "github.com/hxaxd/remote-everything/internal/tunnelbootstrap"

type lanTunnelServerResult struct {
	OK              bool   `json:"ok"`
	InstallationID  string `json:"installation_id"`
	CertificateFile string `json:"tunnel_server_certificate_file"`
	KeyFile         string `json:"tunnel_server_key_file"`
	CAFile          string `json:"tunnel_ca_file"`
	ServerName      string `json:"tunnel_server_name"`
	RestartRequired bool   `json:"restart_required"`
}

// renewLANTunnelServer replaces the FRPS identity without changing the LAN
// entrance certificate, the tunnel authority or any device's pairing.
func renewLANTunnelServer(root string) (lanTunnelServerResult, error) {
	nodes, err := openLANNodes(root)
	if err != nil {
		return lanTunnelServerResult{}, err
	}
	material, err := nodes.TunnelMaterial()
	if err != nil {
		return lanTunnelServerResult{}, err
	}
	server, err := tunnelbootstrap.RenewServerMaterial(material)
	if err != nil {
		return lanTunnelServerResult{}, err
	}
	return lanTunnelServerResult{OK: true, InstallationID: material.InstallationID,
		CertificateFile: server.CertificateFile, KeyFile: server.KeyFile, CAFile: material.CACertFile,
		ServerName: tunnelbootstrap.TunnelServerName, RestartRequired: true}, nil
}
