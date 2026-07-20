package main

import (
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"math/big"
	"os"
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

func loadIssuer(paths publicPaths) (*ecdsa.PrivateKey, *x509.Certificate, error) {
	keyPEM, err := os.ReadFile(paths.issuerKeyFile)
	if err != nil {
		return nil, nil, err
	}
	keyBlock, rest := pem.Decode(keyPEM)
	if keyBlock == nil || len(rest) != 0 || keyBlock.Type != "PRIVATE KEY" {
		return nil, nil, errors.New("invalid issuer private key")
	}
	parsedKey, err := x509.ParsePKCS8PrivateKey(keyBlock.Bytes)
	if err != nil {
		return nil, nil, err
	}
	privateKey, ok := parsedKey.(*ecdsa.PrivateKey)
	if !ok || privateKey.Curve == nil {
		return nil, nil, errors.New("invalid issuer private key")
	}
	certPEM, err := os.ReadFile(paths.issuerCertFile)
	if err != nil {
		return nil, nil, err
	}
	certBlock, rest := pem.Decode(certPEM)
	if certBlock == nil || len(rest) != 0 || certBlock.Type != "CERTIFICATE" {
		return nil, nil, errors.New("invalid issuer certificate")
	}
	certificate, err := x509.ParseCertificate(certBlock.Bytes)
	if err != nil {
		return nil, nil, err
	}
	issuerPublicKey, ok := certificate.PublicKey.(*ecdsa.PublicKey)
	now := time.Now()
	if !ok || !certificate.IsCA || !certificate.BasicConstraintsValid || !certificate.MaxPathLenZero || certificate.KeyUsage&x509.KeyUsageCertSign == 0 || !issuerPublicKey.Equal(&privateKey.PublicKey) ||
		certificate.Subject.CommonName != "Remote Everything Device Issuer" || certificate.Subject.String() != certificate.Issuer.String() ||
		now.Before(certificate.NotBefore) || now.After(certificate.NotAfter) || certificate.CheckSignatureFrom(certificate) != nil {
		return nil, nil, errors.New("issuer key and certificate do not match")
	}
	return privateKey, certificate, nil
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
