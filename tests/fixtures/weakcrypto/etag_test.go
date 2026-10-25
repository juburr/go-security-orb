package weakcrypto

import "testing"

func TestStrong(t *testing.T) {
	if len(Strong([]byte("x"))) != 64 {
		t.Fatal("Strong is not a SHA-256")
	}
}

func TestLegacy(t *testing.T) {
	if len(Legacy([]byte("x"))) != 40 {
		t.Fatal("Legacy is not a SHA-1")
	}
}

func TestETag(t *testing.T) {
	if len(ETag([]byte("x"))) != 32 {
		t.Fatal("ETag is not an MD5")
	}
}
