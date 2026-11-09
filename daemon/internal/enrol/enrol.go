// Package enrol gets a machine its key from the server (#2570): by device
// code, where a person approves the machine on the account's approval page,
// or at once with a one-time enrolment key made on the Machines page. The
// device flow follows RFC 8628: its error names, its interval and slow_down.
package enrol

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// About is how the machine describes itself; the approval page shows it.
type About struct {
	Hostname    string `json:"hostname"`
	OS          string `json:"os"`
	Arch        string `json:"arch"`
	Fingerprint string `json:"fingerprint"`
}

// Machine is the server's view of the enrolled machine.
type Machine struct {
	ID          int64   `json:"id"`
	Name        string  `json:"name"`
	Boards      []int64 `json:"boards"`
	EnrolledVia string  `json:"enrolled_via"`
	State       string  `json:"state"`
}

// Result is what a successful enrolment hands back.
type Result struct {
	Key     string  `json:"machine_key"`
	Machine Machine `json:"machine"`
}

// Start is the server's answer to starting a device-code enrolment.
type Start struct {
	DeviceCode              string `json:"device_code"`
	UserCode                string `json:"user_code"`
	VerificationURI         string `json:"verification_uri"`
	VerificationURIComplete string `json:"verification_uri_complete"`
	ExpiresIn               int    `json:"expires_in"`
	Interval                int    `json:"interval"`
}

// Error is an error the server named (RFC 8628 §3.5 and RFC 6749 §5.2).
type Error struct {
	Code        string `json:"error"`
	Description string `json:"error_description"`
	Status      int    `json:"-"`
}

func (e *Error) Error() string {
	if e.Description != "" {
		return fmt.Sprintf("%s: %s", e.Code, e.Description)
	}
	return e.Code
}

// Client talks to one server.
type Client struct {
	Server string
	HTTP   *http.Client
	// Sleep waits between polls; tests replace it.
	Sleep func(context.Context, time.Duration) error
	// UserAgent names the daemon and its version.
	UserAgent string
}

// NewClient is a client for server with sensible defaults.
func NewClient(server, userAgent string) *Client {
	return &Client{
		Server:    strings.TrimRight(server, "/"),
		HTTP:      &http.Client{Timeout: 30 * time.Second},
		Sleep:     sleep,
		UserAgent: userAgent,
	}
}

func sleep(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

// StartDevice asks the server for a device code and a user code.
func (c *Client) StartDevice(ctx context.Context, about About) (Start, error) {
	var s Start
	err := c.post(ctx, "/api/machines/enrol", about, &s)
	if err == nil && (s.DeviceCode == "" || s.UserCode == "") {
		err = errors.New("the server's answer had no device code: is this a Slipdock server new enough for machines?")
	}
	return s, err
}

// Poll asks for the machine key until a person approves the enrolment,
// refuses it, or it expires. It waits Interval seconds between asks, five
// more after each slow_down, as RFC 8628 §3.5 says.
func (c *Client) Poll(ctx context.Context, s Start) (Result, error) {
	interval := time.Duration(s.Interval) * time.Second
	if interval <= 0 {
		interval = 5 * time.Second
	}
	for {
		if err := c.Sleep(ctx, interval); err != nil {
			return Result{}, err
		}
		var r Result
		err := c.post(ctx, "/api/machines/enrol/token", map[string]string{"device_code": s.DeviceCode}, &r)
		var e *Error
		switch {
		case err == nil:
			return r, checkResult(r)
		case errors.As(err, &e) && e.Code == "authorization_pending":
			continue
		case errors.As(err, &e) && e.Code == "slow_down":
			interval += 5 * time.Second
			continue
		case errors.As(err, &e) && e.Code == "access_denied":
			return Result{}, errors.New("the enrolment was refused on the approval page")
		case errors.As(err, &e) && e.Code == "expired_token":
			return Result{}, errors.New("the code expired before anyone approved it: run init again")
		default:
			return Result{}, err
		}
	}
}

// WithKey enrols at once with a one-time enrolment key.
func (c *Client) WithKey(ctx context.Context, key string, about About) (Result, error) {
	body := map[string]string{
		"enrolment_key": key,
		"hostname":      about.Hostname,
		"os":            about.OS,
		"arch":          about.Arch,
		"fingerprint":   about.Fingerprint,
	}
	var r Result
	if err := c.post(ctx, "/api/machines/enrol/token", body, &r); err != nil {
		return Result{}, err
	}
	return r, checkResult(r)
}

// Me asks the server which machine a key belongs to (GET /api/machine).
func (c *Client) Me(ctx context.Context, key string) (Machine, error) {
	var out struct {
		Machine Machine `json:"machine"`
		Error   string  `json:"error"`
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.Server+"/api/machine", nil)
	if err != nil {
		return Machine{}, err
	}
	req.Header.Set("Authorization", "Bearer "+key)
	if err := c.do(req, &out); err != nil {
		return Machine{}, err
	}
	return out.Machine, nil
}

// SetupPrompt fetches the server's machine-setup prompt for this machine
// (GET /api/machine/setup-prompt): what Claude is told to make the machine
// ready to run the board's jobs. A server that predates it answers 404
// (IsNotFound).
func (c *Client) SetupPrompt(ctx context.Context, key string) (string, error) {
	var out struct {
		Prompt string `json:"prompt"`
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.Server+"/api/machine/setup-prompt", nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+key)
	if err := c.do(req, &out); err != nil {
		return "", err
	}
	if strings.TrimSpace(out.Prompt) == "" {
		return "", errors.New("the server's setup prompt is empty")
	}
	return out.Prompt, nil
}

func checkResult(r Result) error {
	if r.Key == "" {
		return errors.New("the server approved the enrolment but sent no machine key")
	}
	return nil
}

func (c *Client) post(ctx context.Context, path string, body, out any) error {
	data, err := json.Marshal(body)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.Server+path, bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	return c.do(req, out)
}

func (c *Client) do(req *http.Request, out any) error {
	req.Header.Set("Accept", "application/json")
	if c.UserAgent != "" {
		req.Header.Set("User-Agent", c.UserAgent)
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return fmt.Errorf("can't reach %s: %w", c.Server, err)
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return err
	}
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		if err := json.Unmarshal(data, out); err != nil {
			return fmt.Errorf("the server's answer isn't JSON (%d): %w", resp.StatusCode, err)
		}
		return nil
	}
	e := &Error{Status: resp.StatusCode}
	if json.Unmarshal(data, e) != nil || e.Code == "" {
		e.Code = fmt.Sprintf("http_%d", resp.StatusCode)
		e.Description = strings.TrimSpace(string(data))
		if len(e.Description) > 200 {
			e.Description = e.Description[:200]
		}
	}
	if resp.StatusCode == http.StatusUnauthorized {
		e.Code = "unauthorized"
		e.Description = "the server doesn't accept this machine's key: it was revoked, or the machine was enrolled elsewhere"
	}
	return e
}

// IsUnauthorized says whether err is the server refusing the machine key.
func IsUnauthorized(err error) bool {
	var e *Error
	return errors.As(err, &e) && e.Status == http.StatusUnauthorized
}

// IsNotFound says whether err is the server answering 404: an endpoint the
// server doesn't have yet.
func IsNotFound(err error) bool {
	var e *Error
	return errors.As(err, &e) && e.Status == http.StatusNotFound
}
