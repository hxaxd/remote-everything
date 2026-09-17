package secret

import (
	"encoding/hex"
	"regexp"
	"testing"
)

var hex64 = regexp.MustCompile(`^[a-f0-9]{64}$`)

func TestHexIsTheShapeEverySecretHereHas(t *testing.T) {
	value, err := Hex(32)
	if err != nil {
		t.Fatal(err)
	}
	if !hex64.MatchString(value) {
		t.Fatalf("a 32-byte secret is %q", value)
	}
	if _, err := hex.DecodeString(value); err != nil {
		t.Fatalf("a secret is not hex: %v", err)
	}
	other, err := Hex(32)
	if err != nil {
		t.Fatal(err)
	}
	if other == value {
		t.Fatal("two secrets minted the same value")
	}
	// The size asked for is the size handed out, whatever it is.
	for _, size := range []int{1, 16, 64} {
		short, err := Hex(size)
		if err != nil {
			t.Fatal(err)
		}
		if len(short) != size*2 {
			t.Fatalf("Hex(%d) is %q", size, short)
		}
	}
}

func TestSerialIsPositiveAndFresh(t *testing.T) {
	first, err := Serial()
	if err != nil {
		t.Fatal(err)
	}
	if first.Sign() <= 0 {
		t.Fatalf("a certificate serial is %v", first)
	}
	// Twenty bytes with the top bit cleared: nine bytes would mean the leading
	// bytes were dropped, which is how a serial gets reused.
	if first.BitLen() > 159 {
		t.Fatalf("a serial of %d bits is more than a serial", first.BitLen())
	}
	second, err := Serial()
	if err != nil {
		t.Fatal(err)
	}
	if second.Cmp(first) == 0 {
		t.Fatal("two certificates were numbered alike")
	}
}
