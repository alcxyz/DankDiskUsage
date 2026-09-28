package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/alcxyz/DankDiskUsage/internal/collector"
)

var version = "dev"
var revision = "unknown"

func main() {
	if len(os.Args) > 1 && os.Args[1] == "version" {
		fmt.Println(version)
		return
	}
	output := flag.String("output", collector.DefaultOutput(), "snapshot JSON path")
	database := flag.String("database", "/nix/var/nix/db/db.sqlite", "Nix store database")
	system := flag.String("system", "/run/current-system", "current system symlink")
	flag.Parse()
	if flag.NArg() != 0 {
		fmt.Fprintln(os.Stderr, "unexpected arguments")
		os.Exit(2)
	}
	if err := collector.Refresh(collector.Options{Output: *output, Database: *database, System: *system, Version: version, Diagnostics: os.Stderr}); err != nil {
		fmt.Fprintln(os.Stderr, "collector failed; snapshot not updated")
		os.Exit(1)
	}
}
