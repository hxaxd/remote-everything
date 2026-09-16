package devicecore

import (
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"math/big"
	"strings"
	"time"
	"unicode/utf8"

	"software.sslmate.com/src/go-pkcs12"
)

func runePrefix(text string, limit int) string {
	for utf8.RuneCountInString(text) > limit {
		_, size := utf8.DecodeLastRuneInString(text)
		text = text[:len(text)-size]
	}
	return text
}

func issueDeviceCertificate(issuerKey *ecdsa.PrivateKey, issuer *x509.Certificate, publicKey *ecdsa.PublicKey, deviceName string, now time.Time) (*x509.Certificate, string, error) {
	serialBytes := make([]byte, 20)
	if _, err := rand.Read(serialBytes); err != nil {
		return nil, "", err
	}
	serial := new(big.Int).SetBytes(serialBytes)
	serial.Rsh(serial, 1)
	template := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: runePrefix(strings.TrimSpace(deviceName), 64)},
		NotBefore:    now.Add(-5 * time.Minute),
		NotAfter:     now.Add(825 * 24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, issuer, publicKey, issuerKey)
	if err != nil {
		return nil, "", err
	}
	certificate, err := x509.ParseCertificate(der)
	if err != nil {
		return nil, "", err
	}
	digest := sha256.Sum256(certificate.Raw)
	return certificate, hex.EncodeToString(digest[:]), nil
}

func encodePKCS12(privateKey *ecdsa.PrivateKey, certificate, issuer *x509.Certificate, password string) (string, error) {
	contents, err := pkcs12.Modern.Encode(privateKey, certificate, []*x509.Certificate{issuer}, password)
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(contents), nil
}
