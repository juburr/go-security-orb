// Command vulnerable parses a language tag with golang.org/x/text v0.3.5,
// whose language.Parse has GO-2021-0113 (an out-of-bounds read), so
// govulncheck finds the vulnerability called, in source and in the binary.
package main

import (
	"fmt"
	"os"

	"golang.org/x/text/language"
)

func main() {
	tag := "en-US"
	if len(os.Args) > 1 {
		tag = os.Args[1]
	}
	t, err := language.Parse(tag)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println(t)
}
