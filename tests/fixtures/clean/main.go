// Command clean prints the SHA-256 of its arguments. Every check in the orb
// passes on it.
package main

import (
	"crypto/sha256"
	"fmt"
	"os"
	"strings"
)

// Digest returns the hex SHA-256 of s.
func Digest(s string) string {
	return fmt.Sprintf("%x", sha256.Sum256([]byte(s)))
}

func main() {
	fmt.Println(Digest(strings.Join(os.Args[1:], " ")))
}
