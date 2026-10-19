# LinkedIn mechanics

LinkedIn is the most productive source for senior roles and the one most able to hand
you a confident wrong answer. Everything here was learned by getting it wrong first.
The searches themselves belong on the person's `Sources` page; this
file is only how the site behaves.

## Contents

1. Which browser to use
2. Confirming you are signed in, and why it is not optional
3. Two layouts, and telling them apart
4. Collecting job ids
5. Reading the full job description
6. When a search returns nothing but does not say so
7. Building search URLs
8. Pagination
9. Apply links, and not clicking Apply
10. Getting the text out intact
11. Decoding what you capture

## 1. Which browser to use

A real signed-in browser session. An in-app or built-in browser pane first, the
person's own Chrome through an extension as a fallback, and plain web search only as a
last resort. Web search cannot apply a posted-in-the-last-24-hours filter at all, so a
run that falls back to it is materially degraded and the report should say so
prominently rather than presenting the result as a normal day.

## 2. Confirming you are signed in, and why it is not optional

Navigate to the feed and check for the member navigation:

```js
({ url: location.href,
   signinForm: !!document.querySelector('form.login__form, #session_key'),
   bodyStart: document.body.innerText.slice(0, 300) })
```

Signed in when `bodyStart` carries the member's own name and the nav counters. Signed
out when the URL is a `/login` or `/authwall` destination, or `signinForm` is true.

**The page title tells you nothing.** The old tell was an unread-notification count in
the title. A signed-in session has been observed with a bare `Feed | LinkedIn` title
while 24 notifications sat in the nav, so a missing count is not evidence either way,
and a run that stopped on that basis would have thrown away a good scan day.

**Do not infer a session from page content.** Guest job pages still render "Direct
message the job poster", "Referrals increase your chances" and "See who you know".
Those strings prove nothing.

**A signed-out scan is wrong, not degraded.** The guest result set is not a subset of
the member one, it is a different and much worse one. On one measured occasion the
guest view returned 40 results for a search, almost all individual-contributor keyword
noise, and silently omitted two genuine senior postings that the signed-in view
surfaced immediately, one of them a strong match posted six minutes earlier with no
applicants. Signed in, the same search returned 11 results, nearly all relevant.

So if there is no session: **stop searching LinkedIn**. Do not run its searches, do not
report counts for it, and log in the run notes that the browser is signed out and the
person needs to sign in. Other sources still run. An unattended run cannot authenticate and must never enter
credentials.

## 3. Two layouts, and telling them apart

LinkedIn serves two jobs interfaces and flips between them without notice. Check which
one you have before anything else, because the method for getting job ids is different
and the wrong one returns almost nothing while looking like it worked.

**Classic.** The URL keeps `/jobs/search/`. Result cards carry
`data-occludable-job-id`. Employment-type and other `f_` filters bind.

**Server-driven (SDUI).** `/jobs/search/` redirects to `/jobs/search-results/`, the URL
grows `isSdui=true`, and every class name is an obfuscated hash. Result cards are
`<button>` elements with no href and no job id anywhere in the DOM.

```js
({ sdui: /search-results|isSdui/.test(location.href),
   occludable: document.querySelectorAll('[data-occludable-job-id]').length })
```

## 4. Collecting job ids

**On classic, every id is in the DOM**, including for cards not yet rendered, so one
query gets the whole result set with no clicking:

```js
[...document.querySelectorAll('[data-occludable-job-id]')]
  .map(e => e.getAttribute('data-occludable-job-id'))
```

Only seven or so cards render at a time while the rest are occluded, so the visible
text is not the result set and the count in the header is the number to trust.

**On SDUI, there is no id to read**, and href scraping is dead: a selector on
`a[href*="/jobs/view/"]` returns one link rather than the result set. The only method
is to click a card and read the id out of the address bar:

```js
const el = [...document.querySelectorAll('div,span,p')]
  .find(e => e.childElementCount === 0 && e.innerText.trim() === COMPANY_NAME);
el.click();
await new Promise(r => setTimeout(r, 2500));
new URL(location.href).searchParams.get('currentJobId');
```

Because that costs a click and a page settle each time, read the results list as text
first, shortlist, and click only the cards that look like genuine candidates. This is
the whole reason not to capture links for roles that will score below the threshold.

Either way, the canonical URL to record is
`https://www.linkedin.com/jobs/view/<jobId>/`. It is stable and it is what the person
will click.

## 5. Reading the full job description

**Use the signed-in API, not the page.** On the current layouts,
`/jobs/view/<jobId>/` renders only the header and the description body never loads at
all; `get_page_text` returning a header and then jumping to the footer is the tell.
Scrolling, waiting and clicking "see more" do not help, because there is no description
module in the DOM to expand.

```js
const csrf = (document.cookie.match(/JSESSIONID="?([^";]+)/) || [])[1];
const r = await fetch(
  `/voyager/api/jobs/jobPostings/${jobId}?decorationId=com.linkedin.voyager.deco.jobs.web.shared.WebFullJobPosting-65`,
  { headers: { 'csrf-token': csrf,
               'accept': 'application/vnd.linkedin.normalized+json+2.1' } });
const j = await r.json(), d = j.data;
const ENTITY = /&(#\d+|#x[0-9a-f]+|[a-z][a-z0-9]*);/i;
const dec = s => typeof s === 'string' && ENTITY.test(s)
  ? new DOMParser().parseFromString('<!doctype html><body>' + s, 'text/html').body.textContent
  : s;
({ title: dec(d.title),
   company: dec((j.included || []).find(i => /organization\.Company$/.test(i.$type || ''))?.name),
   location: dec(d.formattedLocation),
   listedAt: new Date(d.listedAt).toISOString(),
   applies: d.applies,
   closed: d.closed,
   employmentStatus: d.employmentStatus,
   remoteAllowed: d.workRemoteAllowed,
   applyUrl: d.applyMethod && d.applyMethod.companyApplyUrl,
   description: dec(d.description.text) })
```

`dec` is the decoder from section 11. Wrap every text field as you build the object,
here and in the triage capture, so nothing downstream has to think about it.

This is better than the page in every respect: it returns the full text, the posted
timestamp, the applicant count, whether the posting is closed, and the external apply
destination, in one call.

Three notes:

- **It needs the signed-in session.** A 401 or 403 means the session has gone, which is
  the same stop condition as a signed-out search.
- **`companyApplyUrl` present means an external destination**; absent means Easy Apply.
  This replaces reading the apply link off the page and carries no risk of clicking
  Apply.
- **A description that "will not render" is almost always this**, not a transient
  fault. Three separate incidents were once logged as rendering problems and handled by
  carrying an old score across unconfirmed; the API would have read all three.

For triage across a whole result set, fetch each id and return only metadata plus a few
regex-derived flags rather than the full text. Reading twenty full descriptions to
score a day's results is a waste; reading the two that look promising is not.

## 6. When a search returns nothing but does not say so

This is the trap that produces repeat sightings and phantom same-day finds.

When a search has **no** genuine hits in the time window, LinkedIn does not say so. It
substitutes a recommendation module headed **"Jobs you may be interested in"**, where
every entry is promoted and none respects the date filter. Entries weeks old appear in
the furniture of a fresh result set.

```js
document.querySelector('main').innerText.slice(0, 60)
```

If that reads "Jobs you may be interested in", record the search as **zero genuine
results** and discard every entry. Do not score them and never report them as same-day
finds. Three searches returning an identical seven-item promoted block is the signature.

A related and milder case: LinkedIn appends loosely related results below a divider
reading "We found more results related to your search that may not be exact matches".
Those are genuine postings and should be included in scoring; the rubric filters them.
The divider is the most useful signal on the page for telling the two blocks apart.

## 7. Building search URLs

Verified, and worth not simplifying:

- **A text `location=` parameter is silently discarded.** Location filtering works only
  through `geoId`. A text location returns country-wide results while looking filtered,
  which is the worst possible failure: `geoId=102257491` returns Greater London only,
  where `location=London%2C%20England` returned Liverpool and Manchester too. The
  person's own geoIds belong on their `Sources` page.
- **`f_TPR=r86400`** is the last-24-hours filter, and it is what makes a daily scan a
  daily scan rather than a backfill.
- **`sortBy=DD` is stripped on redirect.** Results come back relevance-ranked whatever
  you ask for. Ignore ordering and rely on the posted timestamp, which is reliable.
- **`f_JT` (employment type) binds on classic and is stripped on SDUI.** Check it
  survived by reading the URL back after navigation, and confirm by looking at
  `employmentStatus` on the results. If it was stripped, drive the Employment type chip
  in the UI instead: open it, tick the type, apply, and confirm the chip label changed
  and the result count dropped. The chip is flaky through scripted clicks, so use a
  real click on the element and allow a few seconds.
- **Phrase searches for a working pattern do not work.** Exact phrases like
  `"Interim Director"` return the promoted module, because job titles almost never carry the
  phrase. A bare boolean `interim AND (...)` is not honoured either and returns a long
  list led by permanent roles. Filter by employment type, never by the words.
- **The results page loads asynchronously.** If a text extraction returns empty, wait
  and try once more before treating it as a failure.

## 8. Pagination

A result set larger than one page shows numbered page buttons and a "View next page"
control, and the header says how many results there are. A single page says so
explicitly. Check the count against what you collected before concluding a search is
complete: it is easy to scan one page of three and report a thin day.

## 9. Apply links, and not clicking Apply

**Do not click Apply or Easy Apply.** It opens an application dialog or a new tab and
risks starting a submission, which breaks the one constraint that matters most.

Two URLs, and they are not interchangeable:

- The **posting URL**, always available, always recorded. It is where the description
  is read.
- The **apply destination**, optional. Take it from `applyMethod.companyApplyUrl` and
  nowhere else. Many roles are Easy Apply and have no external destination at all:
  record that plainly and never invent or guess a link.

## 10. Getting the text out intact

A long description retyped from tool output is the one place a silent truncation
corrupts the stored record, and the stored record is the only copy once the posting
dies.

Compress and encode it in the browser, then verify what you stored:

```js
const gz = async s => {
  const cs = new CompressionStream('gzip');
  const w = cs.writable.getWriter(); w.write(new TextEncoder().encode(s)); w.close();
  const u = new Uint8Array(await new Response(cs.readable).arrayBuffer());
  let b = ''; for (const c of u) b += String.fromCharCode(c);
  return btoa(b);
};
const sha = async s => {
  const h = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s));
  return [...new Uint8Array(h)].map(x => x.toString(16).padStart(2, '0')).join('');
};
```

Hash the description at the source, store it, hash what you stored, and compare. Hash
the string you actually store: if it needed decoding (section 11), hash it after. A mismatch is recoverable in the moment and invisible a week later.

## 11. Decoding what you capture

Some of what you pull out of the page or the API is encoded for HTML, and none of the
places you write it are HTML. A company name can arrive as
`The Depository Trust &amp; Clearing Corporation`; a card title is plain text, so
`&amp;` is what the person then sees on the board, and the company-plus-title
de-duplication stops matching.

**But most of it is not encoded, and decoding clean text damages it.** On 2026-10-19 a
posting's `description.text` held no entities at all, and running it through a decoder
deleted all 5 ampersands and all 10 straight apostrophes: "R&D programme" became "RD
programme", "company's" became "companys". So decode **only a string that contains an
entity**, and leave every other string exactly as it came:

```js
const ENTITY = /&(#\d+|#x[0-9a-f]+|[a-z][a-z0-9]*);/i;
const dec = s => typeof s === 'string' && ENTITY.test(s)
  ? new DOMParser().parseFromString('<!doctype html><body>' + s, 'text/html').body.textContent
  : s;
```

`DOMParser` never executes scripts, which is why it is used rather than assigning the
string to an element's `innerHTML`.

Apply it to each string field as you build the result, not to the finished object:

```js
({ title: dec(d.title), company: dec(company), location: dec(d.formattedLocation) })
```

**Decode at most once.** A second pass turns a literal `&amp;` that the text genuinely
contained into a bare ampersand. `&amp;amp;` means the source was double-encoded: one
pass is still right; say so in the run notes.

`innerText` and `textContent` are already decoded. A value read that way is never
decoded again.

**Check after storing**, for the posting text: count `&` and `'` in the source string
and in what the role page holds. A difference means something decoded what it should
not have.
