package main

import (
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/hxaxd/remote-everything/internal/gatewaycore"
	"github.com/hxaxd/remote-everything/internal/nodecore"
)

const lanUsage = "usage: remote-everything-lan-server init --state ABSOLUTE_PATH --host HOST --name NAME [--valid-days DAYS] [--qr ABSOLUTE_PATH] | certificate renew --state ABSOLUTE_PATH --name NAME [--valid-days DAYS] [--qr ABSOLUTE_PATH] | ports repair --state ABSOLUTE_PATH | serve --state ABSOLUTE_PATH"

func main() {
	if len(os.Args) >= 2 && os.Args[1] == "init" {
		if err := runLANInit(os.Args[2:], os.Stdout); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	if len(os.Args) >= 3 && os.Args[1] == "ports" && os.Args[2] == "repair" {
		flags := flag.NewFlagSet("ports repair", flag.ContinueOnError)
		flags.SetOutput(io.Discard)
		stateRoot := flags.String("state", "", "")
		if flags.Parse(os.Args[3:]) != nil || flags.NArg() != 0 {
			fmt.Fprintln(os.Stderr, lanUsage)
			os.Exit(64)
		}
		result, err := repairLANPorts(*stateRoot)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		_ = json.NewEncoder(os.Stdout).Encode(result)
		return
	}
	if len(os.Args) >= 3 && os.Args[1] == "certificate" && os.Args[2] == "renew" {
		flags := flag.NewFlagSet("certificate renew", flag.ContinueOnError)
		flags.SetOutput(io.Discard)
		stateRoot := flags.String("state", "", "")
		name := flags.String("name", "", "")
		validDays := flags.Int("valid-days", 825, "")
		qrFile := flags.String("qr", "", "")
		if flags.Parse(os.Args[3:]) != nil || flags.NArg() != 0 {
			fmt.Fprintln(os.Stderr, lanUsage)
			os.Exit(64)
		}
		result, err := renewLANCertificate(*stateRoot, *validDays, *name, *qrFile)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		_ = json.NewEncoder(os.Stdout).Encode(result)
		return
	}
	if len(os.Args) < 2 || os.Args[1] != "serve" {
		fmt.Fprintln(os.Stderr, lanUsage)
		os.Exit(64)
	}
	flags := flag.NewFlagSet("serve", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	stateRoot := flags.String("state", "", "")
	if flags.Parse(os.Args[2:]) != nil || flags.NArg() != 0 || !filepath.IsAbs(*stateRoot) {
		fmt.Fprintln(os.Stderr, lanUsage)
		os.Exit(64)
	}
	root := filepath.Clean(*stateRoot)
	lan, err := loadLANState(root)
	if err != nil {
		fmt.Fprintln(os.Stderr, "LAN state unavailable")
		os.Exit(1)
	}
	node, err := nodecore.LoadState(root)
	if err != nil || node.InstallationID != lan.InstallationID {
		fmt.Fprintln(os.Stderr, "node state unavailable")
		os.Exit(1)
	}
	token, err := os.ReadFile(filepath.Join(root, "control-token"))
	if err != nil {
		fmt.Fprintln(os.Stderr, "control token unavailable")
		os.Exit(1)
	}
	handler, err := gatewaycore.New("http://"+node.ListenAddress, string(token))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	serveHandler := lanAccessHandler(lan.AccessToken, handler)
	certificate, err := tls.LoadX509KeyPair(filepath.Join(root, lan.CertificateFile), filepath.Join(root, lan.PrivateKeyFile))
	if err != nil {
		fmt.Fprintln(os.Stderr, "LAN TLS material unavailable")
		os.Exit(1)
	}
	tlsConfig := &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{certificate}}
	server := &http.Server{
		Addr: lan.ListenAddress, Handler: serveHandler, TLSConfig: tlsConfig,
		ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 90 * time.Second,
	}
	if err := server.ListenAndServeTLS("", ""); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
