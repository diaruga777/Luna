// Standalone module for fast local iteration: `go test -tags lunabep_standalone .`
// The build script copies only the *.go files into the libtailscale clone,
// where the same sources compile as extra files of its `package main`.
module lunabep

go 1.25
