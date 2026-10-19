#!/usr/bin/env python3
"""Build application documents for the job-search Tool.

    build_docs.py build    --kind cv|letter|other --template T.docx --rules RULES.md
                           --out DIR --name NAME CONTENT.md
    build_docs.py check    --kind cv|letter|other --rules RULES.md FILE.docx [FILE.pdf]
    build_docs.py inspect  CV.docx
    build_docs.py template --out T.docx [--from CV.docx] [--font F] [--size PT] ...

`build` turns markdown into a .docx styled by the template (pandoc), puts the
template's bullet character back into the lists (pandoc ignores it), renders a
PDF from that .docx (LibreOffice), counts its pages and runs the text checks.
`check` runs the checks alone. `inspect` reports a CV's page setup, fonts,
sizes and colours, and `template` makes a style template from them.

The checks and the build settings come from the person's Writing Rules page,
saved to a file and passed as --rules. Two fenced blocks are read from it:

    ```build
    bullet: -
    cv pages: 2
    ```

    ```checks
    forbid all | third person | \\b(he|his|him|himself)\\b
    require letter | first person | \\b(I|my|me)\\b
    max 2 all | antithesis | \\brather than\\b|, not [a-z]
    ```

A check line is `<rule> <documents> | <label> | <regex>`. The rule is
`forbid` (no hits allowed), `require` (at least one hit) or `max N` (at most N
hits). The documents are `all`, or a comma list of `cv`, `letter`, `other`.
Patterns are Python regular expressions, matched case-insensitively and per
line; `(?-i:...)` makes a part case-sensitive.

Exit status: 0 when every check passed, 1 when one failed (the report says
which, with each hit's line), 2 when the build itself could not run. Every hit
is for a person or an agent to read: a banned word inside a quotation from the
posting is not a defect. The report is printed as text, and as JSON with
--json.

Needs: pandoc, and for PDFs LibreOffice (soffice) and pdftotext/pdfinfo
(poppler). Nothing outside the Python standard library.

With `engine: html` in the build block, `build --kind cv|letter` makes a designed
PDF instead, with no .docx and no template: the markdown is laid out as HTML (for
the CV, a coloured sidebar on every page holding the sections the `sidebar` line
names) and printed to a tagged PDF by Chromium through Playwright. Its settings,
all optional: `font` and `font version` (an @fontsource package, fetched with npm
and cached), `colour primary`, `colour accent`, `colour accent light`, `sidebar`,
`numbers section`, `status section`, `cv pages`, `letter pages`. It also needs
Python Playwright with Chromium and poppler's pdffonts, and adds two checks: no
Type 3 fonts, and the entries readable from the PDF's text in order.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from collections import Counter

KINDS = ("cv", "letter", "other")
EM_DASH = "\u2014"
DEFAULT_BULLET = "\u2022"


class BuildError(Exception):
    pass


# ---------------------------------------------------------------------------
# Reading the Writing Rules page


def fenced_blocks(text, lang):
    """The bodies of every ```<lang> fenced block in a markdown text."""
    pattern = re.compile(r"^```[ \t]*" + re.escape(lang) + r"[ \t]*\n(.*?)^```[ \t]*$", re.M | re.S)
    return [m.group(1) for m in pattern.finditer(text)]


def parse_settings(text):
    settings = {}
    for block in fenced_blocks(text, "build"):
        for line in block.splitlines():
            line = line.strip()
            if not line or line.startswith("#") or ":" not in line:
                continue
            key, value = line.split(":", 1)
            settings[key.strip().lower()] = value.strip()
    return settings


CHECK_HEAD = re.compile(r"^(forbid|require|max\s+(\d+))\s+([a-z, ]+)$")


def parse_checks(text):
    """Check lines from the ```checks blocks. A malformed line is an error, not a skip:
    a check that silently stops running looks exactly like one that passes."""
    checks = []
    for block in fenced_blocks(text, "checks"):
        for n, raw in enumerate(block.splitlines(), 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split(" | ", 2)
            if len(parts) != 3:
                raise BuildError(f"checks line {n}: expected '<rule> <documents> | <label> | <regex>': {line}")
            head, label, pattern = (p.strip() for p in parts)
            m = CHECK_HEAD.match(head)
            if not m:
                raise BuildError(f"checks line {n}: rule must be forbid, require or 'max N', then documents: {head}")
            kinds = {k.strip() for k in m.group(3).split(",") if k.strip()}
            unknown = kinds - set(KINDS) - {"all"}
            if unknown:
                raise BuildError(f"checks line {n}: unknown document kind {', '.join(sorted(unknown))}")
            try:
                regex = re.compile(pattern, re.I)
            except re.error as e:
                raise BuildError(f"checks line {n}: bad pattern {pattern!r}: {e}")
            rule = "max" if m.group(2) else m.group(1)
            checks.append(
                {
                    "rule": rule,
                    "limit": int(m.group(2)) if m.group(2) else None,
                    "kinds": kinds,
                    "label": label,
                    "pattern": pattern,
                    "regex": regex,
                }
            )
    return checks


def read_rules(path):
    if not path:
        return {}, []
    with open(path, encoding="utf-8") as f:
        text = f.read()
    return parse_settings(text), parse_checks(text)


# ---------------------------------------------------------------------------
# Checks


def run_checks(checks, kind, sources):
    """sources: [(name, text)], the .docx text first. A check counts its hits in the
    .docx text; a forbid check also fails on hits that only the PDF shows."""
    results = []
    for check in checks:
        if "all" not in check["kinds"] and kind not in check["kinds"]:
            continue
        per_source = {}
        for name, text in sources:
            hits = []
            for lineno, line in enumerate(text.splitlines(), 1):
                found = check["regex"].findall(line)
                if found:
                    hits.append({"line": lineno, "count": len(found), "text": line.strip()[:200]})
            per_source[name] = hits
        primary = sources[0][0]
        count = sum(h["count"] for h in per_source[primary])
        if check["rule"] == "forbid":
            count = max(count, *(sum(h["count"] for h in hs) for hs in per_source.values()))
            ok = count == 0
        elif check["rule"] == "require":
            ok = count > 0
        else:
            ok = count <= check["limit"]
        results.append(
            {
                "label": check["label"],
                "rule": check["rule"] if check["rule"] != "max" else f"max {check['limit']}",
                "pattern": check["pattern"],
                "count": count,
                "ok": ok,
                "hits": {k: v for k, v in per_source.items() if v},
            }
        )
    return results


# ---------------------------------------------------------------------------
# External tools


def need(cmd):
    path = shutil.which(cmd)
    if not path:
        raise BuildError(f"{cmd} is not installed on this machine")
    return path


def run(args, **kw):
    p = subprocess.run(args, capture_output=True, text=True, **kw)
    if p.returncode != 0:
        raise BuildError(f"{os.path.basename(args[0])} failed: {(p.stderr or p.stdout).strip()[:500]}")
    return p.stdout


def docx_text(path):
    return run([need("pandoc"), path, "-t", "plain", "--wrap=none"])


def pdf_text(path):
    if not shutil.which("pdftotext"):
        return None
    return run(["pdftotext", "-layout", path, "-"])


def pdf_pages(path):
    if shutil.which("pdfinfo"):
        m = re.search(r"^Pages:\s+(\d+)", run(["pdfinfo", path]), re.M)
        if m:
            return int(m.group(1))
    with open(path, "rb") as f:
        data = f.read()
    m = re.findall(rb"/Type\s*/Pages\b[^>]*?/Count\s+(\d+)", data)
    if m:
        return max(int(x) for x in m)
    return len(re.findall(rb"/Type\s*/Page\b(?!s)", data)) or None


def soffice():
    for c in ("soffice", "libreoffice"):
        if shutil.which(c):
            return shutil.which(c)
    for c in ("/Applications/LibreOffice.app/Contents/MacOS/soffice", r"C:\Program Files\LibreOffice\program\soffice.exe"):
        if os.path.exists(c):
            return c
    raise BuildError("LibreOffice (soffice) is not installed on this machine")


def render_pdf(docx, outdir):
    # A private profile, so a LibreOffice the person has open doesn't swallow the job.
    with tempfile.TemporaryDirectory() as profile:
        run(
            [
                soffice(),
                f"-env:UserInstallation=file://{os.path.abspath(profile)}",
                "--headless",
                "--convert-to",
                "pdf",
                "--outdir",
                outdir,
                docx,
            ],
            timeout=180,
        )
    pdf = os.path.join(outdir, os.path.splitext(os.path.basename(docx))[0] + ".pdf")
    if not os.path.exists(pdf):
        raise BuildError("LibreOffice ran but wrote no PDF")
    return pdf


# ---------------------------------------------------------------------------
# .docx surgery. String edits rather than an XML library, so every namespace
# declaration Word relies on survives untouched.


def rewrite_zip(path, edits):
    """edits: {member: fn(str) -> str}."""
    tmp = path + ".tmp"
    with zipfile.ZipFile(path) as src, zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as dst:
        for item in src.infolist():
            data = src.read(item.filename)
            if item.filename in edits:
                data = edits[item.filename](data.decode("utf-8")).encode("utf-8")
            dst.writestr(item, data)
    os.replace(tmp, path)


def read_member(path, member):
    with zipfile.ZipFile(path) as z:
        try:
            return z.read(member).decode("utf-8")
        except KeyError:
            return None


def bullet_levels(xml, used=None):
    """[(char, left, hanging)] for the bullet lists a numbering.xml defines, level 0 of
    each; with `used` (numIds), only those lists, most used first."""
    abstracts = {
        m.group(1): m.group(0)
        for m in re.finditer(r'<w:abstractNum [^>]*w:abstractNumId="(\d+)".*?</w:abstractNum>', xml, re.S)
    }
    order = list(abstracts)
    if used is not None:
        nums = dict(re.findall(r'<w:num w:numId="(\d+)"[^>]*>\s*<w:abstractNumId w:val="(\d+)"', xml))
        order = [nums[n] for n, _ in Counter(used).most_common() if n in nums]
    out = []
    for aid in order:
        lvl = re.search(r'<w:lvl w:ilvl="0".*?</w:lvl>', abstracts.get(aid, ""), re.S)
        if not lvl or '<w:numFmt w:val="bullet"' not in lvl.group(0):
            continue
        text = re.search(r'<w:lvlText w:val="([^"]*)"', lvl.group(0))
        ind = re.search(r'<w:ind [^>]*w:left="(\d+)"[^>]*w:hanging="(\d+)"', lvl.group(0))
        char = unescape_attr(text.group(1)) if text else ""
        if char.strip():
            out.append((char, int(ind.group(1)) if ind else None, int(ind.group(2)) if ind else None))
    return out


def template_bullet(template):
    """The bullet the template defines first: (char, left, hanging), or None."""
    levels = bullet_levels(read_member(template, "word/numbering.xml") or "")
    return levels[0] if levels else None


def escape_attr(s):
    return s.replace("&", "&amp;").replace('"', "&quot;").replace("<", "&lt;").replace(">", "&gt;")


def unescape_attr(s):
    return s.replace("&quot;", '"').replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")


def fix_bullets(xml, bullet, font, indent=None):
    """Every bullet level gets `bullet` as its text, in the body font rather than
    Symbol, which is what pandoc leaves there whatever the template says. With
    indent (left, hanging) in twips, level 0 takes it and each deeper level steps in
    by the same left."""

    def lvl(m):
        block = m.group(0)
        if '<w:numFmt w:val="bullet"' not in block:
            return block
        block = re.sub(r'<w:lvlText w:val="[^"]*"\s*/>', f'<w:lvlText w:val="{escape_attr(bullet)}" />', block)
        block = re.sub(r"<w:rPr>.*?</w:rPr>", "", block, flags=re.S)
        if indent and indent[0] is not None:
            level = int(re.search(r'w:ilvl="(\d+)"', block).group(1))
            left, hanging = indent[0] * (level + 1), indent[1]
            block = re.sub(r"<w:tabs>.*?</w:tabs>", "", block, flags=re.S)
            block = re.sub(r"<w:ind [^>]*/>", f'<w:ind w:left="{left}" w:hanging="{hanging}" />', block)
        fonts = f'<w:rFonts w:ascii="{font}" w:hAnsi="{font}" w:cs="{font}" />' if font else ""
        return block.replace("</w:lvl>", f"<w:rPr>{fonts}</w:rPr></w:lvl>")

    return re.sub(r"<w:lvl\b.*?</w:lvl>", lvl, xml, flags=re.S)


def body_font(template):
    xml = read_member(template, "word/styles.xml") or ""
    m = re.search(r"<w:rPrDefault>.*?<w:rFonts [^>]*w:ascii=\"([^\"]+)\"", xml, re.S)
    return m.group(1) if m else None


# ---------------------------------------------------------------------------
# inspect / template

WORD_DEFAULT_HALF_POINTS = 20  # what Word uses when neither a run nor a style sets a size


def style_table(styles):
    """styleId -> {based_on, sz, font, bold, colour, jc}."""
    table = {}
    for m in re.finditer(r'<w:style [^>]*w:styleId="([^"]+)".*?</w:style>', styles, re.S):
        block = m.group(0)
        get = lambda pat: (re.search(pat, block) or [None, None])[1]  # noqa: E731
        table[m.group(1)] = {
            "based_on": get(r'<w:basedOn w:val="([^"]+)"'),
            "sz": get(r'<w:sz w:val="(\d+)"'),
            "font": get(r'<w:rFonts [^>]*w:ascii="([^"]+)"'),
            "colour": get(r'<w:color w:val="([0-9A-Fa-f]{6})"'),
            "bold": "1" if re.search(r'<w:rPr>.*?<w:b(?:\s*/>|\s+w:val="(?:1|true|on)")', block, re.S) else None,
            "default": 'w:default="1"' in block and 'w:type="paragraph"' in block,
        }
    return table


def style_value(table, style_id, key):
    seen = set()
    while style_id and style_id in table and style_id not in seen:
        seen.add(style_id)
        if table[style_id][key]:
            return table[style_id][key]
        style_id = table[style_id]["based_on"]
    return None


def inspect_docx(path):
    """What a .docx looks like, measured by the characters each property covers."""
    doc = read_member(path, "word/document.xml")
    if doc is None:
        raise BuildError(f"{path} is not a .docx")
    styles = read_member(path, "word/styles.xml") or ""
    table = style_table(styles)
    normal = next((k for k, v in table.items() if v["default"]), "Normal")
    defaults = re.search(r"<w:rPrDefault>(.*?)</w:rPrDefault>", styles, re.S)
    defaults = defaults.group(1) if defaults else ""
    d_sz = re.search(r'<w:sz w:val="(\d+)"', defaults)
    d_font = re.search(r'<w:rFonts [^>]*w:ascii="([^"]+)"', defaults)

    info = {}
    sect = re.findall(r"<w:sectPr\b.*?</w:sectPr>", doc, re.S)
    if sect:
        s = sect[-1]
        pg = re.search(r'<w:pgSz [^>]*w:w="(\d+)"[^>]*w:h="(\d+)"', s)
        if pg:
            info["page_twips"] = [int(pg.group(1)), int(pg.group(2))]
            info["page"] = {(11906, 16838): "a4", (12240, 15840): "letter"}.get(tuple(info["page_twips"]), "custom")
        mar = re.search(r"<w:pgMar ([^>]*)/?>", s)
        if mar:
            info["margins_twips"] = {k: int(v) for k, v in re.findall(r'w:(top|right|bottom|left)="(-?\d+)"', mar.group(1))}

    fonts, sizes, bold_sizes, colours, used_nums = Counter(), Counter(), Counter(), Counter(), []
    paragraphs = re.findall(r"<w:p\b.*?</w:p>", doc, re.S)
    first = None
    for p in paragraphs:
        ppr = re.search(r"<w:pPr>.*?</w:pPr>", p, re.S)
        ppr = ppr.group(0) if ppr else ""
        pstyle = (re.search(r'<w:pStyle w:val="([^"]+)"', ppr) or [None, normal])[1]
        num = re.search(r'<w:numId w:val="(\d+)"', ppr)
        if num:
            used_nums.append(num.group(1))
        for r in re.findall(r"<w:r\b.*?</w:r>", p, re.S):
            text = "".join(re.findall(r"<w:t(?:\s[^>]*)?>([^<]*)</w:t>", r))
            if not text.strip():
                continue
            n = len(text)
            rpr = re.search(r"<w:rPr>.*?</w:rPr>", r, re.S)
            rpr = rpr.group(0) if rpr else ""
            f = re.search(r'<w:rFonts [^>]*w:ascii="([^"]+)"', rpr)
            # A font taken from the theme has no name here: it counts as unknown.
            font = f.group(1) if f else (style_value(table, pstyle, "font") or (d_font.group(1) if d_font else None))
            sz = re.search(r'<w:sz w:val="(\d+)"', rpr)
            half = int(sz.group(1)) if sz else int(style_value(table, pstyle, "sz") or (d_sz.group(1) if d_sz else WORD_DEFAULT_HALF_POINTS))
            size = half / 2
            if font:
                fonts[font] += n
            sizes[size] += n
            if re.search(r'<w:b(?:\s*/>|\s+w:val="(?:1|true|on)")', rpr) or style_value(table, pstyle, "bold"):
                bold_sizes[size] += n
            c = re.search(r'<w:color w:val="([0-9A-Fa-f]{6})"', rpr)
            colour = c.group(1) if c else style_value(table, pstyle, "colour")
            if colour and colour.upper() != "000000":
                colours[colour.upper()] += n
            if first is None:
                first = {"size": size, "centred": '<w:jc w:val="center"' in ppr}

    bullets = bullet_levels(read_member(path, "word/numbering.xml") or "", used_nums)
    info["fonts"] = fonts.most_common(5)
    info["sizes_pt"] = sizes.most_common(6)
    info["bold_sizes_pt"] = bold_sizes.most_common(6)
    info["colours"] = colours.most_common(4)
    info["bullets"] = bullets[:3]
    info["borders"] = len(re.findall(r"<w:pBdr>", doc))
    info["tables"] = len(re.findall(r"<w:tbl>", doc))
    info["headers"] = len(re.findall(r"<w:headerReference", doc))
    body = info["sizes_pt"][0][0] if info["sizes_pt"] else None
    bigger_bold = sorted((s for s, _ in bold_sizes.items() if body and s > body and (not first or s != first["size"])), reverse=False)
    info["suggested"] = {
        "font": info["fonts"][0][0] if info["fonts"] else None,
        "size": body,
        "heading_size": bigger_bold[-1] if bigger_bold else None,
        "name_size": first["size"] if first else None,
        "centre_name": first["centred"] if first else False,
        "heading_colour": info["colours"][0][0] if info["colours"] else None,
        "heading_border": info["borders"] > 0,
        "bullet": bullets[0][0] if bullets else None,
        "bullet_indent": [bullets[0][1], bullets[0][2]] if bullets and bullets[0][1] is not None else None,
        "page": info.get("page"),
        "margins_twips": info.get("margins_twips"),
    }
    return info


PAGES = {"a4": (11906, 16838), "letter": (12240, 15840)}


def style_block(style_id, name, ppr, rpr, based_on="Normal", next_style=None, custom=False):
    nxt = f'<w:next w:val="{next_style}" />' if next_style else ""
    cust = ' w:customStyle="1"' if custom else ""
    return (
        f'<w:style w:type="paragraph"{cust} w:styleId="{style_id}">'
        f'<w:name w:val="{name}" /><w:basedOn w:val="{based_on}" />{nxt}<w:qFormat />'
        f"<w:pPr>{ppr}</w:pPr><w:rPr>{rpr}</w:rPr></w:style>"
    )


def twips(points):
    return round(float(points) * 20)


def make_template(out, opts):
    """A pandoc reference document carrying the CV's look. Markdown maps onto it as:
    `#` the name at the top, `##` a section heading, `###` an entry line, body text
    and bullets in the body style, and three paragraph styles for a fenced div
    (`::: {custom-style="Contact"}`): Contact and Headline under the name, and
    Strapline under an entry line."""
    p = subprocess.run([need("pandoc"), "--print-default-data-file", "reference.docx"], capture_output=True)
    if p.returncode != 0 or not p.stdout:
        raise BuildError("pandoc could not supply its reference document")
    with open(out, "wb") as f:
        f.write(p.stdout)

    font = opts["font"]
    size = round(float(opts["size"]) * 2)
    head = round(float(opts["heading_size"]) * 2)
    name = round(float(opts["name_size"]) * 2)
    headline = round((float(opts["size"]) + 1) * 2)
    colour = (opts["heading_colour"] or "000000").lstrip("#").upper()
    sp = {k: twips(v) for k, v in opts["spacing"].items()}
    centre = '<w:jc w:val="center" />' if opts["centre_name"] else ""
    fonts = f'<w:rFonts w:ascii="{font}" w:hAnsi="{font}" w:eastAsia="{font}" w:cs="{font}" />'
    border = (
        f'<w:pBdr><w:bottom w:val="single" w:sz="6" w:space="2" w:color="{colour}" /></w:pBdr>'
        if opts["heading_border"]
        else ""
    )
    caps = "<w:caps />" if opts["caps"] else ""
    body_ppr = f'<w:spacing w:before="0" w:after="{sp["body"]}" />'
    name_rpr = f'<w:b /><w:caps /><w:color w:val="{colour}" /><w:sz w:val="{name}" /><w:szCs w:val="{name}" />'
    styles_new = {
        "Normal": f'<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal" /><w:qFormat /><w:pPr>{body_ppr}</w:pPr><w:rPr>{fonts}<w:sz w:val="{size}" /><w:szCs w:val="{size}" /></w:rPr></w:style>',
        "BodyText": style_block("BodyText", "Body Text", body_ppr, ""),
        "FirstParagraph": style_block("FirstParagraph", "First Paragraph", body_ppr, "", "BodyText", "BodyText", True),
        "Compact": style_block("Compact", "Compact", f'<w:spacing w:before="0" w:after="{sp["bullet"]}" />', "", "BodyText", None, True),
        "Title": style_block("Title", "Title", f'{centre}<w:spacing w:before="0" w:after="{sp["contact"]}" />', name_rpr, "Normal", "BodyText"),
        "Heading1": style_block("Heading1", "heading 1", f'<w:keepNext />{centre}<w:spacing w:before="0" w:after="{sp["contact"]}" /><w:outlineLvl w:val="0" />', name_rpr, "Normal", "BodyText"),
        "Heading2": style_block("Heading2", "heading 2", f'<w:keepNext />{border}<w:spacing w:before="{sp["heading_before"]}" w:after="{sp["heading_after"]}" /><w:outlineLvl w:val="1" />', f'<w:b />{caps}<w:color w:val="{colour}" /><w:sz w:val="{head}" /><w:szCs w:val="{head}" />', "Normal", "BodyText"),
        "Heading3": style_block("Heading3", "heading 3", f'<w:keepNext /><w:spacing w:before="{sp["entry_before"]}" w:after="{sp["entry_after"]}" /><w:outlineLvl w:val="2" />', f'<w:b /><w:sz w:val="{size}" /><w:szCs w:val="{size}" />', "Normal", "BodyText"),
        "Contact": style_block("Contact", "Contact", f'{centre}<w:spacing w:before="0" w:after="{sp["contact"]}" />', "", "Normal", None, True),
        "Headline": style_block("Headline", "Headline", f'{centre}<w:spacing w:before="0" w:after="{sp["headline_after"]}" />', f'<w:b /><w:sz w:val="{headline}" /><w:szCs w:val="{headline}" />', "Normal", None, True),
        "Strapline": style_block("Strapline", "Strapline", f'<w:keepNext /><w:spacing w:before="0" w:after="{sp["strapline_after"]}" />', "<w:i />", "Normal", None, True),
    }

    def styles(xml):
        xml = re.sub(
            r"<w:rPrDefault>.*?</w:rPrDefault>",
            f'<w:rPrDefault><w:rPr>{fonts}<w:sz w:val="{size}" /><w:szCs w:val="{size}" /><w:lang w:val="en-GB" w:eastAsia="en-US" w:bidi="ar-SA" /></w:rPr></w:rPrDefault>',
            xml,
            flags=re.S,
        )
        xml = re.sub(r"<w:pPrDefault>.*?</w:pPrDefault>", f"<w:pPrDefault><w:pPr>{body_ppr}</w:pPr></w:pPrDefault>", xml, flags=re.S)
        for sid, block in styles_new.items():
            pat = re.compile(r'<w:style [^>]*w:styleId="' + sid + r'".*?</w:style>', re.S)
            xml = pat.sub(lambda _m: block, xml) if pat.search(xml) else xml.replace("</w:styles>", block + "</w:styles>")
        return xml

    page = opts["page"]
    w, h = page if isinstance(page, (list, tuple)) else PAGES.get(page, PAGES["a4"])
    m = opts["margins"]
    sect = (
        f'<w:sectPr><w:pgSz w:w="{w}" w:h="{h}" />'
        f'<w:pgMar w:top="{m["top"]}" w:right="{m["right"]}" w:bottom="{m["bottom"]}" w:left="{m["left"]}" '
        f'w:header="0" w:footer="0" w:gutter="0" /></w:sectPr>'
    )

    def document(xml):
        xml = re.sub(r"<w:sectPr\s*/>|<w:sectPr\b.*?</w:sectPr>", "", xml, flags=re.S)
        return xml.replace("</w:body>", sect + "</w:body>")

    def numbering(xml):
        return fix_bullets(xml, opts["bullet"], font, opts["bullet_indent"])

    edits = {"word/styles.xml": styles, "word/document.xml": document}
    if read_member(out, "word/numbering.xml") is not None:
        edits["word/numbering.xml"] = numbering
    rewrite_zip(out, edits)
    return out


# ---------------------------------------------------------------------------
# The designed PDF: `engine: html` in the build block. The same markdown is laid
# out as HTML (a coloured sidebar on every page for the CV, a plain page for the
# letter) and printed to a tagged PDF by Chromium through Playwright. No .docx.


def md_inline(s):
    """Escape, then **bold**. Nothing else in the CV markdown carries inline markup."""
    s = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")
    return re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)


DIV_OPEN = re.compile(r'^:::\s*\{custom-style="([^"]+)"\}\s*$')


def parse_cv_markdown(text):
    """The CV markdown the template build reads, as structure: the name, the divs under
    it, and sections of paragraphs, bullets, `**Label:** text` lines and entries."""
    doc = {"name": "", "divs": {}, "sections": []}
    section = entry = None
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        raw = lines[i]
        line = raw.strip()
        m = DIV_OPEN.match(line)
        if m:
            body = []
            i += 1
            while i < len(lines) and lines[i].strip() != ":::":
                if lines[i].strip():
                    body.append(lines[i].strip())
                i += 1
            value = " ".join(body)
            if entry is not None and m.group(1) == "Strapline":
                entry["strap"] = value
            elif section is None:
                doc["divs"][m.group(1)] = value
            else:
                section["blocks"].append({"type": "div", "style": m.group(1), "text": value})
        elif line.startswith("# ") and not doc["name"]:
            doc["name"] = line[2:].strip()
        elif line.startswith("## "):
            section = {"title": line[3:].strip(), "blocks": []}
            doc["sections"].append(section)
            entry = None
        elif line.startswith("### ") and section is not None:
            entry = {"type": "entry", "line": line[4:].strip(), "parts": [p.strip() for p in line[4:].split("|")], "strap": "", "bullets": [], "paras": []}
            section["blocks"].append(entry)
        elif line.startswith("- ") and section is not None:
            if entry is not None:
                entry["bullets"].append(line[2:].strip())
            elif section["blocks"] and section["blocks"][-1]["type"] == "bullets":
                section["blocks"][-1]["items"].append(line[2:].strip())
            else:
                section["blocks"].append({"type": "bullets", "items": [line[2:].strip()]})
        elif line and section is not None:
            lab = re.match(r"^\*\*(.+?):\*\*\s*(.*)$", line)
            target = entry["paras"] if entry is not None else None
            if lab and target is None:
                section["blocks"].append({"type": "label", "label": lab.group(1), "text": lab.group(2)})
            elif target is not None:
                target.append(line)
            else:
                section["blocks"].append({"type": "para", "text": line})
        elif line and section is None and not line.startswith("#"):
            doc["divs"].setdefault("Body", "")
            doc["divs"]["Body"] += (" " if doc["divs"]["Body"] else "") + line
        i += 1
    return doc


def parse_letter_markdown(text):
    """The letter: the name, its divs, then every other non-empty line is a paragraph."""
    doc = {"name": "", "divs": {}, "paras": []}
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        m = DIV_OPEN.match(line)
        if m:
            body = []
            i += 1
            while i < len(lines) and lines[i].strip() != ":::":
                if lines[i].strip():
                    body.append(lines[i].strip())
                i += 1
            doc["divs"][m.group(1)] = " ".join(body)
        elif line.startswith("# ") and not doc["name"]:
            doc["name"] = line[2:].strip()
        elif line:
            doc["paras"].append(line)
        i += 1
    return doc


def design_settings(settings):
    def split(key, default):
        raw = settings.get(key)
        return [s.strip().upper() for s in raw.split(",") if s.strip()] if raw else default

    return {
        "font": settings.get("font", "Inter"),
        "font_version": settings.get("font version", "5.0.18"),
        "primary": "#" + settings.get("colour primary", "1F3864").lstrip("#"),
        "accent": "#" + settings.get("colour accent", "1A7F8E").lstrip("#"),
        "accent_light": "#" + settings.get("colour accent light", "9FD3DA").lstrip("#"),
        "sidebar": split("sidebar", ["KEY NUMBERS", "CORE COMPETENCIES", "VENTURES", "GOVERNANCE", "SELECTED CLIENTS", "EDUCATION", "STATUS"]),
        "numbers": split("numbers section", ["KEY NUMBERS"]),
        "status": split("status section", ["STATUS"]),
    }


FONT_WEIGHTS = (400, 500, 600, 700, 800)


def fontsource(font, version):
    """The font's TrueType-outline webfonts from the @fontsource package on npm, cached.
    TrueType outlines matter: Chromium embeds a CFF (.otf) font as Type 3, whose text
    some CV parsers cannot extract."""
    import tarfile

    slug = font.lower().replace(" ", "-")
    cache = os.path.join(os.path.expanduser("~"), ".cache", "job-search", "fonts", f"{slug}-{version}")
    files = os.path.join(cache, "package", "files")
    if not os.path.isdir(files):
        os.makedirs(cache, exist_ok=True)
        npm = shutil.which("npm")
        if not npm:
            raise BuildError(f"npm is not installed, so the {font} webfonts (@fontsource/{slug}) cannot be fetched")
        out = run([npm, "pack", f"@fontsource/{slug}@{version}", "--silent"], cwd=cache, timeout=180).strip().splitlines()[-1]
        with tarfile.open(os.path.join(cache, out)) as t:
            try:
                t.extractall(cache, filter="data")
            except TypeError:  # Python before 3.12
                t.extractall(cache)
    found = {}
    for w in FONT_WEIGHTS:
        p = os.path.join(files, f"{slug}-latin-{w}-normal.woff2")
        if os.path.exists(p):
            found[w] = p
    if 400 not in found:
        raise BuildError(f"@fontsource/{slug}@{version} has no latin 400 webfont")
    return found


def font_faces(font, version):
    import base64

    faces = []
    for w, path in fontsource(font, version).items():
        with open(path, "rb") as f:
            data = base64.b64encode(f.read()).decode()
        faces.append(f"@font-face {{ font-family:'DocFont'; font-weight:{w}; font-style:normal; src:url(data:font/woff2;base64,{data}) format('woff2'); }}")
    return "\n".join(faces)


BASE_CSS = """
@page { size: A4; margin: 0; }
* { box-sizing:border-box; margin:0; padding:0; }
html, body { width:210mm; }
body { font-family:'DocFont', sans-serif; font-size:9.6pt; line-height:1.42; color:var(--ink);
       -webkit-print-color-adjust:exact; print-color-adjust:exact; }
ul { list-style:none; }
li { position:relative; padding-left:12px; margin-bottom:5px; break-inside:avoid; }
li::before { content:""; position:absolute; left:1px; top:0.5em; width:4.5px; height:4.5px; border-radius:50%; background:var(--accent); }
"""

CV_CSS = """
.strip { position:fixed; top:0; left:0; bottom:0; width:var(--side); background:var(--primary); z-index:-1; }
.wrap { display:grid; grid-template-columns: var(--side) 1fr; }
.side, .main { box-decoration-break:clone; -webkit-box-decoration-break:clone; }
.side { color:#fff; padding:13mm 7mm 11mm 9mm; }
.main { padding:12mm 12mm 11mm 9mm; }
.side h1 { font-size:21pt; line-height:1.05; letter-spacing:.5px; font-weight:800; }
.side .head { color:var(--accent-light); font-weight:600; font-size:10.5pt; margin-top:4px; }
.side .contact { margin-top:10px; font-size:8.3pt; color:#dfe6f0; line-height:1.6; }
.side h2 { font-size:7.8pt; letter-spacing:1.4px; text-transform:uppercase; color:var(--accent-light); margin:16px 0 6px;
           border-bottom:1px solid rgba(255,255,255,.25); padding-bottom:3px; break-after:avoid; }
.num { margin-bottom:11px; break-inside:avoid; }
.num .big { font-size:14pt; font-weight:800; line-height:1.1; margin-bottom:2.5px; }
.num .small { font-size:7.6pt; color:#c9d3e2; line-height:1.3; }
.comp { font-size:7.9pt; color:#e6ecf4; margin-bottom:7px; line-height:1.38; break-inside:avoid; }
.comp .lab { font-weight:700; color:#fff; font-size:8.1pt; }
.sp { font-size:7.9pt; color:#e6ecf4; margin-bottom:6px; line-height:1.38; break-inside:avoid; }
.side li { font-size:7.9pt; color:#e6ecf4; margin-bottom:4px; line-height:1.38; padding-left:9px; }
.side li::before { background:var(--accent-light); width:3.5px; height:3.5px; }
.status { margin-top:18px; padding-top:8px; border-top:1px solid rgba(255,255,255,.25); font-size:8.6pt; font-weight:600;
          color:#fff; line-height:1.5; break-inside:avoid; }
.main h2 { font-size:8.6pt; letter-spacing:1.4px; text-transform:uppercase; color:var(--primary); font-weight:800;
           border-bottom:1.5px solid var(--accent); padding-bottom:2px; margin:0 0 6px; break-after:avoid; }
.main p { margin-bottom:6px; }
.main .summary { font-size:9.8pt; line-height:1.48; margin-bottom:12px; }
.entry { margin-bottom:16px; }
.eline { font-weight:700; font-size:10pt; break-after:avoid; }
.eline .t { color:var(--primary); } .eline .c { color:var(--accent); } .eline .d { color:var(--grey); font-weight:500; }
.eline .sep { color:#b5bcc8; font-weight:400; }
.strap { font-style:italic; color:var(--grey); font-size:9.6pt; margin:2px 0 6px; break-after:avoid; }
"""

LETTER_CSS = """
.page { padding:18mm 20mm 16mm 20mm; }
h1 { font-size:21pt; line-height:1.05; letter-spacing:.5px; font-weight:800; color:var(--primary); }
.head { color:var(--accent); font-weight:600; font-size:10.5pt; margin-top:4px; }
.contact { margin-top:6px; font-size:8.6pt; color:var(--grey); }
.contact .sep { color:#b5bcc8; }
.rule { border-bottom:1.5px solid var(--accent); margin:10px 0 16px; }
p { font-size:10pt; line-height:1.55; margin-bottom:9px; }
"""


def root_css(d):
    return (
        f":root {{ --primary:{d['primary']}; --accent:{d['accent']}; --accent-light:{d['accent_light']}; "
        "--grey:#5A6270; --ink:#1d2330; --side:64mm; }"
    )


def html_cv(doc, d):
    sidebar = {t for t in d["sidebar"]}
    name = "<br>".join(md_inline(w) for w in doc["name"].split())
    contact = "<br>".join(md_inline(c.strip()) for c in doc["divs"].get("Contact", "").split("|") if c.strip())
    head = md_inline(doc["divs"].get("Headline", ""))

    def side_section(s):
        title = s["title"].upper()
        if title in d["status"]:
            texts = [b["text"] for b in s["blocks"] if b["type"] == "para"]
            return '<div class="status">' + "".join(f"<p>{md_inline(t)}</p>" for t in texts) + "</div>"
        out = [f"<h2>{md_inline(s['title'].title() if s['title'].isupper() else s['title'])}</h2>"]
        for b in s["blocks"]:
            if b["type"] == "label" and title in d["numbers"]:
                out.append(f'<div class="num"><div class="big">{md_inline(b["label"])}</div><div class="small">{md_inline(b["text"])}</div></div>')
            elif b["type"] == "label":
                out.append(f'<div class="comp"><div class="lab">{md_inline(b["label"])}</div><div>{md_inline(b["text"])}</div></div>')
            elif b["type"] == "bullets":
                out.extend(f'<p class="sp">{md_inline(x)}</p>' for x in b["items"])
            elif b["type"] in ("para", "div"):
                out.append(f'<p class="sp">{md_inline(b["text"])}</p>')
        return "".join(out)

    def main_section(s):
        out = [f"<h2>{md_inline(s['title'])}</h2>"]
        has_entries = any(b["type"] == "entry" for b in s["blocks"])
        for b in s["blocks"]:
            if b["type"] == "entry":
                parts = b["parts"] + [""] * (3 - len(b["parts"]))
                sep = '<span class="sep"> | </span>'
                eline = (
                    f'<h3 class="eline"><span class="t">{md_inline(parts[0])}</span>{sep}<span class="c">{md_inline(parts[1])}</span>'
                    f'{sep}<span class="d">{md_inline(" | ".join(parts[2:]).strip(" |"))}</span></h3>'
                )
                strap = f'<p class="strap">{md_inline(b["strap"])}</p>' if b["strap"] else ""
                paras = "".join(f"<p>{md_inline(p)}</p>" for p in b["paras"])
                items = "".join(f"<li>{md_inline(x)}</li>" for x in b["bullets"])
                out.append(f'<section class="entry">{eline}{strap}{paras}<ul>{items}</ul></section>')
            elif b["type"] == "bullets":
                out.append("<ul>" + "".join(f"<li>{md_inline(x)}</li>" for x in b["items"]) + "</ul>")
            elif b["type"] == "label":
                out.append(f'<p><strong>{md_inline(b["label"])}:</strong> {md_inline(b["text"])}</p>')
            else:
                cls = "" if has_entries else ' class="summary"'
                out.append(f"<p{cls}>{md_inline(b['text'])}</p>")
        return "".join(out)

    by_title = {s["title"].upper(): s for s in doc["sections"]}
    side_html = "".join(side_section(by_title[t]) for t in d["sidebar"] if t in by_title)
    main_html = "".join(main_section(s) for s in doc["sections"] if s["title"].upper() not in sidebar)
    return (
        f'<div class="strip"></div><div class="wrap"><aside class="side"><h1>{name}</h1>'
        f'<div class="head">{head}</div><div class="contact">{contact}</div>{side_html}</aside>'
        f'<main class="main">{main_html}</main></div>'
    )


def html_letter(doc, d):
    sep = '<span class="sep"> | </span>'
    contact = sep.join(md_inline(c.strip()) for c in doc["divs"].get("Contact", "").split("|") if c.strip())
    head = doc["divs"].get("Headline")
    head = f'<div class="head">{md_inline(head)}</div>' if head else ""
    paras = "".join(f"<p>{md_inline(p)}</p>" for p in doc["paras"])
    return f'<div class="page"><h1>{md_inline(doc["name"])}</h1>{head}<div class="contact">{contact}</div><div class="rule"></div>{paras}</div>'


def render_html_pdf(html_doc, pdf):
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        raise BuildError("Playwright for Python is not installed (pip install playwright), so the designed PDF cannot be printed")
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page()
        page.set_content(html_doc, wait_until="load")
        page.emulate_media(media="print")
        kw = dict(path=pdf, prefer_css_page_size=True, print_background=True)
        try:
            page.pdf(tagged=True, **kw)
        except TypeError:
            page.pdf(**kw)
        browser.close()


def pdf_raw_text(path):
    return run([need("pdftotext"), "-raw", path, "-"])


def pdf_font_types(path):
    if not shutil.which("pdffonts"):
        return None
    lines = run(["pdffonts", path]).splitlines()[2:]
    return [l for l in lines if "Type 3" in l]


def reading_order(text, wanted):
    """Each wanted line found in the extracted text, in order. Returns the first one
    out of place, or None."""
    flat = re.sub(r"\s+", " ", text)
    pos = 0
    for w in wanted:
        target = re.sub(r"\s+", " ", w).strip()
        at = flat.find(target, pos)
        if at < 0:
            return target
        pos = at + len(target)
    return None


def build_html(a, settings, checks):
    d = design_settings(settings)
    with open(a.content, encoding="utf-8") as f:
        text = f.read()
    css = font_faces(d["font"], d["font_version"]) + root_css(d) + BASE_CSS
    if a.kind == "cv":
        doc = parse_cv_markdown(text)
        body, css = html_cv(doc, d), css + CV_CSS
        in_side = set(d["sidebar"])
        order = [b["line"] for s in doc["sections"] if s["title"].upper() not in in_side for b in s["blocks"] if b["type"] == "entry"]
    else:
        doc = parse_letter_markdown(text)
        body, css = html_letter(doc, d), css + LETTER_CSS
        order = [p for p in doc["paras"]][:1] + [p for p in doc["paras"]][-1:]
    html_doc = f'<!doctype html><html lang="en-GB"><head><meta charset="utf-8"><title>{md_inline(doc["name"].title())}</title><style>{css}</style></head><body>{body}</body></html>'
    os.makedirs(a.out, exist_ok=True)
    pdf = os.path.join(a.out, a.name + ".pdf")
    render_html_pdf(html_doc, pdf)

    result = {"pdf": pdf, "engine": "html", "notes": []}
    result["pages"] = pdf_pages(pdf)
    wanted = a.pages
    if wanted is None:
        raw = settings.get(f"{a.kind} pages")
        wanted = int(raw) if raw and raw.isdigit() else None
    result["pages_wanted"] = wanted
    extracted = pdf_raw_text(pdf)
    checks_run = run_checks(checks, a.kind, [("pdf", extracted)])
    type3 = pdf_font_types(pdf)
    if type3 is None:
        result["notes"].append("pdffonts is not installed, so the embedded font types were not checked")
    else:
        checks_run.append({"label": "fonts extractable (no Type 3)", "rule": "forbid", "pattern": "Type 3", "count": len(type3), "ok": not type3, "hits": {"pdf": [{"line": 0, "count": 1, "text": l.strip()} for l in type3]} if type3 else {}})
    missing = reading_order(extracted, order)
    checks_run.append({"label": "reading order", "rule": "require", "pattern": "entries in order", "count": 0 if missing else len(order), "ok": missing is None, "hits": {"pdf": [{"line": 0, "count": 1, "text": f"not found in order: {missing}"}]} if missing else {}})
    result["checks"] = checks_run
    pages_ok = wanted is None or result["pages"] == wanted
    result["ok"] = pages_ok and all(c["ok"] for c in checks_run)
    return result


# ---------------------------------------------------------------------------
# Commands


def report(result, as_json):
    if as_json:
        print(json.dumps(result, indent=2, default=list))
        return
    for key in ("docx", "pdf"):
        if result.get(key):
            print(f"{key}: {result[key]}")
    if "pages" in result:
        want = result.get("pages_wanted")
        flag = "" if want is None else (" ok" if result["pages"] == want else f" FAIL (wanted {want})")
        print(f"pages: {result['pages']}{flag}")
    for note in result.get("notes", []):
        print(f"note: {note}")
    for c in result.get("checks", []):
        print(f"{'ok  ' if c['ok'] else 'FAIL'} {c['label']} ({c['rule']}): {c['count']} hit(s)")
        for source, hits in c["hits"].items():
            for h in hits[:20]:
                print(f"       {source}:{h['line']}: {h['text']}")
    print("PASSED" if result["ok"] else "FAILED")


def check_files(kind, checks, docx, pdf):
    sources = [("docx", docx_text(docx))]
    notes = []
    if pdf:
        text = pdf_text(pdf)
        if text is None:
            notes.append("pdftotext is not installed, so the PDF's text was not checked")
        else:
            sources.append(("pdf", text))
    results = run_checks(checks, kind, sources)
    if not checks:
        notes.append("no ```checks block in the rules, so no text checks ran")
    return results, notes


def cmd_check(a):
    _settings, checks = read_rules(a.rules)
    results, notes = check_files(a.kind, checks, a.docx, a.pdf)
    result = {"docx": a.docx, "pdf": a.pdf, "checks": results, "notes": notes, "ok": all(c["ok"] for c in results)}
    if a.pdf and a.pages is not None:
        result["pages"], result["pages_wanted"] = pdf_pages(a.pdf), a.pages
        result["ok"] = result["ok"] and result["pages"] == a.pages
    return result


def cmd_build(a):
    settings, checks = read_rules(a.rules)
    if settings.get("engine", "docx").lower() == "html" and a.kind in ("cv", "letter") and not a.no_pdf:
        return build_html(a, settings, checks)
    if not a.template:
        raise BuildError("--template is required unless the build block says engine: html")
    os.makedirs(a.out, exist_ok=True)
    docx = os.path.join(a.out, a.name + ".docx")
    run([need("pandoc"), a.content, "-f", "markdown-smart", "-o", docx, f"--reference-doc={a.template}"])

    from_template = template_bullet(a.template)
    bullet = a.bullet or settings.get("bullet") or (from_template and from_template[0]) or DEFAULT_BULLET
    indent = from_template[1:] if from_template else None
    font = body_font(a.template)
    if read_member(docx, "word/numbering.xml"):
        rewrite_zip(docx, {"word/numbering.xml": lambda x: fix_bullets(x, bullet, font, indent)})

    result = {"docx": docx, "bullet": bullet, "notes": []}
    pdf = None
    if not a.no_pdf:
        pdf = render_pdf(docx, a.out)
        result["pdf"] = pdf
        result["pages"] = pdf_pages(pdf)
    wanted = a.pages
    if wanted is None and a.kind in ("cv", "letter"):
        raw = settings.get(f"{a.kind} pages")
        wanted = int(raw) if raw and raw.isdigit() else None
    result["pages_wanted"] = wanted

    checks_run, notes = check_files(a.kind, checks, docx, pdf)
    result["checks"] = checks_run
    result["notes"] += notes
    pages_ok = wanted is None or a.no_pdf or result.get("pages") == wanted
    result["ok"] = pages_ok and all(c["ok"] for c in checks_run)
    return result


def cmd_inspect(a):
    info = inspect_docx(a.docx)
    info["ok"] = True
    return info


SPACING = {
    "body": 4.5,
    "bullet": 2.5,
    "contact": 2,
    "headline_after": 7,
    "heading_before": 9,
    "heading_after": 4.5,
    "entry_before": 6.5,
    "entry_after": 1.5,
    "strapline_after": 3,
}


def cmd_template(a):
    source = inspect_docx(a.source) if a.source else {}
    found = source.get("suggested", {})
    pick = lambda given, key, default: given if given is not None else (found.get(key) if found.get(key) is not None else default)  # noqa: E731
    opts = {
        "font": pick(a.font, "font", "Arial"),
        "size": pick(a.size, "size", 10),
        "heading_size": pick(a.heading_size, "heading_size", 12),
        "name_size": pick(a.name_size, "name_size", 16),
        "centre_name": pick(a.centre_name, "centre_name", False),
        "heading_colour": pick(a.heading_colour, "heading_colour", "000000"),
        "heading_border": pick(a.heading_border, "heading_border", True),
        "bullet": pick(a.bullet, "bullet", DEFAULT_BULLET),
        "bullet_indent": found.get("bullet_indent") or [360, 240],
        "page": a.page or found.get("page") or "a4",
        "caps": a.caps,
        "spacing": dict(SPACING),
    }
    if a.bullet_indent:
        opts["bullet_indent"] = [int(x) for x in a.bullet_indent.split(",")]
    for item in a.space or []:
        key, _, value = item.partition("=")
        if key not in SPACING:
            raise BuildError(f"--space {key}: one of {', '.join(SPACING)}")
        opts["spacing"][key] = float(value)
    if opts["page"] == "custom":
        opts["page"] = source["page_twips"]
    margins = {} if a.margin is not None else (found.get("margins_twips") or {})
    default = a.margin if a.margin is not None else 1080
    opts["margins"] = {k: margins.get(k, default) for k in ("top", "right", "bottom", "left")}
    make_template(a.out, opts)
    return {"template": a.out, "settings": opts, "ok": True}


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--json", action="store_true", help="print the report as JSON")
    sub = p.add_subparsers(dest="cmd", required=True)

    b = sub.add_parser("build", help="markdown + template -> .docx and .pdf, then the checks")
    b.add_argument("content")
    b.add_argument("--kind", choices=KINDS, required=True)
    b.add_argument("--template", help="the .docx style template; not needed with engine: html")
    b.add_argument("--rules", help="the Writing Rules page, saved as markdown")
    b.add_argument("--out", required=True)
    b.add_argument("--name", required=True, help="file name without extension")
    b.add_argument("--bullet", help="overrides the rules and the template")
    b.add_argument("--pages", type=int, help="the page count the PDF must have")
    b.add_argument("--no-pdf", action="store_true")

    c = sub.add_parser("check", help="run the checks on built files")
    c.add_argument("docx")
    c.add_argument("pdf", nargs="?")
    c.add_argument("--kind", choices=KINDS, required=True)
    c.add_argument("--rules", required=True)
    c.add_argument("--pages", type=int)

    i = sub.add_parser("inspect", help="a .docx's page setup, fonts, sizes, colours and bullets")
    i.add_argument("docx")

    t = sub.add_parser("template", help="make a style template")
    t.add_argument("--out", required=True)
    t.add_argument("--from", dest="source", help="a CV to take the look from")
    t.add_argument("--font")
    t.add_argument("--size", type=float, help="body size, pt")
    t.add_argument("--heading-size", type=float, help="section heading size, pt")
    t.add_argument("--name-size", type=float, help="the name at the top, pt")
    t.add_argument("--heading-colour", help="hex, e.g. 1F3864")
    t.add_argument("--heading-border", action=argparse.BooleanOptionalAction, default=None)
    t.add_argument("--caps", action=argparse.BooleanOptionalAction, default=True, help="section headings in capitals")
    t.add_argument("--centre-name", action=argparse.BooleanOptionalAction, default=None, help="name, contact and headline centred")
    t.add_argument("--bullet")
    t.add_argument("--bullet-indent", help="LEFT,HANGING in twips, e.g. 260,200")
    t.add_argument("--page", choices=("a4", "letter"))
    t.add_argument("--margin", type=int, help="all four margins, in twips (1440 = 1 inch)")
    t.add_argument("--space", action="append", metavar="KEY=PT", help=f"paragraph spacing in points; keys: {', '.join(SPACING)}")

    a = p.parse_args(argv)
    handlers = {"build": cmd_build, "check": cmd_check, "inspect": cmd_inspect, "template": cmd_template}
    try:
        result = handlers[a.cmd](a)
    except BuildError as e:
        if a.json:
            print(json.dumps({"ok": False, "error": str(e)}))
        else:
            print(f"error: {e}", file=sys.stderr)
        return 2
    if a.cmd in ("inspect", "template"):
        print(json.dumps(result, indent=2, default=list))
    else:
        report(result, a.json)
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
