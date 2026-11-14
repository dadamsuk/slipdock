package runner

import (
	"bytes"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// When the agent can't run at all (#2920) the fault is the machine's, not
// the card's: its account has hit a usage limit, or it can't sign in. Every
// job would fail the same way within seconds, so a runner that went on
// claiming would fail the whole queue in minutes. So the daemon reads two
// signs as trouble:
//
//   - the agent's limit message ("You've hit your weekly limit · resets
//     Nov 15, 6pm"): the runners hold off until the reset it states, or
//     limitHold when it states none that can be read;
//   - an agent that exits non-zero within quickExit and before a single
//     tool call (an API error such as a 403 at sign-in): the runners back
//     off, firstBackoff doubling to maxBackoff, until a job runs normally.
//
// The job goes back to the queue (finish status "requeue"), its card left
// alone, and the hold is shared by the daemon's runners that run the same
// agent, since they share its account.
const (
	quickExit    = time.Minute
	limitHold    = time.Hour
	firstBackoff = time.Minute
	maxBackoff   = 30 * time.Minute
	// The furthest a stated reset is believed: a weekly limit, and a day.
	maxHold = 8 * 24 * time.Hour
	// How much of the end of the log the limit message is looked for in.
	limitTail = 2000
)

// trouble is why a job couldn't run on this machine.
type trouble struct {
	kind   string    // "limit" or "quick_exit"
	until  time.Time // the runners hold off until then
	reason string    // a line for the log and the server
}

var (
	limitMessage = regexp.MustCompile(`(?i)(you'?ve hit your [a-z0-9 -]*limit|you'?ve reached your [a-z0-9 -]*limit|usage limit reached|[a-z0-9-]+ limit reached)`)
	resetsAt     = regexp.MustCompile(`(?i)resets\s+(?:at\s+)?(?:on\s+)?(?:([a-z]{3,9})\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(?:at\s+)?)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?(?:\s*\(([A-Za-z_]+(?:/[A-Za-z_+-]+)*)\))?`)
	months       = map[string]time.Month{"jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12}
)

// limitIn reads the agent's limit message in the end of its log: whether it
// is there, the line it is on, and the reset it states (zero when none can
// be read). Times without a zone are the machine's own, as the agent prints
// them.
func limitIn(log []byte, now time.Time) (bool, string, time.Time) {
	if len(log) > limitTail {
		log = log[len(log)-limitTail:]
	}
	loc := limitMessage.FindIndex(log)
	if loc == nil {
		return false, "", time.Time{}
	}
	start := bytes.LastIndexByte(log[:loc[0]], '\n') + 1
	end := len(log)
	if i := bytes.IndexByte(log[loc[0]:], '\n'); i >= 0 {
		end = loc[0] + i
	}
	line := strings.TrimSpace(string(log[start:end]))
	return true, line, resetTime(line, now)
}

// resetTime is the reset a limit line states ("resets Nov 15, 6pm",
// "resets 3:30am (Europe/London)"), the next one after now, or zero.
func resetTime(line string, now time.Time) time.Time {
	m := resetsAt.FindStringSubmatch(line)
	if m == nil {
		return time.Time{}
	}
	where := now.Location()
	if m[6] != "" {
		l, err := time.LoadLocation(m[6])
		if err != nil {
			return time.Time{}
		}
		where = l
	}
	now = now.In(where)
	hour, _ := strconv.Atoi(m[3])
	minute, _ := strconv.Atoi(m[4])
	switch strings.ToLower(m[5]) {
	case "am":
		if hour == 12 {
			hour = 0
		}
	case "pm":
		if hour < 12 {
			hour += 12
		}
	}
	if hour > 23 || minute > 59 {
		return time.Time{}
	}
	var at time.Time
	if m[1] != "" {
		month, ok := months[strings.ToLower(m[1])[:3]]
		day, _ := strconv.Atoi(m[2])
		if !ok || day < 1 || day > 31 {
			return time.Time{}
		}
		at = time.Date(now.Year(), month, day, hour, minute, 0, 0, where)
		if at.Before(now) {
			at = at.AddDate(1, 0, 0)
		}
	} else {
		at = time.Date(now.Year(), now.Month(), now.Day(), hour, minute, 0, 0, where)
		if at.Before(now) {
			at = at.AddDate(0, 0, 1)
		}
	}
	if at.Sub(now) > maxHold {
		return time.Time{}
	}
	return at
}

// toolCalled is whether a Claude Code transcript shows a tool call.
func toolCalled(transcript []byte) bool {
	return bytes.Contains(transcript, []byte(`"type":"tool_use"`))
}

// Holds are the daemon's holds on claiming, one per agent, shared by its
// runners (#2920).
type Holds struct {
	mu    sync.Mutex
	until map[string]time.Time
	// backoff is the next quick exit's wait, per agent.
	backoff map[string]time.Duration
}

// NewHolds makes an empty set of holds.
func NewHolds() *Holds {
	return &Holds{until: map[string]time.Time{}, backoff: map[string]time.Duration{}}
}

// Until is when the agent's hold ends: zero, or a time already past, when
// there is none.
func (h *Holds) Until(agent string) time.Time {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.until[agent]
}

// Limit holds the agent until at (limitHold from now when at is zero), or
// longer when it is held longer already.
func (h *Holds) Limit(agent string, at, now time.Time) time.Time {
	if at.IsZero() {
		at = now.Add(limitHold)
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if at.After(h.until[agent]) {
		h.until[agent] = at
	}
	return h.until[agent]
}

// QuickExit backs the agent off, each one in a row twice as long as the
// last, from firstBackoff to maxBackoff, and answers until when.
func (h *Holds) QuickExit(agent string, now time.Time) time.Time {
	h.mu.Lock()
	defer h.mu.Unlock()
	wait := h.backoff[agent]
	if wait == 0 {
		wait = firstBackoff
	}
	h.backoff[agent] = min(wait*2, maxBackoff)
	if at := now.Add(wait); at.After(h.until[agent]) {
		h.until[agent] = at
	}
	return h.until[agent]
}

// Ran says a job of the agent's ran normally: the backoff starts again.
func (h *Holds) Ran(agent string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.backoff, agent)
}
