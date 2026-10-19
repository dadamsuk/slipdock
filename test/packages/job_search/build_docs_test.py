"""Tests for the job-search Tool's build script (#1151, the html engine #1164).

Run: python3 test/packages/job_search/build_docs_test.py
(test/slipdock/job_search_build_docs_test.exs runs it with the suite.)

The parsing, checks and .docx surgery need nothing but Python. The tests that
call pandoc or LibreOffice are skipped where those are not installed, and say so.
"""

import contextlib
import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile
import unittest
import zipfile

# No __pycache__ beside the script: the package folder is published as it stands.
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(
    HERE, "..", "..", "..", "packages", "job-search", "skills", "job-search-generate", "scripts", "build_docs.py"
)

spec = importlib.util.spec_from_file_location("build_docs", SCRIPT)
bd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bd)

RULES = """# Writing Rules

Some prose the script ignores, with a | pipe in it.

```build
bullet: -
cv pages: 2
```

```checks
# a comment line
forbid all | third person | \\b(he|his|him)\\b
forbid cv | verbs | (?-i:\\b(owns|leads)\\b)
require letter | first person | \\b(I|my)\\b
max 1 all | antithesis | \\brather than\\b
forbid all | em dashes | \u2014
```
"""

W = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'


def make_docx(path, document_body, styles="", numbering=None, sect=""):
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("[Content_Types].xml", "<Types/>")
        z.writestr("word/document.xml", f"<w:document {W}><w:body>{document_body}{sect}</w:body></w:document>")
        z.writestr("word/styles.xml", f"<w:styles {W}>{styles}</w:styles>")
        if numbering is not None:
            z.writestr("word/numbering.xml", f"<w:numbering {W}>{numbering}</w:numbering>")


def run_main(*args):
    out = io.StringIO()
    err = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = bd.main(list(args))
    return code, out.getvalue(), err.getvalue()


class Rules(unittest.TestCase):
    def test_reads_the_build_block(self):
        self.assertEqual(bd.parse_settings(RULES), {"bullet": "-", "cv pages": "2"})

    def test_reads_every_check_and_skips_comments(self):
        checks = bd.parse_checks(RULES)
        self.assertEqual([c["label"] for c in checks], ["third person", "verbs", "first person", "antithesis", "em dashes"])
        self.assertEqual(checks[0]["kinds"], {"all"})
        self.assertEqual(checks[2]["rule"], "require")
        self.assertEqual((checks[3]["rule"], checks[3]["limit"]), ("max", 1))

    def test_no_blocks_means_no_checks(self):
        self.assertEqual(bd.parse_checks("# Writing Rules\n\nnothing here\n"), [])
        self.assertEqual(bd.parse_settings("nothing"), {})

    def test_a_malformed_line_is_an_error_not_a_skip(self):
        for line, says in [
            ("forbid all third person", "expected"),
            ("ban all | x | y", "rule must be"),
            ("forbid memo | x | y", "unknown document kind memo"),
            ("forbid all | x | (unclosed", "bad pattern"),
        ]:
            with self.subTest(line=line):
                with self.assertRaises(bd.BuildError) as e:
                    bd.parse_checks(f"```checks\n{line}\n```\n")
                self.assertIn(says, str(e.exception))


class Checks(unittest.TestCase):
    checks = bd.parse_checks(RULES)

    def by_label(self, results):
        return {r["label"]: r for r in results}

    def test_a_clean_cv_passes_and_letter_only_checks_do_not_run(self):
        results = self.by_label(bd.run_checks(self.checks, "cv", [("docx", "Built the team.\nGrew revenue.")]))
        self.assertNotIn("first person", results)
        self.assertTrue(all(r["ok"] for r in results.values()))

    def test_a_forbidden_word_fails_with_its_line(self):
        results = self.by_label(bd.run_checks(self.checks, "cv", [("docx", "Built the team.\nHe grew revenue.")]))
        third = results["third person"]
        self.assertFalse(third["ok"])
        self.assertEqual(third["count"], 1)
        self.assertEqual(third["hits"]["docx"], [{"line": 2, "count": 1, "text": "He grew revenue."}])

    def test_require_fails_on_no_hits(self):
        results = self.by_label(bd.run_checks(self.checks, "letter", [("docx", "Dear Sir,\nThe role appeals.")]))
        self.assertFalse(results["first person"]["ok"])
        results = self.by_label(bd.run_checks(self.checks, "letter", [("docx", "Dear Sir,\nI applied.")]))
        self.assertTrue(results["first person"]["ok"])

    def test_max_allows_up_to_its_limit(self):
        one = self.by_label(bd.run_checks(self.checks, "other", [("docx", "this rather than that")]))
        two = self.by_label(bd.run_checks(self.checks, "other", [("docx", "this rather than that\nX rather than Y")]))
        self.assertTrue(one["antithesis"]["ok"])
        self.assertFalse(two["antithesis"]["ok"])
        self.assertEqual(two["antithesis"]["count"], 2)

    def test_patterns_are_case_insensitive_unless_marked(self):
        results = self.by_label(bd.run_checks(self.checks, "cv", [("docx", "OWNS the roadmap\nHIS team")]))
        self.assertTrue(results["verbs"]["ok"], "(?-i:...) keeps a pattern case-sensitive")
        self.assertFalse(results["third person"]["ok"])
        results = self.by_label(bd.run_checks(self.checks, "cv", [("docx", "owns the roadmap")]))
        self.assertFalse(results["verbs"]["ok"])

    def test_a_forbid_hit_only_the_pdf_shows_still_fails(self):
        results = self.by_label(
            bd.run_checks(self.checks, "cv", [("docx", "Built it - fast"), ("pdf", "Built it \u2014 fast")])
        )
        self.assertFalse(results["em dashes"]["ok"])
        self.assertIn("pdf", results["em dashes"]["hits"])


NUMBERING = (
    '<w:abstractNum w:abstractNumId="7">'
    '<w:lvl w:ilvl="0"><w:numFmt w:val="bullet" /><w:lvlText w:val="\u2022" /><w:pPr><w:tabs><w:tab w:val="num" w:pos="0" /></w:tabs>'
    '<w:ind w:left="480" w:hanging="480" /></w:pPr><w:rPr><w:rFonts w:ascii="Symbol" w:hAnsi="Symbol" /></w:rPr></w:lvl>'
    '<w:lvl w:ilvl="1"><w:numFmt w:val="bullet" /><w:lvlText w:val="\u25e6" /><w:pPr><w:ind w:left="1200" w:hanging="480" /></w:pPr></w:lvl>'
    "</w:abstractNum>"
    '<w:abstractNum w:abstractNumId="8"><w:lvl w:ilvl="0"><w:numFmt w:val="decimal" /><w:lvlText w:val="%1." /></w:lvl></w:abstractNum>'
    '<w:abstractNum w:abstractNumId="9"><w:lvl w:ilvl="0"><w:numFmt w:val="bullet" /><w:lvlText w:val="-" />'
    '<w:pPr><w:ind w:left="260" w:hanging="200" /></w:pPr></w:lvl></w:abstractNum>'
    '<w:num w:numId="1"><w:abstractNumId w:val="7" /></w:num>'
    '<w:num w:numId="2"><w:abstractNumId w:val="9" /></w:num>'
)


class Bullets(unittest.TestCase):
    def test_every_bullet_level_gets_the_character_and_numbered_lists_are_left_alone(self):
        xml = bd.fix_bullets(NUMBERING, "-", "Arial")
        self.assertNotIn("\u2022", xml)
        self.assertNotIn("\u25e6", xml)
        self.assertNotIn("Symbol", xml)
        self.assertEqual(xml.count('<w:lvlText w:val="-" />'), 3)
        self.assertIn('<w:lvlText w:val="%1." />', xml)
        self.assertIn('<w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:cs="Arial" />', xml)

    def test_an_indent_steps_in_per_level(self):
        xml = bd.fix_bullets(NUMBERING, "-", None, (260, 200))
        self.assertIn('<w:ind w:left="260" w:hanging="200" />', xml)
        self.assertIn('<w:ind w:left="520" w:hanging="200" />', xml)
        self.assertNotIn("<w:tabs>", xml)

    def test_a_character_xml_cares_about_is_escaped(self):
        xml = bd.fix_bullets(NUMBERING, '"&', None)
        self.assertIn('<w:lvlText w:val="&quot;&amp;" />', xml)

    def test_bullet_levels_puts_the_lists_in_use_first(self):
        self.assertEqual(bd.bullet_levels(NUMBERING)[0], ("\u2022", 480, 480))
        self.assertEqual(bd.bullet_levels(NUMBERING, ["2", "2", "1"])[0], ("-", 260, 200))
        self.assertEqual(bd.bullet_levels(""), [])


class Inspect(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)

    def cv(self):
        run = lambda text, rpr="": f"<w:r><w:rPr>{rpr}</w:rPr><w:t>{text}</w:t></w:r>"  # noqa: E731
        arial = '<w:rFonts w:ascii="Arial" w:hAnsi="Arial" />'
        body = (
            f'<w:p><w:pPr><w:jc w:val="center" /></w:pPr>{run("JANE DOE", arial + "<w:b /><w:color w:val=\"1F3864\" /><w:sz w:val=\"32\" />")}</w:p>'
            f'<w:p><w:pPr><w:pBdr><w:bottom w:val="single" /></w:pBdr></w:pPr>{run("EXPERIENCE", arial + "<w:b /><w:color w:val=\"1F3864\" /><w:sz w:val=\"24\" />")}</w:p>'
            + "".join(
                f'<w:p><w:pPr><w:numPr><w:ilvl w:val="0" /><w:numId w:val="2" /></w:numPr></w:pPr>{run("A long line of body text that sets the body size by volume.", arial)}</w:p>'
                for _ in range(5)
            )
        )
        sect = '<w:sectPr><w:pgSz w:w="11906" w:h="16838" /><w:pgMar w:top="1080" w:right="1080" w:bottom="1080" w:left="1080" /></w:sectPr>'
        path = os.path.join(self.tmp, "cv.docx")
        make_docx(path, body, '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal" /></w:style>', NUMBERING, sect)
        return path

    def test_reads_page_fonts_sizes_colour_and_the_bullet_in_use(self):
        found = bd.inspect_docx(self.cv())["suggested"]
        self.assertEqual(found["page"], "a4")
        self.assertEqual(found["margins_twips"], {"top": 1080, "right": 1080, "bottom": 1080, "left": 1080})
        self.assertEqual(found["font"], "Arial")
        self.assertEqual(found["size"], 10.0, "a run with no size anywhere is Word's 10pt")
        self.assertEqual(found["heading_size"], 12.0)
        self.assertEqual(found["name_size"], 16.0)
        self.assertTrue(found["centre_name"])
        self.assertEqual(found["heading_colour"], "1F3864")
        self.assertTrue(found["heading_border"])
        self.assertEqual(found["bullet"], "-")
        self.assertEqual(found["bullet_indent"], [260, 200])

    def test_size_comes_from_the_style_chain(self):
        styles = (
            '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:rPr><w:sz w:val="22" /></w:rPr></w:style>'
            '<w:style w:type="paragraph" w:styleId="Big"><w:basedOn w:val="Normal" /><w:rPr><w:sz w:val="40" /></w:rPr></w:style>'
            '<w:style w:type="paragraph" w:styleId="Child"><w:basedOn w:val="Big" /></w:style>'
        )
        body = (
            '<w:p><w:r><w:t>body text that is long enough to be the body</w:t></w:r></w:p>'
            '<w:p><w:pPr><w:pStyle w:val="Child" /></w:pPr><w:r><w:t>big</w:t></w:r></w:p>'
        )
        path = os.path.join(self.tmp, "styled.docx")
        make_docx(path, body, styles)
        sizes = dict(bd.inspect_docx(path)["sizes_pt"])
        self.assertEqual(sizes, {11.0: 44, 20.0: 3})

    def test_bold_and_colour_come_through_styles_and_a_theme_font_is_unknown(self):
        styles = (
            '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:rPr><w:rFonts w:asciiTheme="minorHAnsi" /></w:rPr></w:style>'
            '<w:style w:type="paragraph" w:styleId="Heading2"><w:basedOn w:val="Normal" />'
            '<w:rPr><w:b /><w:color w:val="336699" /><w:sz w:val="28" /></w:rPr></w:style>'
        )
        body = (
            '<w:p><w:r><w:rPr><w:sz w:val="36" /></w:rPr><w:t>JANE DOE</w:t></w:r></w:p>'
            '<w:p><w:pPr><w:pStyle w:val="Heading2" /></w:pPr><w:r><w:t>SECTION</w:t></w:r></w:p>'
            + '<w:p><w:r><w:t>plain body text, long enough to be the body size</w:t></w:r></w:p>' * 3
        )
        path = os.path.join(self.tmp, "themed.docx")
        make_docx(path, body, styles)
        info = bd.inspect_docx(path)
        self.assertEqual(info["fonts"], [], "a theme font has no name to suggest")
        self.assertIsNone(info["suggested"]["font"])
        self.assertEqual(info["suggested"]["heading_size"], 14.0)
        self.assertEqual(info["suggested"]["heading_colour"], "336699")
        self.assertEqual(info["suggested"]["name_size"], 18.0)
        code, out, _ = run_main("template", "--from", path, "--out", os.path.join(self.tmp, "t.docx")) if shutil.which("pandoc") else (0, '{"settings": {"font": "Arial"}}', "")
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out)["settings"]["font"], "Arial", "falls back rather than naming a font '(theme)'")

    def test_not_a_docx_is_an_error(self):
        path = os.path.join(self.tmp, "x.docx")
        with zipfile.ZipFile(path, "w") as z:
            z.writestr("hello.txt", "hi")
        with self.assertRaises(bd.BuildError):
            bd.inspect_docx(path)
        code, _, err = run_main("inspect", path)
        self.assertEqual(code, 2)
        self.assertIn("is not a .docx", err)


@unittest.skipUnless(shutil.which("pandoc"), "pandoc is not installed")
class WithPandoc(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        self.template = os.path.join(self.tmp, "t.docx")
        self.rules = os.path.join(self.tmp, "rules.md")
        with open(self.rules, "w") as f:
            f.write(RULES)
        code, out, _ = run_main(
            "template", "--out", self.template, "--font", "Arial", "--heading-colour", "1F3864",
            "--bullet", "-", "--bullet-indent", "260,200", "--centre-name", "--space", "bullet=3",
        )
        self.assertEqual(code, 0)
        self.settings = json.loads(out)["settings"]

    def md(self, text, name="in.md"):
        path = os.path.join(self.tmp, name)
        with open(path, "w") as f:
            f.write(text)
        return path

    def test_the_template_carries_the_look(self):
        styles = bd.read_member(self.template, "word/styles.xml")
        self.assertIn('w:ascii="Arial"', styles)
        self.assertIn('<w:color w:val="1F3864" />', styles)
        for style in ("Heading1", "Heading2", "Heading3", "Contact", "Headline", "Strapline"):
            self.assertIn(f'w:styleId="{style}"', styles)
        self.assertIn('<w:spacing w:before="0" w:after="60" />', styles, "--space bullet=3 is 60 twips")
        document = bd.read_member(self.template, "word/document.xml")
        self.assertIn('<w:pgSz w:w="11906" w:h="16838" />', document)
        self.assertEqual(document.count("<w:sectPr"), 1)
        self.assertEqual(bd.template_bullet(self.template), ("-", 260, 200))
        self.assertEqual(self.settings["spacing"]["bullet"], 3.0)

    def test_an_unknown_spacing_key_is_refused(self):
        code, _, err = run_main("template", "--out", os.path.join(self.tmp, "x.docx"), "--space", "gutter=3")
        self.assertEqual(code, 2)
        self.assertIn("--space gutter", err)

    def test_build_puts_the_bullet_back_and_passes_clean_text(self):
        content = self.md(
            '# Jane Doe\n\n::: {custom-style="Contact"}\nphone | email\n:::\n\n## Experience\n\n'
            "### Head of Things | Acme | 2019 to 2026\n\n- Built the team.\n- Grew revenue.\n"
        )
        code, out, _ = run_main(
            "--json", "build", content, "--kind", "cv", "--template", self.template, "--rules", self.rules,
            "--out", os.path.join(self.tmp, "out"), "--name", "cv", "--no-pdf",
        )
        result = json.loads(out)
        self.assertEqual(code, 0, out)
        self.assertTrue(result["ok"])
        self.assertEqual(result["bullet"], "-")
        numbering = bd.read_member(result["docx"], "word/numbering.xml")
        self.assertIn('<w:lvlText w:val="-" />', numbering)
        self.assertNotIn("\u2022", numbering)
        self.assertIn('<w:ind w:left="260" w:hanging="200" />', numbering)
        document = bd.read_member(result["docx"], "word/document.xml")
        self.assertIn('w:val="Contact"', document)

    def test_build_fails_on_a_check_and_names_the_line(self):
        content = self.md("# Jane Doe\n\nHe owns the roadmap.\n")
        code, out, _ = run_main(
            "build", content, "--kind", "cv", "--template", self.template, "--rules", self.rules,
            "--out", os.path.join(self.tmp, "out"), "--name", "cv", "--no-pdf",
        )
        self.assertEqual(code, 1)
        self.assertIn("FAIL third person (forbid): 1 hit(s)", out)
        self.assertIn("FAIL verbs (forbid): 1 hit(s)", out)
        self.assertIn("He owns the roadmap.", out)
        self.assertTrue(out.rstrip().endswith("FAILED"))

    def test_check_runs_on_a_built_file(self):
        content = self.md("Dear Sam,\n\nThe role appeals.\n")
        run_main(
            "build", content, "--kind", "letter", "--template", self.template, "--out",
            os.path.join(self.tmp, "out"), "--name", "letter", "--no-pdf",
        )
        docx = os.path.join(self.tmp, "out", "letter.docx")
        code, out, _ = run_main("check", docx, "--kind", "letter", "--rules", self.rules)
        self.assertEqual(code, 1)
        self.assertIn("FAIL first person (require): 0 hit(s)", out)

    def test_bad_rules_stop_the_build(self):
        rules = self.md("```checks\nforbid all he\n```\n", "bad.md")
        code, out, _ = run_main(
            "--json", "build", self.md("x\n"), "--kind", "cv", "--template", self.template, "--rules", rules,
            "--out", self.tmp, "--name", "x", "--no-pdf",
        )
        self.assertEqual(code, 2)
        self.assertFalse(json.loads(out)["ok"])

    @unittest.skipUnless(shutil.which("soffice") and shutil.which("pdfinfo"), "LibreOffice or poppler is not installed")
    def test_the_pdf_is_rendered_and_its_pages_counted_against_the_rules(self):
        short = self.md("# Jane Doe\n\nBuilt the team.\n")
        code, out, _ = run_main(
            "--json", "build", short, "--kind", "cv", "--template", self.template, "--rules", self.rules,
            "--out", os.path.join(self.tmp, "out"), "--name", "short",
        )
        result = json.loads(out)
        self.assertTrue(os.path.exists(result["pdf"]))
        self.assertEqual(result["pages"], 1)
        self.assertEqual(result["pages_wanted"], 2, "cv pages comes from the build block")
        self.assertFalse(result["ok"])
        self.assertEqual(code, 1)
        code, out, _ = run_main(
            "--json", "build", short, "--kind", "cv", "--template", self.template, "--rules", self.rules,
            "--out", os.path.join(self.tmp, "out"), "--name", "short", "--pages", "1",
        )
        self.assertEqual(code, 0, out)
        self.assertEqual(bd.pdf_pages(json.loads(out)["pdf"]), 1)


HTML_RULES = """# Writing Rules

```build
engine: html
cv pages: 2
letter pages: 1
sidebar: key numbers, status
colour primary: #112233
```

```checks
forbid all | em dashes | —
```
"""

CV_MD = """# Jane Doe

::: {custom-style="Contact"}
London | jane@example.com
:::

::: {custom-style="Headline"}
Chief Technology Officer
:::

## Summary

Builds teams that ship & <keeps> them.

## Key Numbers

**40:** engineers led
**12m:** **raised** in funding

## Experience

### CTO | Acme | 2019 to 2026

::: {custom-style="Strapline"}
Series B fintech
:::

- Built the team.
- Grew revenue.

### Head of Things | Beta | 2015 to 2019

- Ran the platform.

## Status

Available from January.
"""

LETTER_MD = """# Jane Doe

::: {custom-style="Contact"}
London | jane@example.com
:::

Dear Sam,

I would like to apply.

Yours sincerely,
"""


class HtmlEngine(unittest.TestCase):
    """The designed PDF (`engine: html`, #1164). Chromium is stubbed out except in the
    one test that prints for real, which is skipped where Playwright is not installed."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        self.rules = self.write("rules.md", HTML_RULES)
        self.settings, _ = bd.read_rules(self.rules)
        self.d = bd.design_settings(self.settings)

    def write(self, name, text):
        path = os.path.join(self.tmp, name)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        return path

    def stub(self, name, value):
        original = getattr(bd, name)
        setattr(bd, name, value)
        self.addCleanup(setattr, bd, name, original)

    def home_here(self):
        """The font cache lives under ~, so point ~ at the test's own folder."""
        old = os.environ.get("HOME")
        os.environ["HOME"] = self.tmp
        self.addCleanup(lambda: os.environ.__setitem__("HOME", old) if old is not None else os.environ.pop("HOME"))

    def stub_printing(self, pages=2, text=None, type3=()):
        printed = {}

        def render(html_doc, pdf):
            printed["html"] = html_doc
            with open(pdf, "wb") as f:
                f.write(b"%PDF-1.7")

        self.stub("font_faces", lambda font, version: "")
        self.stub("render_html_pdf", render)
        self.stub("pdf_pages", lambda path: pages)
        self.stub("pdf_raw_text", lambda path: text if text is not None else "CTO | Acme | 2019 to 2026 x Head of Things | Beta | 2015 to 2019")
        self.stub("pdf_font_types", lambda path: None if type3 is None else list(type3))
        return printed

    def build(self, kind, content, *extra):
        code, out, _ = run_main(
            "--json", "build", self.write(f"{kind}.md", content), "--kind", kind, "--rules", self.rules,
            "--out", os.path.join(self.tmp, "out"), "--name", kind, *extra,
        )
        return code, json.loads(out)

    def test_the_cv_markdown_is_read_as_structure(self):
        doc = bd.parse_cv_markdown(CV_MD)
        self.assertEqual(doc["name"], "Jane Doe")
        self.assertEqual(doc["divs"], {"Contact": "London | jane@example.com", "Headline": "Chief Technology Officer"})
        self.assertEqual([s["title"] for s in doc["sections"]], ["Summary", "Key Numbers", "Experience", "Status"])
        numbers = doc["sections"][1]["blocks"]
        self.assertEqual([(b["type"], b["label"]) for b in numbers], [("label", "40"), ("label", "12m")])
        cto, head = doc["sections"][2]["blocks"]
        self.assertEqual(cto["parts"], ["CTO", "Acme", "2019 to 2026"])
        self.assertEqual(cto["strap"], "Series B fintech", "a Strapline under an entry belongs to the entry")
        self.assertEqual(cto["bullets"], ["Built the team.", "Grew revenue."])
        self.assertEqual(head["bullets"], ["Ran the platform."])

    def test_the_letter_is_its_name_divs_and_paragraphs(self):
        doc = bd.parse_letter_markdown(LETTER_MD)
        self.assertEqual(doc["name"], "Jane Doe")
        self.assertEqual(doc["divs"], {"Contact": "London | jane@example.com"})
        self.assertEqual(doc["paras"], ["Dear Sam,", "I would like to apply.", "Yours sincerely,"])

    def test_design_settings_have_defaults_and_take_overrides(self):
        self.assertEqual(self.d["primary"], "#112233", "a leading # is not doubled")
        self.assertEqual(self.d["accent"], "#1A7F8E")
        self.assertEqual(self.d["sidebar"], ["KEY NUMBERS", "STATUS"])
        self.assertEqual(self.d["font"], "Inter")
        defaults = bd.design_settings({})
        self.assertIn("SELECTED CLIENTS", defaults["sidebar"])
        self.assertEqual(defaults["numbers"], ["KEY NUMBERS"])

    def test_the_cv_puts_sidebar_sections_in_the_bar_and_escapes_text(self):
        html_doc = bd.html_cv(bd.parse_cv_markdown(CV_MD), self.d)
        side, main = html_doc.split('<main class="main">')
        self.assertIn('<div class="num"><div class="big">40</div><div class="small">engineers led</div></div>', side)
        self.assertIn('<div class="status"><p>Available from January.</p></div>', side)
        self.assertNotIn("Experience", side)
        self.assertNotIn("Key Numbers", main)
        self.assertIn('<p class="summary">Builds teams that ship &amp; &lt;keeps&gt; them.</p>', main)
        self.assertIn("<strong>raised</strong>", side)
        self.assertIn('<span class="c">Acme</span>', main)
        self.assertIn('<p class="strap">Series B fintech</p>', main)
        self.assertLess(main.index("Acme"), main.index("Beta"), "entries keep their order")
        self.assertIn("Jane<br>Doe", side)

    def test_the_letter_has_no_headline_unless_given_one(self):
        doc = bd.parse_letter_markdown(LETTER_MD)
        html_doc = bd.html_letter(doc, self.d)
        self.assertNotIn('class="head"', html_doc)
        self.assertIn('London<span class="sep"> | </span>jane@example.com', html_doc)
        doc["divs"]["Headline"] = "CTO"
        self.assertIn('<div class="head">CTO</div>', bd.html_letter(doc, self.d))

    def test_reading_order_names_the_first_entry_out_of_place(self):
        text = "CTO  | Acme\n| 2019 to 2026 then Head of Things"
        self.assertIsNone(bd.reading_order(text, ["CTO | Acme | 2019 to 2026", "Head of Things"]))
        self.assertEqual(bd.reading_order(text, ["Head of Things", "CTO | Acme | 2019 to 2026"]), "CTO | Acme | 2019 to 2026")
        self.assertEqual(bd.reading_order(text, ["Missing"]), "Missing")

    def test_without_engine_html_a_template_is_still_required(self):
        rules = self.write("docx-rules.md", "```build\ncv pages: 2\n```\n")
        code, out, _ = run_main("--json", "build", self.write("cv.md", CV_MD), "--kind", "cv", "--rules", rules, "--out", self.tmp, "--name", "cv")
        self.assertEqual(code, 2)
        self.assertIn("--template is required", json.loads(out)["error"])

    def test_a_cv_build_makes_only_a_pdf_and_passes_its_checks(self):
        printed = self.stub_printing()
        code, result = self.build("cv", CV_MD)
        self.assertEqual(code, 0, result)
        self.assertEqual(result["engine"], "html")
        self.assertNotIn("docx", result)
        self.assertEqual(os.listdir(os.path.join(self.tmp, "out")), ["cv.pdf"])
        self.assertEqual(result["pages_wanted"], 2, "cv pages comes from the build block")
        labels = {c["label"]: c["ok"] for c in result["checks"]}
        self.assertEqual(labels, {"em dashes": True, "fonts extractable (no Type 3)": True, "reading order": True})
        self.assertIn('<html lang="en-GB">', printed["html"])
        self.assertIn("--primary:#112233", printed["html"])

    def test_the_wrong_page_count_fails_the_build(self):
        self.stub_printing(pages=3)
        code, result = self.build("cv", CV_MD)
        self.assertEqual(code, 1)
        self.assertEqual(result["pages"], 3)
        self.assertFalse(result["ok"])
        code, result = self.build("cv", CV_MD, "--pages", "3")
        self.assertEqual(code, 0, "--pages overrides the build block")

    def test_a_type_3_font_fails_the_build(self):
        self.stub_printing(type3=["Inter  Type 3  Custom  yes yes no 5 0"])
        code, result = self.build("cv", CV_MD)
        self.assertEqual(code, 1)
        fonts = next(c for c in result["checks"] if c["label"].startswith("fonts"))
        self.assertFalse(fonts["ok"])
        self.assertIn("Type 3", fonts["hits"]["pdf"][0]["text"])

    def test_entries_out_of_order_in_the_pdf_text_fail_the_build(self):
        self.stub_printing(text="Head of Things | Beta | 2015 to 2019 then CTO | Acme | 2019 to 2026")
        code, result = self.build("cv", CV_MD)
        self.assertEqual(code, 1)
        order = next(c for c in result["checks"] if c["label"] == "reading order")
        self.assertIn("not found in order: Head of Things", order["hits"]["pdf"][0]["text"])

    def test_a_forbidden_word_in_the_pdf_text_fails_the_build(self):
        self.stub_printing(text="CTO | Acme | 2019 to 2026 — Head of Things | Beta | 2015 to 2019")
        code, result = self.build("cv", CV_MD)
        self.assertEqual(code, 1)
        self.assertFalse(next(c for c in result["checks"] if c["label"] == "em dashes")["ok"])

    def test_without_pdffonts_the_font_check_is_a_note_not_a_failure(self):
        self.stub_printing(type3=None)
        code, result = self.build("cv", CV_MD)
        self.assertEqual(code, 0, result)
        self.assertTrue(any("pdffonts is not installed" in n for n in result["notes"]))

    def test_a_letter_checks_its_first_and_last_paragraph_and_one_page(self):
        self.stub_printing(pages=1, text="Dear Sam, I would like to apply. Yours sincerely,")
        code, result = self.build("letter", LETTER_MD)
        self.assertEqual(code, 0, result)
        self.assertEqual(result["pages_wanted"], 1)
        self.stub_printing(pages=1, text="Yours sincerely, Dear Sam,")
        code, result = self.build("letter", LETTER_MD)
        self.assertEqual(code, 1)

    def test_no_npm_and_no_cached_font_is_an_error_naming_the_font(self):
        self.home_here()
        real_which = shutil.which
        bd.shutil.which = lambda cmd, *a, **k: None if cmd == "npm" else real_which(cmd, *a, **k)
        self.addCleanup(setattr, bd.shutil, "which", real_which)
        with self.assertRaises(bd.BuildError) as e:
            bd.fontsource("Inter", "5.0.18")
        self.assertIn("@fontsource/inter", str(e.exception))

    def test_a_cached_font_without_a_regular_weight_is_refused(self):
        self.home_here()
        files = os.path.join(self.tmp, ".cache", "job-search", "fonts", "inter-5.0.18", "package", "files")
        os.makedirs(files)
        self.write(os.path.join(files, "inter-latin-700-normal.woff2"), "x")
        with self.assertRaises(bd.BuildError) as e:
            bd.fontsource("Inter", "5.0.18")
        self.assertIn("no latin 400", str(e.exception))
        self.write(os.path.join(files, "inter-latin-400-normal.woff2"), "x")
        self.assertEqual(sorted(bd.fontsource("Inter", "5.0.18")), [400, 700])

    @unittest.skipUnless(
        importlib.util.find_spec("playwright") and shutil.which("pdfinfo") and shutil.which("pdftotext"),
        "Playwright or poppler is not installed",
    )
    def test_chromium_prints_the_cv_for_real(self):
        self.stub("font_faces", lambda font, version: "")
        code, result = self.build("cv", CV_MD, "--pages", "1")
        self.assertEqual(code, 0, result)
        self.assertEqual(bd.pdf_pages(result["pdf"]), 1)


if __name__ == "__main__":
    for tool in ("pandoc", "soffice", "pdfinfo"):
        if not shutil.which(tool):
            print(f"note: {tool} is not installed; the tests that need it are skipped", file=sys.stderr)
    unittest.main(verbosity=1)
