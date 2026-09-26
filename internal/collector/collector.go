package collector

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type Measurement struct {
	Paths     int64  `json:"paths"`
	Bytes     int64  `json:"bytes"`
	UpdatedAt string `json:"updatedAt"`
	CheckedAt string `json:"checkedAt"`
	Error     string `json:"error"`
}

type Closure struct {
	Measurement
	Target string `json:"target"`
}

type Snapshot struct {
	Version int `json:"version"`
	Nix     struct {
		Registered Measurement `json:"registered"`
		Closure    Closure     `json:"closure"`
	} `json:"nix"`
}

type Options struct{ Output, Database, System string }

func DefaultOutput() string {
	base := os.Getenv("XDG_CACHE_HOME")
	if !filepath.IsAbs(base) {
		home, err := os.UserHomeDir()
		if err != nil {
			return ""
		}
		base = filepath.Join(home, ".cache")
	}
	return filepath.Join(base, "dankDiskUsage", "snapshot.json")
}

func Refresh(o Options) error {
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	if o.Output == "" {
		return errors.New("no output path")
	}
	if o.Database == "" {
		o.Database = "/nix/var/nix/db/db.sqlite"
	}
	if o.System == "" {
		o.System = "/run/current-system"
	}
	dir := filepath.Dir(o.Output)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	lock, err := os.OpenFile(o.Output+".lock", os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return err
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	s := Snapshot{Version: 1}
	if data, err := readSnapshot(o.Output); err == nil {
		if err := json.Unmarshal(data, &s); err != nil || !validSnapshot(s) {
			return errors.New("existing snapshot is incompatible")
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	now := time.Now().UTC().Format(time.RFC3339)
	paths, size, err := registered(ctx, o.Database)
	if err == nil {
		s.Nix.Registered = Measurement{Paths: paths, Bytes: size, UpdatedAt: now, CheckedAt: now}
	} else {
		s.Nix.Registered.Error = "registered paths unavailable"
		s.Nix.Registered.CheckedAt = now
	}
	target, err := filepath.EvalSymlinks(o.System)
	if err != nil {
		s.Nix.Closure.Error = "system target unavailable"
		s.Nix.Closure.CheckedAt = now
	} else if target != s.Nix.Closure.Target || s.Nix.Closure.UpdatedAt == "" || s.Nix.Closure.Error != "" {
		paths, size, err := closure(ctx, target)
		if err == nil {
			s.Nix.Closure = Closure{Measurement: Measurement{Paths: paths, Bytes: size, UpdatedAt: now, CheckedAt: now}, Target: target}
		} else {
			s.Nix.Closure.Error = "system closure unavailable"
			s.Nix.Closure.CheckedAt = now
		}
	} else {
		s.Nix.Closure.CheckedAt = now
	}
	return writeAtomic(o.Output, s)
}

func validSnapshot(s Snapshot) bool {
	if s.Version != 1 {
		return false
	}
	for _, m := range []Measurement{s.Nix.Registered, s.Nix.Closure.Measurement} {
		if m.Paths < 0 || m.Bytes < 0 {
			return false
		}
		for _, stamp := range []string{m.UpdatedAt, m.CheckedAt} {
			if stamp != "" {
				if _, err := time.Parse(time.RFC3339, stamp); err != nil {
					return false
				}
			}
		}
		if m.UpdatedAt == "" && (m.Paths != 0 || m.Bytes != 0) {
			return false
		}
	}
	return s.Nix.Closure.Target == "" || s.Nix.Closure.UpdatedAt != ""
}

func readSnapshot(path string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, 1024*1024+1))
	if err != nil {
		return nil, err
	}
	if len(data) > 1024*1024 {
		return nil, errors.New("snapshot exceeds size limit")
	}
	return data, nil
}

func writeAtomic(path string, s Snapshot) error {
	data, err := json.Marshal(s)
	if err != nil {
		return err
	}
	data = append(data, '\n')
	f, err := os.CreateTemp(filepath.Dir(path), ".snapshot-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	defer f.Close()
	if err := f.Chmod(0600); err != nil {
		return err
	}
	if _, err := f.Write(data); err != nil {
		return err
	}
	if err := f.Sync(); err != nil {
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(f.Name(), path)
}

// run puts every child in its own process group so a timeout also stops descendants.
func run(parent context.Context, timeout time.Duration, name string, args []string, out io.Writer) error {
	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()
	cmd := exec.Command(name, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Stdout = out
	var stderr boundedBuffer
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		return err
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		return err
	case <-ctx.Done():
		syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		<-done
		return ctx.Err()
	}
}

type boundedBuffer struct{ bytes.Buffer }

func (b *boundedBuffer) Write(p []byte) (int, error) {
	if b.Len()+len(p) > 65536 {
		return 0, errors.New("command output exceeded limit")
	}
	return b.Buffer.Write(p)
}

func registered(ctx context.Context, database string) (int64, int64, error) {
	var out boundedBuffer
	u := url.URL{Scheme: "file", Path: database}
	u.RawQuery = "mode=ro"
	err := run(ctx, 15*time.Second, "sqlite3", []string{"-readonly", "-batch", "-noheader", "-list", "-separator", "|", "-init", "/dev/null", u.String(), "PRAGMA query_only=ON; SELECT count(*), COALESCE(sum(narSize),0), COALESCE(sum(CASE WHEN narSize IS NULL OR typeof(narSize) != 'integer' OR narSize < 0 THEN 1 ELSE 0 END),0) FROM ValidPaths;"}, &out)
	if err == nil {
		parts := strings.Split(strings.TrimSpace(out.String()), "|")
		if len(parts) == 3 && parts[2] == "0" {
			count, e1 := nonnegative(parts[0])
			size, e2 := nonnegative(parts[1])
			if e1 == nil && e2 == nil {
				return count, size, nil
			}
		}
	}
	return registeredFallback(ctx)
}

func registeredFallback(ctx context.Context) (int64, int64, error) {
	var p lineParser
	err := run(ctx, 55*time.Second, "nix", []string{"--extra-experimental-features", "nix-command", "--store", storeURI(), "--offline", "path-info", "--all", "--size"}, &p)
	if err != nil {
		return 0, 0, err
	}
	if err := p.finish(); err != nil {
		return 0, 0, err
	}
	return p.count, p.size, nil
}

type lineParser struct {
	pending     []byte
	count, size int64
	failed      error
}

func (p *lineParser) Write(b []byte) (int, error) {
	if p.failed != nil {
		return 0, p.failed
	}
	for _, c := range b {
		if c == '\n' {
			if err := p.line(); err != nil {
				p.failed = err
				return 0, err
			}
			p.pending = p.pending[:0]
		} else {
			if len(p.pending) >= 8192 {
				p.failed = errors.New("oversized line")
				return 0, p.failed
			}
			p.pending = append(p.pending, c)
		}
	}
	return len(b), nil
}
func (p *lineParser) finish() error {
	if p.failed != nil {
		return p.failed
	}
	if len(p.pending) > 0 {
		return p.line()
	}
	return nil
}
func (p *lineParser) line() error {
	fields := strings.Fields(string(p.pending))
	if len(fields) < 2 || !strings.HasPrefix(fields[0], "/nix/store/") {
		return errors.New("invalid path-info output")
	}
	size, err := nonnegative(fields[len(fields)-1])
	if err != nil {
		return err
	}
	if p.size > math.MaxInt64-size || p.count == math.MaxInt64 {
		return errors.New("size overflow")
	}
	p.count++
	p.size += size
	return nil
}
func nonnegative(s string) (int64, error) {
	v, err := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
	if err != nil || v < 0 {
		return 0, errors.New("invalid nonnegative integer")
	}
	return v, nil
}

func closure(ctx context.Context, target string) (int64, int64, error) {
	var requisites pathParser
	store := storeURI()
	if err := run(ctx, 30*time.Second, "nix-store", []string{"--store", store, "--query", "--requisites", target}, &requisites); err != nil {
		return 0, 0, err
	}
	if err := requisites.finish(); err != nil {
		return 0, 0, err
	}
	if len(requisites.paths) == 0 {
		return 0, 0, errors.New("empty closure")
	}
	var sum int64
	for i := 0; i < len(requisites.paths); i += 128 {
		end := i + 128
		if end > len(requisites.paths) {
			end = len(requisites.paths)
		}
		args := append([]string{"--store", store, "--query", "--size"}, requisites.paths[i:end]...)
		sizes := sizeParser{limit: end - i}
		if err := run(ctx, 30*time.Second, "nix-store", args, &sizes); err != nil {
			return 0, 0, err
		}
		if err := sizes.finish(); err != nil {
			return 0, 0, err
		}
		if len(sizes.values) != end-i {
			return 0, 0, errors.New("closure size count mismatch")
		}
		for _, n := range sizes.values {
			if sum > math.MaxInt64-n {
				return 0, 0, errors.New("size overflow")
			}
			sum += n
		}
	}
	return int64(len(requisites.paths)), sum, nil
}

func storeURI() string {
	info, err := os.Stat("/nix/var/nix/daemon-socket/socket")
	if err == nil && info.Mode()&os.ModeSocket != 0 {
		return "daemon"
	}
	return "local"
}

type pathParser struct {
	pending    []byte
	paths      []string
	failed     error
	totalBytes int
}

func (p *pathParser) Write(b []byte) (int, error) {
	return parseLines(&p.pending, b, &p.failed, func(line string) error {
		if !strings.HasPrefix(line, "/nix/store/") || strings.ContainsAny(line, " \t\r") {
			return errors.New("invalid closure path")
		}
		if len(p.paths) >= 250000 {
			return errors.New("too many closure paths")
		}
		if p.totalBytes+len(line) > 32*1024*1024 {
			return errors.New("closure path output exceeded limit")
		}
		p.paths = append(p.paths, line)
		p.totalBytes += len(line)
		return nil
	})
}
func (p *pathParser) finish() error {
	return finishLine(&p.pending, &p.failed, func(line string) error { _, err := p.Write([]byte("\n")); return err })
}

type sizeParser struct {
	pending []byte
	values  []int64
	failed  error
	limit   int
}

func (p *sizeParser) Write(b []byte) (int, error) {
	return parseLines(&p.pending, b, &p.failed, func(line string) error {
		if len(p.values) >= p.limit {
			return errors.New("too many closure sizes")
		}
		n, err := nonnegative(line)
		if err != nil {
			return err
		}
		p.values = append(p.values, n)
		return nil
	})
}
func (p *sizeParser) finish() error {
	return finishLine(&p.pending, &p.failed, func(line string) error { _, err := p.Write([]byte("\n")); return err })
}

func parseLines(pending *[]byte, b []byte, failed *error, line func(string) error) (int, error) {
	if *failed != nil {
		return 0, *failed
	}
	for _, c := range b {
		if c == '\n' {
			if err := line(string(*pending)); err != nil {
				*failed = err
				return 0, err
			}
			*pending = (*pending)[:0]
		} else {
			if len(*pending) >= 8192 {
				*failed = errors.New("oversized line")
				return 0, *failed
			}
			*pending = append(*pending, c)
		}
	}
	return len(b), nil
}
func finishLine(pending *[]byte, failed *error, line func(string) error) error {
	if *failed != nil {
		return *failed
	}
	if len(*pending) > 0 {
		return line(string(*pending))
	}
	return nil
}
