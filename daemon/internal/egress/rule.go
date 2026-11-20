// Package egress is a job's network allowlist (#3517): a small proxy the
// daemon runs for each job whose trust tier says network "allowlist",
// which lets a connection through only to a host and port on the job's
// list, and the two helpers the job's own processes reach it by (forward,
// inside a container; connect, for git over ssh). The sandbox around the
// job (confined, container) denies every other outbound connection, so
// the proxy is the only way out.
package egress

import (
	"fmt"
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

// Rule lets a job's connections through to one host (or, for *.name, any
// name under it) on one port.
type Rule struct {
	Host string
	Port int
}

func (r Rule) String() string { return r.Host + ":" + strconv.Itoa(r.Port) }

// hostName is a DNS name (or an IPv4 address), lower case, optionally
// *. before it for any name under it.
var hostName = regexp.MustCompile(`^(\*\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`)

// ParseRule reads one of a tier's allow_hosts: host (port 443), host:port,
// *.host or *.host:port. localhost:port (or 127.0.0.1:port) is a port on
// the machine itself the job may reach directly, outside the proxy.
func ParseRule(s string) (Rule, error) {
	host, port := strings.ToLower(strings.TrimSpace(s)), 443
	if h, p, ok := strings.Cut(host, ":"); ok {
		n, err := strconv.Atoi(p)
		if err != nil || n < 1 || n > 65535 || strconv.Itoa(n) != p {
			return Rule{}, fmt.Errorf("%q: the port must be a number from 1 to 65535", s)
		}
		host, port = h, n
	}
	host = strings.TrimSuffix(host, ".")
	if !hostName.MatchString(host) || len(host) > 253 {
		return Rule{}, fmt.Errorf("%q is not a host name (host, host:port, *.host or *.host:port)", s)
	}
	r := Rule{Host: host, Port: port}
	if isLoopbackName(host) && !strings.Contains(s, ":") {
		return Rule{}, fmt.Errorf("%q: name the port on this machine the job may reach (localhost:5432, say)", s)
	}
	return r, nil
}

// Loopback is a port on the machine itself, which the job reaches directly.
func (r Rule) Loopback() bool { return isLoopbackName(r.Host) }

func isLoopbackName(host string) bool {
	return host == "localhost" || host == "127.0.0.1"
}

// Allows says whether the rule lets a connection to host:port through.
// host is as the job named it: case and a trailing dot don't matter.
func (r Rule) Allows(host string, port int) bool {
	if port != r.Port {
		return false
	}
	host = strings.TrimSuffix(strings.ToLower(host), ".")
	if suffix, ok := strings.CutPrefix(r.Host, "*."); ok {
		return strings.HasSuffix(host, "."+suffix) && len(host) > len(suffix)+1
	}
	return host == r.Host
}

// AgentRules are the hosts an agent needs: its model API, and where its
// login is refreshed.
func AgentRules(agent string) []Rule {
	switch agent {
	case "claude":
		return []Rule{{"api.anthropic.com", 443}, {"console.anthropic.com", 443}}
	case "codex":
		return []Rule{{"api.openai.com", 443}, {"auth.openai.com", 443}, {"chatgpt.com", 443}}
	}
	return nil
}

// URLRule is the host and port of an http(s) URL: the Slipdock server's.
func URLRule(raw string) (Rule, bool) {
	u, err := url.Parse(raw)
	if err != nil || u.Hostname() == "" {
		return Rule{}, false
	}
	port := 443
	if u.Scheme == "http" {
		port = 80
	} else if u.Scheme != "https" {
		return Rule{}, false
	}
	if p := u.Port(); p != "" {
		n, err := strconv.Atoi(p)
		if err != nil || n < 1 || n > 65535 {
			return Rule{}, false
		}
		port = n
	}
	return Rule{Host: strings.ToLower(u.Hostname()), Port: port}, true
}

// scpLike is git's [user@]host:path.
var scpLike = regexp.MustCompile(`^(?:[^@/:]+@)?([^/:\[\]]+):`)

// RemoteRule is the host and port a git remote URL reaches: https, http,
// ssh and git URLs and the scp-like user@host:path. A local path is none.
func RemoteRule(raw string) (Rule, bool) {
	raw = strings.TrimSpace(raw)
	if strings.Contains(raw, "://") {
		u, err := url.Parse(raw)
		if err != nil || u.Hostname() == "" {
			return Rule{}, false
		}
		ports := map[string]int{"https": 443, "http": 80, "ssh": 22, "git+ssh": 22, "ssh+git": 22, "git": 9418}
		port, ok := ports[u.Scheme]
		if !ok {
			return Rule{}, false
		}
		if p := u.Port(); p != "" {
			n, err := strconv.Atoi(p)
			if err != nil || n < 1 || n > 65535 {
				return Rule{}, false
			}
			port = n
		}
		return Rule{Host: strings.ToLower(u.Hostname()), Port: port}, true
	}
	if m := scpLike.FindStringSubmatch(raw); m != nil && !strings.Contains(raw, "::") {
		return Rule{Host: strings.ToLower(m[1]), Port: 22}, true
	}
	return Rule{}, false
}
