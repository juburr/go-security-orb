package main

import "testing"

func TestDigest(t *testing.T) {
	const want = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
	if got := Digest("hello"); got != want {
		t.Fatalf("Digest(hello) = %s, want %s", got, want)
	}
}
