package cli

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"path/filepath"
	"strings"
	"time"

	"github.com/dadamsuk/slipdock/daemon/internal/enrol"
	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

// cmdInit enrols the machine (W-2544 part 1) and writes its ceiling (part 2).
func cmdInit(args []string, env Env) error {
	fs, home := newFlags("init", env)
	server := fs.String("server", "", "the Slipdock server's address (asked if left out)")
	key := fs.String("key", "", "a one-time enrolment key from the Machines page, instead of a code to approve")
	replace := fs.Bool("replace", false, "enrol again, though this machine is enrolled already")
	noBrowser := fs.Bool("no-browser", false, "don't open the approval page, only print it")
	allowHTTP := fs.Bool("allow-http", false, "allow a plain http:// server (a development server: the machine key travels unencrypted)")
	var roots, agents list
	fs.Var(&roots, "root", "a directory runners may work in (repeat for more; default: your source folder)")
	fs.Var(&agents, "agent", "an agent runners may run (repeat for more; default: claude)")
	maxMode := fs.String("max-mode", "", "the highest permission mode a runner may use (default: acceptEdits)")
	maxTimeout := fs.Int("max-timeout", 0, "the longest a job may run, in minutes (default: 60)")
	asMe := fs.Bool("as-me", false, "run jobs as you, for a laptop that is only yours (asked if neither this nor --user)")
	user := fs.String("user", "", "run jobs as this dedicated account, made if it isn't there (the question's default: "+DefaultAccount+")")
	noSetup := fs.Bool("no-setup", false, "don't offer to set the machine up (Claude, or a shell as the account)")
	if err := parse(fs, args); err != nil {
		return err
	}
	d, err := dir(*home, env)
	if err != nil {
		return err
	}

	if machine.Enrolled(d) && !*replace {
		st, _, _ := machine.Load(d)
		return fmt.Errorf("this machine is already enrolled (%s on %s). Pass --replace to enrol it again; "+
			"the old key keeps working until you revoke it on the Machines page", orUnknown(st.Name), orUnknown(st.Server))
	}

	// The ceiling's flags are checked before enrolling, so a mistake in
	// them doesn't leave a machine enrolled on the server with no ceiling.
	userHome, err := env.UserHome()
	if err != nil {
		return fmt.Errorf("can't find your home directory: %w", err)
	}
	if _, _, err := chooseCeiling(d, []int64{0}, roots, agents, *maxMode, *maxTimeout, userHome, nil, env); err != nil {
		return err
	}

	// Who jobs run as, and the account set up (one sudo), before the
	// enrolment: a refusal here leaves nothing enrolled.
	who, err := chooseRunAs(*asMe, *user, env)
	if err != nil {
		return err
	}
	jobsHome := userHome
	if who.account != "" {
		if who, err = setUpAccount(who, env); err != nil {
			return err
		}
		jobsHome = who.home
	}

	srv, err := serverURL(*server, *allowHTTP, env)
	if err != nil {
		return err
	}

	id, err := machine.LoadOrCreateIdentity(d)
	if err != nil {
		return err
	}
	host, err := env.Hostname()
	if err != nil || host == "" {
		return fmt.Errorf("can't tell this machine's hostname: %v", err)
	}
	about := enrol.About{Hostname: host, OS: env.OSName(), Arch: env.GOARCH, Fingerprint: id.Fingerprint()}
	fmt.Fprintf(env.Stdout, "This machine: %s (%s, %s)\nFingerprint:  %s\n\n", about.Hostname, about.OS, about.Arch, about.Fingerprint)

	client := enrol.NewClient(srv, "slipdock-runner/"+Version)
	if env.HTTP != nil {
		client.HTTP = env.HTTP
	}
	if env.Sleep != nil {
		client.Sleep = env.Sleep
	}

	ctx, cancel := env.Context()
	defer cancel()

	var res enrol.Result
	via := "key"
	if *key != "" {
		res, err = client.WithKey(ctx, strings.TrimSpace(*key), about)
	} else {
		via = "device"
		res, err = deviceFlow(ctx, client, about, *noBrowser, env)
	}
	if err != nil {
		return fmt.Errorf("enrolment failed: %w", err)
	}

	ceiling, kept, err := chooseCeiling(d, res.Machine.Boards, roots, agents, *maxMode, *maxTimeout, jobsHome, who.executors(env.GOOS), env)
	if err != nil {
		return err
	}

	st := machine.State{
		Server:      srv,
		MachineID:   res.Machine.ID,
		Name:        res.Machine.Name,
		Boards:      res.Machine.Boards,
		EnrolledVia: via,
		EnrolledAt:  time.Now().UTC().Truncate(time.Second),
	}
	if err := machine.Save(d, st, res.Key); err != nil {
		return fmt.Errorf("enrolled, but couldn't save the machine key: %w", err)
	}
	if !kept {
		if err := machine.SaveCeiling(d, ceiling); err != nil {
			return err
		}
	}
	if err := saveRunAs(d, who); err != nil {
		return fmt.Errorf("enrolled, but couldn't write who jobs run as into %s: %w", machine.LocalFile, err)
	}

	fmt.Fprintf(env.Stdout, "Enrolled as %s (machine #%d). Its key is in %s, readable only by you.\n\n",
		st.Name, st.MachineID, filepath.Join(d, machine.KeyFile))
	how := "Proposed"
	if kept {
		how = "Kept"
	}
	fmt.Fprintf(env.Stdout, "%s ceiling, in %s (only someone at this machine changes it; the server never sees the file):\n", how, filepath.Join(d, machine.CeilingFile))
	printCeiling(env, ceiling)
	if !*noSetup {
		offerSetup(ctx, client, res.Key, who, ceiling.Roots[0], env)
	}
	fmt.Fprintf(env.Stdout, "\nNext: add its runners on the Machines page, then `slipdock-runner service install`.\n"+
		"`slipdock-runner show` says what the server can and cannot make this machine do.\n")
	return nil
}

func orUnknown(s string) string {
	if s == "" {
		return "unknown"
	}
	return s
}

// serverURL is --server, or what the person types (DefaultServer if
// nothing). Plain http carries the machine key unencrypted, so it is
// refused unless --allow-http says so, even to this machine (#2797).
func serverURL(flagValue string, allowHTTP bool, env Env) (string, error) {
	s := strings.TrimSpace(flagValue)
	if s == "" {
		fmt.Fprintf(env.Stdout, "Slipdock server [%s]: ", DefaultServer)
		s = strings.TrimSpace(readLine(env.Stdin))
		if s == "" {
			s = DefaultServer
		}
	}
	u, err := url.Parse(s)
	if err != nil || u.Host == "" || (u.Scheme != "https" && u.Scheme != "http") {
		return "", fmt.Errorf("%q is not a server address: give one like %s", s, DefaultServer)
	}
	if u.Scheme == "http" {
		if !allowHTTP {
			return "", fmt.Errorf("%s is plain http: the machine key would travel unencrypted. "+
				"Use https, or pass --allow-http for a development server", s)
		}
		fmt.Fprintf(env.Stderr, "warning: %s is plain http (--allow-http): the machine key travels unencrypted\n", s)
	}
	return strings.TrimRight(u.Scheme+"://"+u.Host+u.Path, "/"), nil
}

func deviceFlow(ctx context.Context, c *enrol.Client, about enrol.About, noBrowser bool, env Env) (enrol.Result, error) {
	start, err := c.StartDevice(ctx, about)
	if err != nil {
		return enrol.Result{}, err
	}
	open := start.VerificationURIComplete
	if open == "" {
		open = start.VerificationURI
	}
	fmt.Fprintf(env.Stdout, "To approve this machine, open\n\n  %s\n\nand enter the code  %s\n\n"+
		"Check the page shows the fingerprint above before you approve it.\n", start.VerificationURI, start.UserCode)
	if !noBrowser && env.OpenBrowser != nil {
		if err := env.OpenBrowser(open); err == nil {
			fmt.Fprintln(env.Stdout, "(Opened it in your browser.)")
		}
	}
	fmt.Fprintln(env.Stdout, "Waiting for approval…")
	if start.ExpiresIn > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, time.Duration(start.ExpiresIn)*time.Second)
		defer cancel()
	}
	res, err := c.Poll(ctx, start)
	if errors.Is(err, context.DeadlineExceeded) {
		return res, errors.New("the code expired before anyone approved it: run init again")
	}
	return res, err
}

// chooseCeiling keeps a ceiling already on disk (a person's own, on
// --replace) unless a flag changes it; otherwise it proposes one, its
// working directories in jobsHome (the home of the account jobs run as).
// The executors are who init's choice says jobs run as.
func chooseCeiling(d string, boards []int64, roots, agents list, maxMode string, maxTimeout int, jobsHome string, executors []string, env Env) (machine.Ceiling, bool, error) {
	flags := len(roots) > 0 || len(agents) > 0 || maxMode != "" || maxTimeout != 0
	if existing, err := machine.LoadCeiling(d); err == nil && !flags {
		if executors == nil || equal(existing.Executors, executors) {
			return existing, true, nil
		}
		existing.Executors = executors
		return existing, false, nil
	}
	c := machine.ProposeCeiling(jobsHome, boards)
	if executors != nil {
		c.Executors = executors
	}
	if len(roots) > 0 {
		c.Roots = nil
		for _, r := range roots {
			abs, err := filepath.Abs(r)
			if err != nil {
				return c, false, err
			}
			c.Roots = append(c.Roots, abs)
		}
	}
	if len(agents) > 0 {
		c.Agents = append([]string(nil), agents...)
	}
	if maxMode != "" {
		c.MaxPermissionMode = maxMode
	}
	if maxTimeout != 0 {
		c.MaxTimeoutMinutes = maxTimeout
	}
	if err := c.Validate(); err != nil {
		return c, false, fmt.Errorf("that ceiling isn't valid: %w", err)
	}
	return c, false, nil
}

func printCeiling(env Env, c machine.Ceiling) {
	boards := make([]string, len(c.Boards))
	for i, b := range c.Boards {
		boards[i] = fmt.Sprintf("#%d", b)
	}
	fmt.Fprintf(env.Stdout, "  working directories inside: %s\n  agents:                     %s\n"+
		"  highest permission mode:    %s\n  longest job:                %d minutes\n  boards:                     %s\n"+
		"  executors:                  %s\n",
		strings.Join(c.Roots, ", "), strings.Join(c.Agents, ", "), c.MaxPermissionMode, c.MaxTimeoutMinutes, strings.Join(boards, ", "),
		strings.Join(c.Executors, ", "))
}

func equal(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
