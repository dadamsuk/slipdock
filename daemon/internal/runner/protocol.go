package runner

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// Client speaks the runner protocol (SlipdockWeb.API.RunnerController) as
// one of a machine's runners: the machine key, and the runner's id in
// X-Runner-Id. Plain text, as the shell runner sends it.
type Client struct {
	Server    string
	Key       string
	HTTP      *http.Client
	UserAgent string
}

// Job is a claimed job: what the server sent, every field data.
type Job struct {
	ID           int64
	Kind         string
	CardID       int64
	CardURL      string
	BoardID      int64
	LeaseSeconds int
	Profile      string
	MergePR      string
	MergeCommit  string
	Prompt       string
}

// Claim is what the claim's answer said besides a job.
type Claim struct {
	// RetryAfter is set when a server going down for a deploy asks the
	// runner to wait before claiming again.
	RetryAfter time.Duration
	// Held is why work is held, when it is.
	Held string
}

// Refused is the server refusing the runner: the machine key (401), this
// runner (403, it isn't the machine's any more) or the request (400).
type Refused struct {
	Status int
	Text   string
}

func (e *Refused) Error() string {
	return fmt.Sprintf("the server refused the runner (HTTP %d): %s", e.Status, e.Text)
}

// IsRevoked says whether err is the server refusing the machine key.
func IsRevoked(err error) bool {
	var r *Refused
	return errors.As(err, &r) && r.Status == http.StatusUnauthorized
}

// ErrLost is a job no longer this runner's: its lease ran out and the
// server has given it to another.
var ErrLost = errors.New("the job is no longer this runner's")

func (c *Client) request(ctx context.Context, runnerID int64, method, path string, body []byte, headers http.Header) (*http.Response, []byte, error) {
	req, err := http.NewRequestWithContext(ctx, method, c.Server+path, bytes.NewReader(body))
	if err != nil {
		return nil, nil, err
	}
	for k, vs := range headers {
		for _, v := range vs {
			req.Header.Add(k, v)
		}
	}
	req.Header.Set("Authorization", "Bearer "+c.Key)
	if runnerID != 0 {
		req.Header.Set("X-Runner-Id", strconv.FormatInt(runnerID, 10))
	}
	req.Header.Set("Content-Type", "text/plain")
	if c.UserAgent != "" {
		req.Header.Set("User-Agent", c.UserAgent)
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, nil, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return nil, nil, err
	}
	return resp, data, nil
}

func refused(resp *http.Response, data []byte) error {
	switch resp.StatusCode {
	case http.StatusUnauthorized, http.StatusForbidden, http.StatusBadRequest:
		return &Refused{Status: resp.StatusCode, Text: strings.TrimSpace(string(data))}
	}
	return fmt.Errorf("HTTP %d: %s", resp.StatusCode, firstLine(string(data)))
}

// Claim asks for a job, waiting up to wait for one. A nil job is nothing to do.
func (c *Client) Claim(ctx context.Context, runnerID int64, headers http.Header, wait int) (*Job, Claim, error) {
	ctx, cancel := context.WithTimeout(ctx, time.Duration(wait+15)*time.Second)
	defer cancel()
	resp, data, err := c.request(ctx, runnerID, http.MethodPost, "/api/runner/claim?wait="+strconv.Itoa(wait), nil, headers)
	if err != nil {
		return nil, Claim{}, err
	}
	var info Claim
	info.Held = resp.Header.Get("X-Held")
	if s, err := strconv.Atoi(resp.Header.Get("Retry-After")); err == nil && s > 0 {
		if s > 60 {
			s = 60
		}
		info.RetryAfter = time.Duration(s) * time.Second
	}
	switch resp.StatusCode {
	case http.StatusNoContent:
		return nil, info, nil
	case http.StatusOK:
		job, err := parseJob(resp.Header, data)
		return job, info, err
	}
	return nil, info, refused(resp, data)
}

// parseJob reads a claimed job from its headers, checking each before use:
// they came from the server.
func parseJob(h http.Header, body []byte) (*Job, error) {
	id, err := strconv.ParseInt(h.Get("X-Job-Id"), 10, 64)
	if err != nil || id <= 0 {
		return nil, fmt.Errorf("the server sent a job with no usable id (%q)", h.Get("X-Job-Id"))
	}
	job := &Job{ID: id, Prompt: string(body)}
	job.Kind = h.Get("X-Job-Kind")
	if !kindName(job.Kind) {
		job.Kind = ""
	}
	if card, err := strconv.ParseInt(h.Get("X-Card-Id"), 10, 64); err == nil && card > 0 {
		job.CardID = card
	}
	if board, err := strconv.ParseInt(h.Get("X-Board-Id"), 10, 64); err == nil && board > 0 {
		job.BoardID = board
	}
	if u := h.Get("X-Card-Url"); strings.HasPrefix(u, "http://") || strings.HasPrefix(u, "https://") {
		job.CardURL = u
	}
	job.LeaseSeconds, _ = strconv.Atoi(h.Get("X-Lease-Seconds"))
	switch p := h.Get("X-Card-Profile"); p {
	case "docs", "fix", "feature", "schema", "security", "spike":
		job.Profile = p
	}
	job.MergePR = h.Get("X-Merge-Pr")
	job.MergeCommit = h.Get("X-Merge-Commit")
	return job, nil
}

func kindName(k string) bool {
	if k == "" || len(k) > 40 {
		return false
	}
	for _, r := range k {
		if !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '_' || r == '-') {
			return false
		}
	}
	return true
}

// Heartbeat renews the job's lease with the tail of its log. cancel says the
// board cancelled the job; ErrLost that it is no longer this runner's.
func (c *Client) Heartbeat(ctx context.Context, runnerID, jobID int64, tail []byte) (cancel bool, err error) {
	ctx, stop := context.WithTimeout(ctx, 15*time.Second)
	defer stop()
	resp, data, err := c.request(ctx, runnerID, http.MethodPost, fmt.Sprintf("/api/runner/jobs/%d/heartbeat", jobID), tail, nil)
	if err != nil {
		return false, err
	}
	switch resp.StatusCode {
	case http.StatusOK:
		return strings.TrimSpace(string(data)) == "cancel", nil
	case http.StatusNotFound:
		return false, ErrLost
	}
	return false, refused(resp, data)
}

// Transcript sends lines of the job's transcript starting at line from. The
// answer is the lines the server holds (where the next send starts) and
// whether its log is full.
func (c *Client) Transcript(ctx context.Context, runnerID, jobID int64, from int, lines []byte) (held int, capped bool, err error) {
	ctx, stop := context.WithTimeout(ctx, 15*time.Second)
	defer stop()
	resp, data, err := c.request(ctx, runnerID, http.MethodPost, fmt.Sprintf("/api/runner/jobs/%d/transcript?from=%d", jobID, from), lines, nil)
	if err != nil {
		return from, false, err
	}
	word, n := "", -1
	if f := strings.Fields(string(data)); len(f) == 2 {
		word = f[0]
		if v, err := strconv.Atoi(f[1]); err == nil && v >= 0 {
			n = v
		}
	}
	switch {
	case resp.StatusCode == http.StatusOK && word == "ok" && n >= 0,
		resp.StatusCode == http.StatusConflict && word == "from" && n >= 0:
		return n, false, nil
	case resp.StatusCode == http.StatusOK && word == "capped":
		return n, true, nil
	}
	return from, false, fmt.Errorf("HTTP %d: %s", resp.StatusCode, firstLine(string(data)))
}

// Finish reports the job ended: its exit code, its status when it was
// stopped (cancelled, timeout) or failed before it ran, the merge commit of
// a merge, and the tail of its log. It tries five times, a little apart; a
// job the server doesn't know (404) is reported.
func (c *Client) Finish(ctx context.Context, runnerID, jobID int64, exit int, status, merged string, tail []byte, sleep func(time.Duration)) error {
	q := fmt.Sprintf("exit=%d", exit)
	if status != "" {
		q += "&status=" + status
	}
	if merged != "" && isHex(merged) {
		q += "&merged=" + merged
	}
	var last error
	for try := 1; try <= 5; try++ {
		rctx, stop := context.WithTimeout(ctx, 30*time.Second)
		resp, data, err := c.request(rctx, runnerID, http.MethodPost, fmt.Sprintf("/api/runner/jobs/%d/finish?%s", jobID, q), tail, nil)
		stop()
		switch {
		case err != nil:
			last = err
		case resp.StatusCode == http.StatusOK, resp.StatusCode == http.StatusNotFound:
			return nil
		default:
			last = fmt.Errorf("HTTP %d: %s", resp.StatusCode, firstLine(string(data)))
		}
		if try < 5 {
			sleep(time.Duration(try*2) * time.Second)
		}
	}
	return last
}

// FetchConfig reads the machine's runners: at once with wait 0, else the
// server's long-poll for a version above since. nil is no change.
func (c *Client) FetchConfig(ctx context.Context, since int64, wait int) (*MachineConfig, error) {
	ctx, cancel := context.WithTimeout(ctx, time.Duration(wait+15)*time.Second)
	defer cancel()
	h := http.Header{"Accept": {"application/json"}}
	resp, data, err := c.request(ctx, 0, http.MethodGet, fmt.Sprintf("/api/machine/config?version=%d&wait=%d", since, wait), nil, h)
	if err != nil {
		return nil, err
	}
	switch resp.StatusCode {
	case http.StatusNoContent:
		return nil, nil
	case http.StatusOK:
		var mc MachineConfig
		if err := json.Unmarshal(data, &mc); err != nil {
			return nil, fmt.Errorf("the machine's config isn't JSON: %w", err)
		}
		return &mc, nil
	}
	return nil, refused(resp, data)
}

func isHex(s string) bool {
	if s == "" || len(s) > 64 {
		return false
	}
	for _, r := range s {
		if !(r >= '0' && r <= '9' || r >= 'a' && r <= 'f' || r >= 'A' && r <= 'F') {
			return false
		}
	}
	return true
}

func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	if len(s) > 200 {
		s = s[:200]
	}
	return s
}
