# Build toolchain

Everything here is mechanics. What the documents say, how they are voiced and what the
file names are belong to the person's `Job Scan Document Rules` page.

## Contents

1. Check before you start
2. What each tool is for
3. Building the .docx
4. A helper library held in Slipdock
5. Rendering the PDF
6. Validating, and the gate sweeps
7. Attachments, and what they cost
8. Timing against the lease

## 1. Check before you start

Finding out halfway through that LibreOffice is missing wastes the expensive part of the
build. One command, first:

```sh
for c in pandoc soffice pdftotext pdfinfo node; do
  printf '%-10s %s\n' "$c" "$(command -v $c || echo MISSING)"
done
fc-list | grep -ci 'arial\|liberation sans'
```

Anything MISSING means the files cannot be built on this machine, and the skill's
step 10 applies: write the content, say which tool was missing, and do not report a
success.

**A cloud session has all of it already.** Measured on 2026-10-16: pandoc, LibreOffice,
poppler (`pdftotext`, `pdfinfo`), node 22 with the `docx` library resolvable,
python-docx 1.2.0, and four matching Arial or Liberation Sans faces. So the cloud path
needs no installation, and a toolchain failure almost always means the build is running
on someone's own machine through a local runner.

## 2. What each tool is for

| Tool | Used for |
|---|---|
| node, with the `docx` library | Writing the `.docx`, where the person's rules specify a node build |
| python-docx | The same job in Python, and for reading a `.docx` back to check it parses |
| LibreOffice (`soffice`) | Rendering the PDF from the final `.docx` |
| pandoc | Converting a `.docx` to plain text for the gate sweeps |
| poppler (`pdftotext`, `pdfinfo`) | Sweeping the PDF, and counting its pages |

## 3. Building the .docx

Follow whatever approach the person's document rules name. Where they specify a library
and a set of format values, those values are the specification: page size, margins,
font, sizes, heading colour, bullet format. A build that quietly uses the library's
defaults produces a document that looks nothing like their CV and passes every text
gate.

Two things that are easy to get wrong and hard to see afterwards:

- **Bullets.** Use the library's numbering or list feature with the character their
  rules specify. A literal unicode bullet typed into the text is not a list, does not
  indent, and survives every sweep.
- **One line per entry.** Where their rules say the title, company and dates are one
  line, build it as one line. A tab-stop layout or a two-paragraph arrangement reads
  differently in Word than in a PDF, and the PDF is what gets sent.

## 4. A helper library held in Slipdock

Where the document rules name a helper file, fetch it rather than reimplementing it.
`download_file` takes an attachment id, which `get_card` and `read_page` list, and it
saves the file locally rather than returning its bytes through the conversation, so it
is cheap.

**A vault file is not an attachment.** A file the rules describe as synced into a vault
may carry a file id that `download_file` will not accept. If the helper cannot be
fetched, **stop and say so**. Do not write your own version of it: the layout it
produces is part of a structure the person has declared immutable, and an
approximation will pass the gates while looking wrong on the page.

## 5. Rendering the PDF

Render from the final validated `.docx`, after the gates, so the two can never
disagree:

```sh
soffice --headless --convert-to pdf --outdir "$OUTDIR" "$FILE.docx"
```

- It is slow on a cold start, several seconds to half a minute, and it is silent while
  it works. Allow for it rather than timing it out.
- **Fonts.** Where Arial is unavailable, Liberation Sans is metric-compatible and
  substitutes without changing the line breaks, which is why the page count holds.
  A font that is neither will reflow the document and can turn two pages into three.
- **Whenever a `.docx` is rebuilt, re-render its PDF in the same run.** A stale PDF
  beside a corrected `.docx` is the worst of the failure modes here, because the PDF is
  the copy that gets sent.

## 6. Validating, and the gate sweeps

**Validate** that the `.docx` is a well-formed document, not merely a file that was
written. Reading it back with python-docx and confirming the paragraph count is a cheap
and sufficient check:

```sh
python3 -c "from docx import Document; d=Document('$FILE.docx'); print(len(d.paragraphs),'paragraphs')"
```

**Sweep** with pandoc for the text gates and pdftotext for the PDF, exactly as the
person's rules list them. Two notes on reading the results:

- `grep -c` answering `0` is a pass for a gate that must be clean, and a **failure** for
  a gate that requires something to be present, such as first person in a cover letter.
  Read which kind each gate is before acting on a count.
- A hit is not automatically a defect. A banned word inside a quotation from the
  posting, or describing the employer's vacancy, is legitimate. Read every hit.

**Page count**, where their rules fix one:

```sh
pdfinfo "$FILE.pdf" | grep Pages
```

A spill to an extra page means trimming the build, never trimming the PDF.

## 7. Attachments, and what they cost

`upload_file` takes `content_base64` for binary and `text` for a text file. Base64 the
file and pass it:

```sh
base64 -w0 "$FILE.docx"
```

**The base64 passes through the conversation, so attaching a file costs context.**
Measured on 2026-10-16: a 36 KB `.docx` encodes to about 48,900 characters, roughly
12,000 tokens; a 14 KB `.pdf` to about 19,300, roughly 4,800. Budget for it, attach what
the person will actually send, and keep everything else as text.

Three behaviours confirmed by round trip on 2026-10-16:

- **The bytes survive intact.** Uploaded and downloaded again, the SHA-256 matched.
- **`content_type` is inferred from the filename** and comes back correct for `.docx`,
  so passing it is unnecessary.
- **A second upload under the same filename adds a second attachment** rather than
  replacing the first, silently, and nothing available here can delete one. The newer
  attachment has the higher id. On a rebuild, say which id is current and leave the
  deletion to the person.

The reply carries `markdown` and `url` for the attachment. Use the `markdown` as given
if you want the file linked from a comment or a page body.

## 8. Timing against the lease

A claimed job's lease is 20 minutes. A four-document build with gates, a validation
step and two PDF renders runs comfortably past that if anything needs a second attempt,
and an expired lease hands the same card to the next claimer, which produces a duplicate
build rather than an error.

Call `job_progress` at the natural boundaries: after the content is written and gated,
after the files are built, and after the attachments are up. Its `note` is posted as a
comment on the card, so pass one only where it tells the person something, and renew
without a note the rest of the time.
