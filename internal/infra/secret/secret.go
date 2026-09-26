// Package secret mints the random values this deployment identifies and
// authenticates itself with: the installation id a node binds a gateway by, the
// control token it authenticates with, the tunnel token, and the serial numbers of
// every certificate it issues.
//
// They are here rather than in each package that needs one because a secret is a
// secret whichever machine mints it: one way to make one is what keeps the
// length, the encoding and the source of randomness from drifting apart.
package secret

import (
	"crypto/rand"
	"encoding/hex"
	"math/big"
)

// Hex returns size random bytes, lowercase hex encoded: the shape every token,
// installation id and node id here has (32 bytes, 64 characters).
func Hex(size int) (string, error) {
	value := make([]byte, size)
	if _, err := rand.Read(value); err != nil {
		return "", err
	}
	return hex.EncodeToString(value), nil
}

// Serial returns a certificate serial number: 20 random bytes with the highest bit
// cleared, so the number is positive and within what a certificate may carry. Every
// certificate this project issues is numbered with one, and a certificate is
// identified by it.
func Serial() (*big.Int, error) {
	value := make([]byte, 20)
	if _, err := rand.Read(value); err != nil {
		return nil, err
	}
	serial := new(big.Int).SetBytes(value)
	serial.Rsh(serial, 1)
	return serial, nil
}
