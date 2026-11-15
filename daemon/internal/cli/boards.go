package cli

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/dadamsuk/slipdock/daemon/internal/machine"
)

const boardsUsage = "slipdock-runner boards [add|remove <board id>...] [--home DIR]"

// cmdBoards lists, adds or removes the boards in the machine's ceiling
// (#3249): the person at the machine's own say over which boards it
// serves, which the server can't change. The file is edited in place,
// every other field kept, and a running daemon takes the change on its
// next turn of the config loop, without a restart.
func cmdBoards(args []string, env Env) error {
	fs, home := newFlags("boards", env)
	// Flags may come before or after the action and its ids.
	var pos []string
	for rest := args; ; {
		if err := fs.Parse(rest); err != nil {
			if errors.Is(err, flag.ErrHelp) {
				return err
			}
			return errUsage
		}
		if fs.NArg() == 0 {
			break
		}
		pos = append(pos, fs.Arg(0))
		rest = fs.Args()[1:]
	}
	d, err := dir(*home, env)
	if err != nil {
		return err
	}
	path := filepath.Join(d, machine.CeilingFile)
	if len(pos) == 0 {
		c, err := machine.LoadCeiling(d)
		if err != nil {
			return ceilingErr(path, err)
		}
		fmt.Fprintf(env.Stdout, "This machine serves %s (its ceiling: %s).\n"+
			"Change them with `slipdock-runner boards add|remove <board id>...`.\n", boardList(c.Boards), path)
		return nil
	}
	action, rawIDs := pos[0], pos[1:]
	if action != "add" && action != "remove" {
		fmt.Fprintf(env.Stderr, "slipdock-runner boards: unknown action %q (add or remove)\n%s\n", action, boardsUsage)
		return errUsage
	}
	if len(rawIDs) == 0 {
		fmt.Fprintf(env.Stderr, "slipdock-runner boards %s: name at least one board id\n%s\n", action, boardsUsage)
		return errUsage
	}
	ids, err := boardIDs(rawIDs)
	if err != nil {
		fmt.Fprintf(env.Stderr, "slipdock-runner boards %s: %v\n", action, err)
		return errUsage
	}

	var changed, unchanged []int64
	c, err := machine.EditCeiling(d, func(c *machine.Ceiling) error {
		has := map[int64]bool{}
		for _, b := range c.Boards {
			has[b] = true
		}
		for _, id := range ids {
			if has[id] == (action == "add") {
				unchanged = append(unchanged, id)
				continue
			}
			has[id] = action == "add"
			changed = append(changed, id)
		}
		if len(changed) == 0 {
			return errNoChange
		}
		var boards []int64
		for b, in := range has {
			if in {
				boards = append(boards, b)
			}
		}
		if len(boards) == 0 {
			return fmt.Errorf("that would leave the ceiling with no board, and a machine serves at least one: " +
				"to stop this machine serving boards, revoke it on the Machines page instead")
		}
		sort.Slice(boards, func(i, j int) bool { return boards[i] < boards[j] })
		c.Boards = boards
		return nil
	})
	for _, id := range unchanged {
		if action == "add" {
			fmt.Fprintf(env.Stdout, "Board #%d is in the ceiling already: nothing to add.\n", id)
		} else {
			fmt.Fprintf(env.Stdout, "Board #%d isn't in the ceiling: nothing to remove.\n", id)
		}
	}
	switch {
	case errors.Is(err, errNoChange):
		fmt.Fprintf(env.Stdout, "%s is unchanged.\n", path)
		return nil
	case err != nil:
		return ceilingErr(path, err)
	}
	what, to := "Added", "to"
	if action == "remove" {
		what, to = "Removed", "from"
	}
	fmt.Fprintf(env.Stdout, "%s %s %s the ceiling (%s). This machine now serves %s.\n",
		what, someBoards(changed), to, path, boardList(c.Boards))
	if action == "remove" {
		fmt.Fprintln(env.Stdout, "A runner on a removed board takes no more jobs; the job it holds finishes first.")
	}
	fmt.Fprintln(env.Stdout, "A running daemon picks this up within a minute: no restart needed.")
	return nil
}

// someBoards is "board #5", or "boards #5, #6".
func someBoards(ids []int64) string {
	if len(ids) == 1 {
		return fmt.Sprintf("board #%d", ids[0])
	}
	return boardList(ids)
}

var errNoChange = errors.New("no change")

// boardIDs reads board ids: positive whole numbers, a leading # allowed.
func boardIDs(raw []string) ([]int64, error) {
	var ids []int64
	for _, s := range raw {
		id, err := strconv.ParseInt(strings.TrimPrefix(s, "#"), 10, 64)
		if err != nil || id < 1 {
			return nil, fmt.Errorf("%q is not a board id (a positive whole number, as the board's address shows it)", s)
		}
		ids = append(ids, id)
	}
	return ids, nil
}

func ceilingErr(path string, err error) error {
	if errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("there is no ceiling at %s: run slipdock-runner init", path)
	}
	return err
}
