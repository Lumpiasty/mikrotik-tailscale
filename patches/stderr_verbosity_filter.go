// Copyright (c) mikrotik-tailscale build. Injected at image build time.
// SPDX-License-Identifier: BSD-3-Clause

//go:build ts_omit_logtail

package main

// When logtail is compiled out (ts_omit_logtail), logpolicy is never
// installed (see run() in tailscaled.go: `if buildfeatures.HasLogTail`),
// so log.Printf output goes raw to stderr. Nothing parses the [v1]/[v2]
// verbosity tags Tailscale embeds in log messages, which means every
// verbose line (filter "Accept: TCP", "netcheck: [v1] report",
// "wg: [v2]" handshakes/keepalives) is printed regardless of --verbose.
//
// This restores the equivalent of logtail's StderrLevel=0 behavior:
// drop lines carrying a [v1]+ tag, unless TS_LOG_VERBOSITY is set to
// 1 or higher (runtime escape hatch for debugging — no rebuild needed).

import (
	"bytes"
	"log"
	"os"
)

var verboseLogTags = [][]byte{[]byte("[v1] "), []byte("[v2] "), []byte("[v3] ")}

type stderrVerbosityFilter struct{ w *os.File }

func (f stderrVerbosityFilter) Write(p []byte) (int, error) {
	for _, tag := range verboseLogTags {
		if bytes.Contains(p, tag) {
			// Claim success so the log package doesn't complain;
			// the line is intentionally discarded.
			return len(p), nil
		}
	}
	return f.w.Write(p)
}

func init() {
	if v := os.Getenv("TS_LOG_VERBOSITY"); v != "" && v != "0" {
		return
	}
	log.SetOutput(stderrVerbosityFilter{os.Stderr})
}
