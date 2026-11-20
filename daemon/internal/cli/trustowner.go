package cli

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"path/filepath"
	"sort"
	"strings"

	"github.com/dadamsuk/slipdock/daemon/internal/intent"
	"github.com/dadamsuk/slipdock/daemon/internal/machine"
	"github.com/dadamsuk/slipdock/daemon/internal/runner"
)

// cmdTrustOwner pins the passkeys of the owners of the boards this
// machine's runners serve into its ceiling (#3533, W-2910): it asks the
// server for each owner's keys, shows each one's fingerprint, and writes
// the ones the person at the machine confirms into ceiling.json's
// owner_keys, with the origin and relying party id they sign for. With
// keys pinned, a job runs at the owner tier only when its card's text is
// signed by one of them. The server never writes the ceiling: the keys
// are fetched here, once, and checked by a person, never at job time.
func cmdTrustOwner(args []string, env Env) error {
	fs, home := newFlags("trust-owner", env)
	yes := fs.Bool("yes", false, "pin without asking (for scripts: compare the fingerprints some other way)")
	if err := parse(fs, args); err != nil {
		return err
	}
	d, err := dir(*home, env)
	if err != nil {
		return err
	}
	return trustOwner(d, *yes, env)
}

// ownerListing is one owner's keys as the server listed them, with the
// runners whose boards they own.
type ownerListing struct {
	runner.OwnerKeys
	runners []string
}

func trustOwner(d string, yes bool, env Env) error {
	st, key, err := machine.Load(d)
	if err != nil {
		return err
	}
	if _, err := machine.LoadCeiling(d); err != nil {
		return ceilingErr(filepath.Join(d, machine.CeilingFile), err)
	}
	ctx, cancel := env.Context()
	defer cancel()
	owners, err := fetchOwnerKeys(ctx, st, key, env)
	if err != nil {
		return err
	}

	fmt.Fprintf(env.Stdout, "The server lists these passkeys of the boards' owners. Compare each fingerprint with the\n"+
		"owner's own list (their account page, or `slipdock passkeys` signed in as them) before you pin it:\n")
	var keys []machine.OwnerKey
	for _, o := range owners {
		fmt.Fprintf(env.Stdout, "\nOwner #%d (runners %s), signing on %s (rp id %s):\n",
			o.OwnerID, strings.Join(o.runners, ", "), o.Origin, o.RPID)
		if len(o.Keys) == 0 {
			fmt.Fprintln(env.Stdout, "  no passkeys: they add one on their account page")
		}
		for _, k := range o.Keys {
			pinned, why := pinnable(o.OwnerKeys, k)
			if why != "" {
				fmt.Fprintf(env.Stdout, "  - %s: left out, %s\n", orUnknown(k.Name), why)
				continue
			}
			fmt.Fprintf(env.Stdout, "  - %s  %s  %s\n", orUnknown(k.Name), pinned.Algorithm, pinned.Fingerprint)
			keys = append(keys, pinned)
		}
	}
	fmt.Fprintln(env.Stdout)

	fetched := map[int64]bool{}
	for _, o := range owners {
		fetched[o.OwnerID] = true
	}
	ceilPath := filepath.Join(d, machine.CeilingFile)
	current, _ := machine.LoadCeiling(d)
	next := mergeOwnerKeys(current.OwnerKeys, keys, fetched)
	added, dropped := diffKeys(current.OwnerKeys, next)
	if len(added) == 0 && len(dropped) == 0 {
		fmt.Fprintf(env.Stdout, "%s already pins exactly these keys: nothing to change.\n", ceilPath)
		return nil
	}
	for _, k := range dropped {
		fmt.Fprintf(env.Stdout, "Unpins %s (%s): the owner no longer has it.\n", orUnknown(k.Name), k.Fingerprint)
	}
	if !yes {
		fmt.Fprintf(env.Stdout, "Pin %d key(s) in %s? Only if every fingerprint matches the owner's. [y/N]: ", len(next), ceilPath)
		answer := strings.ToLower(strings.TrimSpace(readLine(env.Stdin)))
		fmt.Fprintln(env.Stdout)
		if answer != "y" && answer != "yes" {
			fmt.Fprintln(env.Stdout, "Nothing pinned.")
			return nil
		}
	}
	c, err := machine.EditCeiling(d, func(c *machine.Ceiling) error {
		c.OwnerKeys = next
		return nil
	})
	if err != nil {
		return ceilingErr(ceilPath, err)
	}
	fmt.Fprintf(env.Stdout, "Pinned %d owner key(s) in %s. A job the server says is owner tier now runs as owner only when\n"+
		"its card's text is signed with one of them, and as member otherwise. A running daemon picks this up\n"+
		"within a minute: no restart needed.\n", len(c.OwnerKeys), ceilPath)
	if len(c.OwnerKeys) > 0 && len(c.Tiers) == 0 {
		fmt.Fprintln(env.Stdout, "The ceiling sets no tiers, so a job's tier changes nothing yet: add them under \"tiers\" in "+ceilPath+".")
	}
	return nil
}

// fetchOwnerKeys asks the server, for each of the machine's runners, for
// the passkeys of the owner of its board tree: one listing per owner.
func fetchOwnerKeys(ctx context.Context, st machine.State, key string, env Env) ([]*ownerListing, error) {
	hc := env.HTTP
	if hc == nil {
		hc = http.DefaultClient
	}
	client := &runner.Client{Server: st.Server, Key: key, HTTP: hc, UserAgent: "slipdock-runner/" + Version}
	listing, err := client.FetchConfig(ctx, 0, 0)
	if err != nil {
		return nil, fmt.Errorf("can't read this machine's runners: %w", err)
	}
	if listing == nil || len(listing.Runners) == 0 {
		return nil, errNoRunners
	}
	byOwner := map[int64]*ownerListing{}
	var owners []*ownerListing
	for _, r := range listing.Runners {
		k, err := client.FetchOwnerKeys(ctx, r.ID)
		if err != nil {
			return nil, fmt.Errorf("can't read the owner's passkeys for runner %s (#%d): %w", r.Name, r.ID, err)
		}
		o := byOwner[k.OwnerID]
		if o == nil {
			o = &ownerListing{OwnerKeys: k}
			byOwner[k.OwnerID] = o
			owners = append(owners, o)
		}
		o.runners = append(o.runners, fmt.Sprintf("%s (#%d)", r.Name, r.ID))
	}
	sort.Slice(owners, func(i, j int) bool { return owners[i].OwnerID < owners[j].OwnerID })
	return owners, nil
}

var errNoRunners = errors.New("this machine has no runners yet, and the server lists a board owner's passkeys to one of them: " +
	"add a runner on the Machines page, then run `slipdock-runner trust-owner`")

// pinnable is k as the ceiling keeps it, its fingerprint worked out here
// from the key itself; or why it can't be pinned.
func pinnable(o runner.OwnerKeys, k runner.OwnerKey) (machine.OwnerKey, string) {
	der, err := intent.Decode64(k.SPKI)
	if err != nil {
		return machine.OwnerKey{}, "its key isn't base64url"
	}
	_, alg, err := intent.ParseKey(der)
	if err != nil {
		return machine.OwnerKey{}, "the daemon can't check its signatures (" + err.Error() + ")"
	}
	fp := intent.Fingerprint(der)
	if k.Fingerprint != fp {
		return machine.OwnerKey{}, "the server's fingerprint for it isn't its key's"
	}
	pk := machine.OwnerKey{OwnerID: o.OwnerID, Name: k.Name, CredentialID: k.CredentialID, Algorithm: alg,
		SPKI: k.SPKI, Fingerprint: fp, Origin: o.Origin, RPID: o.RPID}
	if err := pk.Check(); err != nil {
		return machine.OwnerKey{}, err.Error()
	}
	return pk, ""
}

// mergeOwnerKeys is the pinned keys after trust-owner: those of owners it
// didn't ask about kept as they were, the fetched owners' replaced by
// their keys now.
func mergeOwnerKeys(old, fresh []machine.OwnerKey, fetched map[int64]bool) []machine.OwnerKey {
	var out []machine.OwnerKey
	seen := map[string]bool{}
	for _, k := range fresh {
		if !seen[k.CredentialID] {
			seen[k.CredentialID] = true
			out = append(out, k)
		}
	}
	for _, k := range old {
		if !fetched[k.OwnerID] && !seen[k.CredentialID] {
			seen[k.CredentialID] = true
			out = append(out, k)
		}
	}
	return out
}

// diffKeys is what next pins that old didn't, and what it drops.
func diffKeys(old, next []machine.OwnerKey) (added, dropped []machine.OwnerKey) {
	has := func(list []machine.OwnerKey, k machine.OwnerKey) bool {
		for _, o := range list {
			if o == k {
				return true
			}
		}
		return false
	}
	for _, k := range next {
		if !has(old, k) {
			added = append(added, k)
		}
	}
	for _, k := range old {
		if !has(next, k) {
			dropped = append(dropped, k)
		}
	}
	return added, dropped
}

// offerTrustOwner is init's optional last step: told yes, it runs
// trust-owner; anything else, or no runners yet, leaves it for later.
// Init has already succeeded: nothing here fails it.
func offerTrustOwner(d string, env Env) {
	fmt.Fprint(env.Stdout, "\nPin the board owners' passkeys now, so cards they sign can run at the owner tier? "+
		"(needs a runner; later: `slipdock-runner trust-owner`) [y/N]: ")
	answer := strings.ToLower(strings.TrimSpace(readLine(env.Stdin)))
	fmt.Fprintln(env.Stdout)
	if answer != "y" && answer != "yes" {
		return
	}
	if err := trustOwner(d, false, env); err != nil {
		fmt.Fprintf(env.Stdout, "Not pinned: %v.\n", err)
	}
}

// ownerKeyChecks are doctor's checks of the pinned owner keys: each is
// still one of an owner's passkeys, and the ceiling has tiers for a
// signature to matter.
func ownerKeyChecks(ctx context.Context, st machine.State, key string, c machine.Ceiling, env Env) []check {
	if len(c.OwnerKeys) == 0 {
		return nil
	}
	var out []check
	if len(c.Tiers) == 0 {
		out = append(out, check{warn, "owner keys", "pinned, but the ceiling sets no tiers, so a signature changes nothing"})
	}
	owners, err := fetchOwnerKeys(ctx, st, key, env)
	if err != nil {
		return append(out, check{warn, "owner keys", "can't check them against the owners' passkeys: " + err.Error()})
	}
	have := map[string]bool{}
	for _, o := range owners {
		for _, k := range o.Keys {
			have[o.Origin+" "+k.CredentialID+" "+k.SPKI] = true
		}
	}
	gone := 0
	for _, k := range c.OwnerKeys {
		if !have[k.Origin+" "+k.CredentialID+" "+k.SPKI] {
			gone++
			out = append(out, check{warn, "owner key " + orUnknown(k.Name),
				k.Fingerprint + " is pinned, but the owner's account no longer has it: run slipdock-runner trust-owner to unpin it"})
		}
	}
	if gone == 0 {
		out = append(out, check{ok, "owner keys", fmt.Sprintf("%d pinned, each still one of the owners' passkeys", len(c.OwnerKeys))})
	}
	return out
}
