package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type enrollRequestFile struct {
	path string
	item *enrollRequest
}

func loadEnrollRequests() []enrollRequestFile {
	result := []enrollRequestFile{}
	for _, path := range enrollRequestFiles() {
		item, err := readEnrollRequest(path)
		if err != nil {
			continue
		}
		result = append(result, enrollRequestFile{path: path, item: item})
	}
	return result
}

// saveEnrollRequestCLI rewrites a state file as root: 0600, owned by the
// enrollment service user, atomic replace — same as remote-everything-enroll.
func saveEnrollRequestCLI(path string, item *enrollRequest) error {
	contents, err := json.Marshal(item)
	if err != nil {
		return err
	}
	temporary := strings.TrimSuffix(path, ".json") + ".json.tmp"
	if err := os.WriteFile(temporary, contents, 0o600); err != nil {
		return err
	}
	if err := os.Chmod(temporary, 0o600); err != nil {
		return err
	}
	if err := chownFunc(temporary, enrollUser); err != nil {
		return err
	}
	return replaceFile(temporary, path)
}

func rebuildTrust() error {
	temporary := strings.TrimSuffix(trustBundleFile, ".pem") + ".pem.tmp"
	var bundle strings.Builder
	ca, err := os.ReadFile(bootstrapCAFile)
	if err != nil {
		return err
	}
	bundle.Write(ca)
	if len(ca) > 0 && ca[len(ca)-1] != '\n' {
		bundle.WriteByte('\n')
	}
	certificates, _ := filepath.Glob(filepath.Join(approvedDir, "*.pem"))
	for _, path := range certificates {
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		bundle.Write(data)
		if len(data) > 0 && data[len(data)-1] != '\n' {
			bundle.WriteByte('\n')
		}
	}
	if err := os.WriteFile(temporary, []byte(bundle.String()), 0o644); err != nil {
		return err
	}
	if err := os.Chmod(temporary, 0o644); err != nil {
		return err
	}
	if err := replaceFile(temporary, trustBundleFile); err != nil {
		return err
	}
	if err := execFunc("/usr/bin/caddy", "validate", "--config", caddyConfigFile, "--adapter", "caddyfile"); err != nil {
		return err
	}
	return execFunc("/usr/bin/systemctl", "reload", "caddy")
}

func printEnrollRequest(stdout io.Writer, item *enrollRequest) error {
	encoded, err := json.MarshalIndent(item, "", "  ")
	if err != nil {
		return err
	}
	_, _ = io.WriteString(stdout, string(encoded)+"\n")
	return nil
}

func enrollApprove(code string, stdout io.Writer) error {
	matches := []enrollRequestFile{}
	for _, entry := range loadEnrollRequests() {
		if entry.item.RegistrationCode == strings.ToUpper(code) {
			matches = append(matches, entry)
		}
	}
	if len(matches) != 1 {
		return errors.New("registration code not found or ambiguous")
	}
	entry := matches[0]
	item := entry.item
	if item.Status == "approved" {
		return printEnrollRequest(stdout, item)
	}
	if item.Status != "pending" {
		return fmt.Errorf("request is %s", item.Status)
	}
	if isEnrollExpired(item) {
		item.Status = "expired"
		if err := saveEnrollRequestCLI(entry.path, item); err != nil {
			return err
		}
		return errors.New("request expired")
	}

	issuerKey, issuerCert, err := loadIssuer()
	if err != nil {
		return err
	}
	if item.CredentialDelivery != "pkcs12" && item.CredentialDelivery != "" {
		return errors.New("unsupported credential delivery")
	}
	if item.CredentialPassword == "" {
		return errors.New("request is missing credential password")
	}
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}

	now := time.Now().UTC()
	certificate, certificatePEM, certificateFingerprint, err := issueDeviceCertificate(issuerKey, issuerCert, &privateKey.PublicKey, item.DeviceName, item.Fingerprint, now)
	if err != nil {
		return err
	}
	if err := pemCertificate(filepath.Join(approvedDir, certificateFingerprint+".pem"), certificatePEM); err != nil {
		return err
	}
	if err := rebuildTrust(); err != nil {
		return err
	}
	item.Status = "approved"
	item.CertificatePEM = string(certificatePEM)
	item.CertificateFingerprint = certificateFingerprint
	credential, err := encodePKCS12(privateKey, certificate, issuerCert, item.CredentialPassword)
	if err != nil {
		return err
	}
	item.CredentialPKCS12 = credential
	item.CredentialPassword = ""
	item.ApprovedAt = isoUTC(now)
	if err := saveEnrollRequestCLI(entry.path, item); err != nil {
		return err
	}
	if err := printEnrollRequest(stdout, item); err != nil {
		return err
	}
	auditLine("enrollment approved",
		"registration_code", item.RegistrationCode,
		"fingerprint", item.Fingerprint,
		"certificate_fingerprint", certificateFingerprint)
	return nil
}

func enrollRevoke(fingerprint string, stdout io.Writer) error {
	fingerprint = strings.ToLower(fingerprint)
	certificatePath := filepath.Join(approvedDir, fingerprint+".pem")
	matches := []enrollRequestFile{}
	for _, entry := range loadEnrollRequests() {
		if entry.item.Fingerprint == fingerprint || entry.item.CertificateFingerprint == fingerprint {
			matches = append(matches, entry)
		}
	}
	if _, err := os.Stat(certificatePath); err != nil && len(matches) > 0 {
		alternate := matches[0].item.CertificateFingerprint
		if alternate == "" {
			alternate = "None"
		}
		certificatePath = filepath.Join(approvedDir, alternate+".pem")
	}
	if info, err := os.Stat(certificatePath); err != nil || !info.Mode().IsRegular() {
		return errors.New("approved fingerprint not found")
	}
	if err := os.Remove(certificatePath); err != nil {
		return err
	}
	for _, entry := range matches {
		if entry.item.Status == "approved" {
			entry.item.Status = "revoked"
			entry.item.RevokedAt = isoUTC(time.Now())
			if err := saveEnrollRequestCLI(entry.path, entry.item); err != nil {
				return err
			}
		}
	}
	if err := rebuildTrust(); err != nil {
		return err
	}
	_, _ = io.WriteString(stdout, "revoked "+fingerprint+"\n")
	auditLine("enrollment revoked", "fingerprint", fingerprint)
	return nil
}

func enrollList(stdout io.Writer) error {
	items := []map[string]any{}
	for _, entry := range loadEnrollRequests() {
		data, err := json.Marshal(entry.item)
		if err != nil {
			return err
		}
		var value map[string]any
		if err := json.Unmarshal(data, &value); err != nil {
			return err
		}
		delete(value, "certificate_pem")
		delete(value, "public_key_pem")
		delete(value, "credential_pkcs12")
		delete(value, "credential_password")
		items = append(items, value)
	}
	encoded, err := json.MarshalIndent(items, "", "  ")
	if err != nil {
		return err
	}
	_, _ = io.WriteString(stdout, string(encoded)+"\n")
	return nil
}

func runEnrollCLI(args []string, stdout io.Writer) error {
	if euidFunc() != 0 {
		return errors.New("must run as root")
	}
	if err := os.MkdirAll(approvedDir, 0o755); err != nil {
		return err
	}
	switch {
	case len(args) == 1 && args[0] == "list":
		return enrollList(stdout)
	case len(args) == 2 && args[0] == "approve":
		return enrollApprove(args[1], stdout)
	case len(args) == 2 && args[0] == "revoke":
		return enrollRevoke(args[1], stdout)
	case len(args) == 1 && args[0] == "rebuild":
		return rebuildTrust()
	default:
		return errors.New("usage: remote-everything-enroll list | approve CODE | revoke FINGERPRINT | rebuild")
	}
}
