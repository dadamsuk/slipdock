package cli

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"

	"github.com/dadamsuk/slipdock/daemon/internal/enrol"
	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

// setupQuestion is what init asks once the machine is enrolled.
const setupQuestion = "Set up this machine with Claude now? It reads the board's machine-setup page, " +
	"installs what's missing and proves it by running the suite. [y/N] "

// setupLater says how to set the machine up after init.
const setupLater = "To set it up with Claude later: `slipdock-runner setup` (`--print` for the prompt alone)."

// cmdSetup sets the machine up with Claude from the server's machine-setup
// prompt (#2579), or with --print only prints the prompt. Claude runs as
// the account jobs run as: the dedicated account init saved in the local
// file (executor user), else the person running this (executor me).
func cmdSetup(args []string, env Env) error {
	fs, home := newFlags("setup", env)
	printOnly := fs.Bool("print", false, "print the setup prompt instead of launching Claude with it")
	if err := parse(fs, args); err != nil {
		return err
	}
	d, err := dir(*home, env)
	if err != nil {
		return err
	}
	st, key, err := machine.Load(d)
	if err != nil {
		return err
	}
	client := enrol.NewClient(st.Server, "slipdock-runner/"+Version)
	if env.HTTP != nil {
		client.HTTP = env.HTTP
	}
	ctx, cancel := env.Context()
	defer cancel()

	if *printOnly {
		prompt, err := fetchSetupPrompt(ctx, client, key)
		if err != nil {
			return err
		}
		fmt.Fprintln(env.Stdout, prompt)
		return nil
	}
	l, err := machine.LoadLocal(d)
	if err != nil {
		return fmt.Errorf("the local file: %w", err)
	}
	account := ""
	if l.User != nil {
		account = l.User.Name
	}
	_, err = launchClaude(ctx, client, key, account, env)
	return err
}

// offerSetup is the end of init: it asks whether to set the machine up
// with Claude now, where it otherwise opens a shell as the account
// (startSetUp). Told yes, it launches Claude as the account jobs run as,
// in place of the shell. Told no, or if Claude can't be launched (no
// prompt from the server, claude missing), it falls back to startSetUp.
// Init has already succeeded: nothing here fails it.
func offerSetup(ctx context.Context, client *enrol.Client, key string, who runAs, root string, env Env) {
	fmt.Fprintf(env.Stdout, "\n%s", setupQuestion)
	answer := strings.ToLower(strings.TrimSpace(readLine(env.Stdin)))
	fmt.Fprintln(env.Stdout)
	if answer == "y" || answer == "yes" {
		launched, err := launchClaude(ctx, client, key, who.account, env)
		if err != nil {
			fmt.Fprintf(env.Stdout, "Not set up with Claude: %v.\n", err)
		}
		if launched {
			fmt.Fprintln(env.Stdout, setupLater)
			return
		}
	}
	startSetUp(who, root, env)
	fmt.Fprintf(env.Stdout, "\n%s\n", setupLater)
}

// launchClaude launches Claude Code with the server's setup prompt, as the
// account jobs run as: account, or the person running this when it is "".
// It says whether claude was started; err is why not, or how it ended.
func launchClaude(ctx context.Context, client *enrol.Client, key, account string, env Env) (bool, error) {
	if account == "" {
		// Only the person's own PATH can be looked at: the account's is
		// its login shell's, seen only once sudo starts it.
		if _, err := env.LookPath("claude"); err != nil {
			return false, errors.New("Claude Code (`claude`) isn't on the PATH: install it first")
		}
	}
	prompt, err := fetchSetupPrompt(ctx, client, key)
	if err != nil {
		return false, err
	}
	if account == "" {
		fmt.Fprintln(env.Stdout, "Starting Claude Code with the server's machine-setup prompt…")
		if err := env.Interactive("claude", prompt); err != nil {
			return true, fmt.Errorf("claude stopped with an error: %w", err)
		}
		return true, nil
	}
	fmt.Fprintf(env.Stdout, "Starting Claude Code as %s with the server's machine-setup prompt…\n", account)
	if err := env.Interactive("sudo", claudeAs(account, prompt)...); err != nil {
		return true, fmt.Errorf("claude as %s stopped with an error: %w. To set it up by hand: `sudo -u %s -i`, then `claude`", account, err, account)
	}
	return true, nil
}

// claudeAs is sudo's arguments to run claude with prompt in a login shell
// as account (so claude is found on the account's own PATH).
//
// The prompt can't be claude's argument as it is: with -i, sudo hands the
// command to the login shell's -c, backslash-escaping every character but
// letters, digits, _, - and $, so a newline becomes a line continuation
// (dropped) and a $NAME is expanded. It goes over as base64 instead, in a
// script with no $ in it, decoded by the shell sudo starts. (Trailing
// newlines are lost, as in any command substitution.)
func claudeAs(account, prompt string) []string {
	b64 := base64.StdEncoding.EncodeToString([]byte(prompt))
	return []string{"-u", account, "-i", "sh", "-c", "exec claude \"`echo " + b64 + " | base64 -d`\""}
}

func fetchSetupPrompt(ctx context.Context, client *enrol.Client, key string) (string, error) {
	prompt, err := client.SetupPrompt(ctx, key)
	switch {
	case enrol.IsNotFound(err):
		return "", fmt.Errorf("the server at %s doesn't offer a setup prompt yet: follow the board's machine-setup page by hand", client.Server)
	case err != nil:
		return "", fmt.Errorf("couldn't fetch the setup prompt: %w", err)
	}
	return prompt, nil
}
