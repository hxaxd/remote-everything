package tunnelbootstrap

import (
	"crypto/x509"
	"os"
	"strings"
	"testing"
)

func TestServerIdentityAndAgentTrustSurviveLeafRenewal(t *testing.T) {
	material, err := EnsureGatewayMaterial(t.TempDir(), strings.Repeat("a", 64))
	if err != nil {
		t.Fatal(err)
	}
	server, err := EnsureServerMaterial(material)
	if err != nil {
		t.Fatal(err)
	}
	bundle := t.TempDir()
	agent, err := EnsureTunnelMaterial(bundle, material)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AddCert(readCertificate(t, agent.CACertFile))
	check := func(path string) {
		t.Helper()
		certificate := readCertificate(t, path)
		if _, err := certificate.Verify(x509.VerifyOptions{Roots: roots, DNSName: TunnelServerName, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}); err != nil {
			t.Fatal(err)
		}
		if _, err := certificate.Verify(x509.VerifyOptions{Roots: roots, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}}); err == nil {
			t.Fatal("server leaf is also a client identity")
		}
	}
	check(server.CertificateFile)
	again, err := EnsureServerMaterial(material)
	if err != nil || again.Fingerprint != server.Fingerprint {
		t.Fatalf("ensure replaced server identity: %+v %v", again, err)
	}
	renewed, err := RenewServerMaterial(material)
	if err != nil || renewed.Fingerprint == server.Fingerprint {
		t.Fatalf("renew did not replace server identity: %+v %v", renewed, err)
	}
	check(renewed.CertificateFile)
	if got, err := EnsureTunnelMaterial(bundle, material); err != nil || got.Fingerprint != agent.Fingerprint {
		t.Fatalf("server renewal changed agent identity: %+v %v", got, err)
	}
}

func TestServerIdentityRejectsWrongKeyAndAuthority(t *testing.T) {
	material, err := EnsureGatewayMaterial(t.TempDir(), strings.Repeat("b", 64))
	if err != nil {
		t.Fatal(err)
	}
	server, err := EnsureServerMaterial(material)
	if err != nil {
		t.Fatal(err)
	}
	wrong, err := EnsureGatewayMaterial(t.TempDir(), strings.Repeat("c", 64))
	if err != nil {
		t.Fatal(err)
	}
	key, err := os.ReadFile(wrong.CAKeyFile)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(server.KeyFile, key, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := EnsureServerMaterial(material); err == nil {
		t.Fatal("server accepted a mismatched key")
	}
	if _, err := RenewServerMaterial(material); err != nil {
		t.Fatal(err)
	}
	material.CACertificate, material.CAKey = wrong.CACertificate, wrong.CAKey
	if _, err := EnsureServerMaterial(material); err == nil {
		t.Fatal("server accepted the wrong authority")
	}
}
