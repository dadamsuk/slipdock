package runner

// Listed is one runner as the machine's config lists it: its typed config,
// and whether a person paused it on the Machines page (#2572). A paused
// runner takes no job; the one it holds finishes.
type Listed struct {
	Runner
	Paused bool `json:"paused"`
}

// Listing is GET /api/machine/config's answer: the machine's runners, at
// the machine's config version.
type Listing struct {
	Version int64    `json:"version"`
	Runners []Listed `json:"runners"`
}
