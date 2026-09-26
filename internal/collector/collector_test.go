package collector

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func fake(t *testing.T, name, body string) {
	t.Helper()
	dir := os.Getenv("FAKE_BIN")
	if err := os.WriteFile(filepath.Join(dir, name), []byte("#!/bin/sh\n"+body+"\n"), 0700); err != nil {
		t.Fatal(err)
	}
}

func setup(t *testing.T) (Options, string) {
	t.Helper()
	dir := t.TempDir()
	bin := filepath.Join(dir, "bin")
	if err := os.Mkdir(bin, 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("FAKE_BIN", bin)
	t.Setenv("PATH", bin+":"+os.Getenv("PATH"))
	store := filepath.Join(dir, "store")
	if err := os.WriteFile(store, nil, 0600); err != nil {
		t.Fatal(err)
	}
	system := filepath.Join(dir, "system")
	if err := os.Symlink(store, system); err != nil {
		t.Fatal(err)
	}
	return Options{Output: filepath.Join(dir, "cache", "snapshot.json"), Database: filepath.Join(dir, "db"), System: system}, store
}

func read(t *testing.T, path string) Snapshot {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var s Snapshot
	if err := json.Unmarshal(b, &s); err != nil {
		t.Fatal(err)
	}
	return s
}

func TestRefreshAndReuseClosure(t *testing.T) {
	o, target := setup(t)
	fake(t, "sqlite3", "printf '3|42|0\\n'")
	fake(t, "nix-store", `case "$*" in
  *--requisites*) printf '/nix/store/aaa\n/nix/store/bbb\n' ;;
  *--size*) printf '10\n20\n' ;;
esac`)
	if err := Refresh(o); err != nil {
		t.Fatal(err)
	}
	s := read(t, o.Output)
	if s.Version != 1 || s.Nix.Registered.Paths != 3 || s.Nix.Registered.Bytes != 42 || s.Nix.Closure.Paths != 2 || s.Nix.Closure.Bytes != 30 || s.Nix.Closure.Target != target || s.Nix.Closure.UpdatedAt == "" {
		t.Fatalf("unexpected snapshot: %+v", s)
	}
	if s.Nix.Registered.CheckedAt == "" || s.Nix.Closure.CheckedAt == "" {
		t.Fatal("missing collection timestamps")
	}
	if info, err := os.Stat(o.Output); err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("snapshot permissions: %v, %v", info, err)
	}
	if info, err := os.Stat(filepath.Dir(o.Output)); err != nil || info.Mode().Perm() != 0700 {
		t.Fatalf("cache permissions: %v, %v", info, err)
	}
	fake(t, "nix-store", "exit 33")
	if err := Refresh(o); err != nil {
		t.Fatal(err)
	}
	if got := read(t, o.Output); got.Nix.Closure.Error != "" || got.Nix.Closure.Bytes != 30 {
		t.Fatalf("closure not reused: %+v", got)
	}
	newTarget := filepath.Join(filepath.Dir(target), "store2")
	if err := os.WriteFile(newTarget, nil, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(o.System); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(newTarget, o.System); err != nil {
		t.Fatal(err)
	}
	if err := Refresh(o); err != nil {
		t.Fatal(err)
	}
	got := read(t, o.Output)
	if got.Nix.Closure.Error == "" || got.Nix.Closure.Bytes != 30 || got.Nix.Closure.Target != target {
		t.Fatalf("last good closure not retained: %+v", got)
	}
}

func TestFallbackAndFailureRetention(t *testing.T) {
	o, _ := setup(t)
	fake(t, "sqlite3", "exit 1")
	fake(t, "nix", "printf '/nix/store/aaa 12\\n/nix/store/bbb with spaces 15\\n'")
	fake(t, "nix-store", "printf '/nix/store/aaa\\n'")
	if err := Refresh(o); err != nil {
		t.Fatal(err)
	}
	s := read(t, o.Output)
	if s.Nix.Registered.Paths != 2 || s.Nix.Registered.Bytes != 27 {
		t.Fatalf("bad fallback: %+v", s)
	}
	fake(t, "nix", "printf '/nix/store/aaa bad\\n'")
	if err := Refresh(o); err != nil {
		t.Fatal(err)
	}
	got := read(t, o.Output)
	if got.Nix.Registered.Bytes != 27 || got.Nix.Registered.UpdatedAt != s.Nix.Registered.UpdatedAt || got.Nix.Registered.Error != "registered paths unavailable" {
		t.Fatalf("last good registered value not retained: %+v", got)
	}
}

func TestMalformedSnapshotIsPreserved(t *testing.T) {
	o, _ := setup(t)
	if err := os.MkdirAll(filepath.Dir(o.Output), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(o.Output, []byte("not json"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := Refresh(o); err == nil {
		t.Fatal("expected incompatible snapshot error")
	}
	b, err := os.ReadFile(o.Output)
	if err != nil {
		t.Fatal(err)
	}
	if string(b) != "not json" {
		t.Fatal("existing file overwritten")
	}
}

func TestLineParserRejectsBadSizes(t *testing.T) {
	for _, line := range []string{"/nix/store/a -1\n", "/nix/store/a 1x\n", "/other/a 1\n", "/nix/store/a 9223372036854775808\n"} {
		var p lineParser
		if _, err := p.Write([]byte(line)); err == nil {
			t.Errorf("accepted %q", strings.TrimSpace(line))
		}
	}
}

func TestSQLiteReadOnlyAggregation(t *testing.T) {
	if _, err := exec.LookPath("sqlite3"); err != nil {
		t.Skip("sqlite3 unavailable")
	}
	db := filepath.Join(t.TempDir(), "db #?.sqlite")
	cmd := exec.Command("sqlite3", db, "CREATE TABLE ValidPaths (narSize INTEGER); INSERT INTO ValidPaths VALUES (10),(22);")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("fixture: %v: %s", err, out)
	}
	paths, size, err := registered(context.Background(), db)
	if err != nil || paths != 2 || size != 32 {
		t.Fatalf("got %d paths %d bytes: %v", paths, size, err)
	}
}

func TestDefaultOutputIgnoresRelativeCacheHome(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", "relative/cache")
	if got := DefaultOutput(); strings.HasPrefix(got, "relative/") || !filepath.IsAbs(got) {
		t.Fatalf("relative cache path: %q", got)
	}
}

func TestRunKillsDescendantsOnTimeout(t *testing.T) {
	start := time.Now()
	err := run(context.Background(), 50*time.Millisecond, "sh", []string{"-c", "sleep 5 & wait"}, os.Stdout)
	if err == nil || time.Since(start) > time.Second {
		t.Fatalf("timeout failed: %v after %s", err, time.Since(start))
	}
}

func TestConcurrentRefreshDoesNotWaitOnLock(t *testing.T) {
	o, _ := setup(t)
	if err := os.MkdirAll(filepath.Dir(o.Output), 0700); err != nil {
		t.Fatal(err)
	}
	f, err := os.OpenFile(o.Output+".lock", os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	defer syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	start := time.Now()
	if err := Refresh(o); err == nil || time.Since(start) > time.Second {
		t.Fatalf("lock wait: %v after %s", err, time.Since(start))
	}
}
