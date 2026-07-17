package main

import (
	"fmt"
	"os"
)

type errorResponse struct {
	OK   bool   `json:"ok"`
	Code string `json:"code"`
}

func errorBody(code string) errorResponse {
	return errorResponse{OK: false, Code: code}
}

func main() {
	args := os.Args[1:]
	if len(args) == 1 {
		switch args[0] {
		case "enrollment-server":
			serveEnrollment()
			return
		case "status-server":
			serveStatus()
			return
		}
	}
	if len(args) >= 1 && args[0] == "enroll" {
		if err := runEnrollCLI(args[1:], os.Stdout); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	fmt.Fprintln(os.Stderr, "usage: gateway enrollment-server | status-server | enroll (list | approve CODE | revoke FINGERPRINT | rebuild)")
	os.Exit(64)
}
