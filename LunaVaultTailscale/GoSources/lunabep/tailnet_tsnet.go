//go:build !lunabep_standalone

package main

import "C"

import (
	"context"
	"errors"
	"net"
)

// tailnetServer is the part of *tsnet.Server the BEP layer uses.
type tailnetServer interface {
	Dial(ctx context.Context, network, address string) (net.Conn, error)
	Listen(network, address string) (net.Listener, error)
}

// lookupTailnetServer resolves a libtailscale handle (the `tailscale`
// integer tailscale_new returned) to its tsnet server through the registry
// tailscale.go keeps.
func lookupTailnetServer(handle int) (tailnetServer, error) {
	s := getServer(C.int(handle))
	if s == nil || s.s == nil {
		return nil, errors.New("tailnet: unknown handle")
	}
	return s.s, nil
}
