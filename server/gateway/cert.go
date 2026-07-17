package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"math/big"
	"os"
	"time"

	pkcs12 "software.sslmate.com/src/go-pkcs12"
)

var errUnsupportedKey = errors.New("unsupported key")

// parseDevicePublicKey accepts only ECDSA P-256, like the Python services.
func parseDevicePublicKey(der []byte) (*ecdsa.PublicKey, error) {
	parsed, err := x509.ParsePKIXPublicKey(der)
	if err != nil {
		return nil, err
	}
	publicKey, ok := parsed.(*ecdsa.PublicKey)
	if !ok || publicKey.Curve != elliptic.P256() {
		return nil, errUnsupportedKey
	}
	return publicKey, nil
}

func derAppend(dst []byte, tag byte, content []byte) []byte {
	dst = append(dst, tag)
	switch length := len(content); {
	case length < 128:
		dst = append(dst, byte(length))
	case length < 256:
		dst = append(dst, 0x81, byte(length))
	default:
		dst = append(dst, 0x82, byte(length>>8), byte(length))
	}
	return append(dst, content...)
}

// derName renders SEQUENCE { SET { CN UTF8String }, SET { OU UTF8String } },
// byte-identical to cryptography.x509.Name([CN, OU]) DER.
func derName(commonName, organizationalUnit string) []byte {
	attribute := func(oid []byte, value string) []byte {
		body := derAppend(nil, 0x06, oid)
		body = derAppend(body, 0x0c, []byte(value))
		return derAppend(nil, 0x30, body)
	}
	rdn := func(oid []byte, value string) []byte {
		return derAppend(nil, 0x31, attribute(oid, value))
	}
	body := rdn([]byte{0x55, 0x04, 0x03}, commonName)
	body = append(body, rdn([]byte{0x55, 0x04, 0x0b}, organizationalUnit)...)
	return derAppend(nil, 0x30, body)
}

func runePrefix(text string, limit int) string {
	runes := []rune(text)
	if len(runes) > limit {
		runes = runes[:limit]
	}
	return string(runes)
}

// ecKeyIdentifier matches cryptography's _key_identifier_from_public_key for
// EC keys: SHA-1 over the X9.62 uncompressed point (RFC 5280 method 1).
func ecKeyIdentifier(publicKey *ecdsa.PublicKey) []byte {
	digest := sha1.Sum(elliptic.Marshal(elliptic.P256(), publicKey.X, publicKey.Y))
	return digest[:]
}

func loadIssuer() (*ecdsa.PrivateKey, *x509.Certificate, error) {
	keyPEM, err := os.ReadFile(issuerKeyFile)
	if err != nil {
		return nil, nil, err
	}
	keyBlock, _ := pem.Decode(keyPEM)
	if keyBlock == nil {
		return nil, nil, errors.New("device issuer key is not PEM")
	}
	var issuerKey *ecdsa.PrivateKey
	if parsed, err := x509.ParsePKCS8PrivateKey(keyBlock.Bytes); err == nil {
		issuerKey, _ = parsed.(*ecdsa.PrivateKey)
	}
	if issuerKey == nil {
		if parsed, err := x509.ParseECPrivateKey(keyBlock.Bytes); err == nil {
			issuerKey = parsed
		}
	}
	if issuerKey == nil || issuerKey.Curve != elliptic.P256() {
		return nil, nil, errors.New("device issuer key is not an ECDSA P-256 key")
	}
	certPEM, err := os.ReadFile(issuerCertFile)
	if err != nil {
		return nil, nil, err
	}
	certBlock, _ := pem.Decode(certPEM)
	if certBlock == nil {
		return nil, nil, errors.New("device issuer certificate is not PEM")
	}
	issuerCert, err := x509.ParseCertificate(certBlock.Bytes)
	if err != nil {
		return nil, nil, err
	}
	return issuerKey, issuerCert, nil
}

// issueDeviceCertificate reproduces the certificate fields of kimi-enroll.
func issueDeviceCertificate(issuerKey *ecdsa.PrivateKey, issuerCert *x509.Certificate, publicKey *ecdsa.PublicKey, deviceName, keyFingerprint string, now time.Time) (*x509.Certificate, []byte, string, error) {
	serialBytes := make([]byte, 20)
	if _, err := rand.Read(serialBytes); err != nil {
		return nil, nil, "", err
	}
	serial := new(big.Int).SetBytes(serialBytes)
	serial.Rsh(serial, 1)
	template := &x509.Certificate{
		SerialNumber:          serial,
		RawSubject:            derName(runePrefix(deviceName, 64), runePrefix(keyFingerprint, 16)),
		NotBefore:             now.Add(-5 * time.Minute),
		NotAfter:              now.Add(1825 * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
		BasicConstraintsValid: true,
		SubjectKeyId:          ecKeyIdentifier(publicKey),
		AuthorityKeyId:        ecKeyIdentifier(&issuerKey.PublicKey),
		SignatureAlgorithm:    x509.ECDSAWithSHA256,
	}
	// Force our AuthorityKeyId even when the issuer carries its own SKI.
	parent := *issuerCert
	parent.SubjectKeyId = nil
	der, err := x509.CreateCertificate(rand.Reader, template, &parent, publicKey, issuerKey)
	if err != nil {
		return nil, nil, "", err
	}
	certificate, err := x509.ParseCertificate(der)
	if err != nil {
		return nil, nil, "", err
	}
	encoded := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	fingerprint := sha256.Sum256(der)
	return certificate, encoded, hex.EncodeToString(fingerprint[:]), nil
}

func pemCertificate(path string, contents []byte) error {
	if err := os.WriteFile(path, contents, 0o644); err != nil {
		return err
	}
	return os.Chmod(path, 0o644)
}

// encodePKCS12 mirrors BestAvailableEncryption: PBES2/AES-256-CBC via the
// go-pkcs12 Modern encoder, decodable by Python cryptography and OpenSSL 3.
func encodePKCS12(privateKey *ecdsa.PrivateKey, certificate *x509.Certificate, issuer *x509.Certificate, password string) (string, error) {
	encoded, err := pkcs12.Modern.Encode(privateKey, certificate, []*x509.Certificate{issuer}, password)
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(encoded), nil
}
