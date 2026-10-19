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
            font = f.group(1) if f else (style_value(table, pstyle, "font") or (d_font.group(1) if d_font else "(theme)"))
            sz = re.search(r'<w:sz w:val="(\d+)"', rpr)
            half = int(sz.group(1)) if sz else int(style_value(table, pstyle, "sz") or (d_sz.group(1) if d_sz else WORD_DEFAULT_HALF_POINTS))
            size = half / 2
            fonts[font] += n
            sizes[size] += n
            if re.search(r'<w:b(?:\s*/>|\s+w:val="(?:1|true|on)")', rpr):
                bold_sizes[size] += n
            c = re.search(r'<w:color w:val="([0-9A-Fa-f]{6})"', rpr)
            if c and c.group(1).upper() != "000000":
                colours[c.group(1).upper()] += n
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
    b.add_argument("--template", required=True)
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
