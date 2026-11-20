package egress

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"syscall"
)

// Main is `slipdock-runner egress forward|connect …`, which the daemon
// names in a job's command line and environment; not for people.
//
//	forward --listen 127.0.0.1:PORT --to SOCKET -- PROG [ARGS...]
//	    inside a container with no network: takes the job's connections to
//	    its proxy's address and carries them to the proxy's unix socket,
//	    mounted in, while PROG runs.
//	connect PROXY HOST PORT
//	    ssh's ProxyCommand: a CONNECT through PROXY, then stdin and stdout.
func Main(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "usage: slipdock-runner egress forward|connect …")
		return 2
	}
	switch args[0] {
	case "connect":
		if len(args) != 4 {
			fmt.Fprintln(stderr, "usage: slipdock-runner egress connect PROXY HOST PORT")
			return 2
		}
		if err := Connect(args[1], args[2], args[3], stdin, stdout); err != nil {
			fmt.Fprintf(stderr, "slipdock-runner egress: %v\n", err)
			return 1
		}
		return 0
	case "forward":
		return forwardMain(args[1:], stderr)
	}
	fmt.Fprintf(stderr, "slipdock-runner egress: unexpected %q\n", args[0])
	return 2
}

// dialProxy is net.Dial, for Connect: a test's stands in.
var dialProxy = net.Dial

// Connect opens a tunnel to host:port through the proxy and copies stdin
// into it and what comes back to stdout.
func Connect(proxy, host, port string, stdin io.Reader, stdout io.Writer) error {
	c, err := dialProxy("tcp", proxy)
	if err != nil {
		return err
	}
	defer c.Close()
	addr := net.JoinHostPort(host, port)
	if _, err := fmt.Fprintf(c, "CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n", addr, addr); err != nil {
		return err
	}
	br := bufio.NewReader(c)
	resp, err := http.ReadResponse(br, &http.Request{Method: http.MethodConnect})
	if err != nil {
		return err
	}
	if resp.StatusCode == http.StatusForbidden {
		return fmt.Errorf("%s: %w", addr, ErrDenied)
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s: the proxy said %s", addr, resp.Status)
	}
	go func() {
		_, _ = io.Copy(c, stdin)
		closeWrite(c)
	}()
	_, err = io.Copy(stdout, br)
	return err
}

func forwardMain(args []string, stderr io.Writer) int {
	var listen, to string
	i := 0
	for ; i < len(args); i++ {
		switch args[i] {
		case "--listen", "--to":
			if i+1 >= len(args) {
				fmt.Fprintf(stderr, "slipdock-runner egress forward: %s needs a value\n", args[i])
				return 2
			}
			if args[i] == "--listen" {
				listen = args[i+1]
			} else {
				to = args[i+1]
			}
			i++
			continue
		case "--":
			i++
		default:
			fmt.Fprintf(stderr, "slipdock-runner egress forward: unexpected %q\n", args[i])
			return 2
		}
		break
	}
	if listen == "" || to == "" || i >= len(args) {
		fmt.Fprintln(stderr, "usage: slipdock-runner egress forward --listen ADDR --to SOCKET -- PROG [ARGS...]")
		return 2
	}
	l, err := net.Listen("tcp", listen)
	if err != nil {
		// The job never runs without its way out: it would fail later,
		// and less clearly.
		fmt.Fprintf(stderr, "slipdock-runner egress forward: the job was not run: %v\n", err)
		return 126
	}
	defer l.Close()
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				u, err := net.Dial("unix", to)
				if err != nil {
					return
				}
				defer u.Close()
				splice(u, c, bufio.NewReader(c))
			}()
		}
	}()
	cmd := exec.Command(args[i], args[i+1:]...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := cmd.Start(); err != nil {
		fmt.Fprintf(stderr, "slipdock-runner egress forward: %v\n", err)
		return 127
	}
	sigs := make(chan os.Signal, 4)
	signal.Notify(sigs, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP, syscall.SIGQUIT)
	go func() {
		for s := range sigs {
			_ = cmd.Process.Signal(s)
		}
	}()
	err = cmd.Wait()
	signal.Stop(sigs)
	return exitStatus(err)
}

func exitStatus(err error) int {
	if err == nil {
		return 0
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		if ws, ok := ee.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
			return 128 + int(ws.Signal())
		}
		return ee.ExitCode()
	}
	return 1
}

// Env is what a job's processes get to use the proxy at addr: the proxy
// variables in both cases, and, when sshProxy isn't "", git's ssh through
// it (sshProxy is the command that runs `egress connect`).
func Env(addr, sshProxy string) []string {
	u := "http://" + addr
	env := []string{"HTTPS_PROXY=" + u, "https_proxy=" + u, "HTTP_PROXY=" + u, "http_proxy=" + u,
		"ALL_PROXY=" + u, "all_proxy=" + u, "NO_PROXY=localhost,127.0.0.1,::1", "no_proxy=localhost,127.0.0.1,::1"}
	if sshProxy != "" {
		env = append(env, "GIT_SSH_COMMAND=ssh -o ProxyCommand="+strconv.Quote(sshProxy+" egress connect "+addr+" %h %p"))
	}
	return env
}
