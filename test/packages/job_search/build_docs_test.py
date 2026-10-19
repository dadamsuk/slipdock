"""Tests for the job-search Tool's build script (#1151).

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


if __name__ == "__main__":
    for tool in ("pandoc", "soffice", "pdfinfo"):
        if not shutil.which(tool):
            print(f"note: {tool} is not installed; the tests that need it are skipped", file=sys.stderr)
    unittest.main(verbosity=1)
