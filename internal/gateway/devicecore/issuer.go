package devicecore

import (
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"strings"
	"time"
	"unicode/utf8"

	"software.sslmate.com/src/go-pkcs12"

	"github.com/hxaxd/remote-everything/internal/infra/secret"
)

func runePrefix(text string, limit int) string {
	for utf8.RuneCountInString(text) > limit {
		_, size := utf8.DecodeLastRuneInString(text)
		text = text[:len(text)-size]
	}
	return text
}

// CertificateFingerprint is the shape every fingerprint on the wire has: the
// SHA-256 of a certificate's DER encoding, lowercase hex. A device record is
// keyed by it, and so is the certificate a gateway serves its clients with.
func CertificateFingerprint(certificate *x509.Certificate) string {
	digest := sha256.Sum256(certificate.Raw)
	return hex.EncodeToString(digest[:])
}

// PublicKeyPin is the second form a client pins a gateway's certificate in: the
// base64 SHA-256 of its SubjectPublicKeyInfo, which survives a renewal that
// keeps the key and is what a platform pinning by public key needs.
func PublicKeyPin(certificate *x509.Certificate) string {
	digest := sha256.Sum256(certificate.RawSubjectPublicKeyInfo)
	return base64.StdEncoding.EncodeToString(digest[:])
}

func issueDeviceCertificate(issuerKey *ecdsa.PrivateKey, issuer *x509.Certificate, publicKey *ecdsa.PublicKey, deviceName string, now time.Time) (*x509.Certificate, string, error) {
	serial, err := secret.Serial()
	if err != nil {
		return nil, "", err
	}
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
	return certificate, CertificateFingerprint(certificate), nil
}

func encodePKCS12(privateKey *ecdsa.PrivateKey, certificate, issuer *x509.Certificate, password string) (string, error) {
	// The Legacy encoder (PBES1/3DES, HMAC-SHA-1) is what every platform's
	// PKCS#12 reader accepts. Modern2023 (PBES2/AES-256) is refused by Apple's
	// SecPKCS12Import with errSecAuthFailed even with the right password, so a
	// credential in that encoding cannot ever be imported on iOS. The password
	// is a fresh 256-bit random value per attempt, which is the strong half of
	// the container regardless of the PBE scheme.
	contents, err := pkcs12.Legacy.Encode(privateKey, certificate, []*x509.Certificate{issuer}, password)
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(contents), nil
}
