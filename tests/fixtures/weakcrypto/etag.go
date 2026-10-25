// Package weakcrypto uses algorithms FIPS 140-3 doesn't allow: MD5 for
// ETags and SHA-1 for a legacy checksum. gosec finds both, and their tests
// fail in FIPS 140-3 only mode. Strong uses SHA-256, which passes.
package weakcrypto

import (
	"crypto/md5"
	"crypto/sha1"
	"crypto/sha256"
	"fmt"
)

// ETag names a response body.
func ETag(body []byte) string {
	return fmt.Sprintf("%x", md5.Sum(body))
}

// Legacy is the checksum an old protocol needs.
func Legacy(body []byte) string {
	return fmt.Sprintf("%x", sha1.Sum(body)) // #nosec G401
}

// Strong is the checksum new code uses.
func Strong(body []byte) string {
	return fmt.Sprintf("%x", sha256.Sum256(body))
}
