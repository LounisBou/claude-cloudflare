#!/usr/bin/env python3
"""Cases of the Caddyfile parser and its edits, for tests/run-tests.sh.

Each case is a Caddyfile written inline, put through caddy-site-set's edit
(set_site, the body as body() makes it) and caddy-site-remove's (remove_site).
One line per check: name<TAB>expected<TAB>actual, both as repr(); a refused
edit gives the name and exit code of its error.

    caddyfile-cases.py <engine dir>
"""

import sys

sys.path.insert(0, sys.argv[1])

from cflib import caddyfile, errors  # noqa: E402

BODY = caddyfile.body("respond x")


def outcome(edit, *args):
    try:
        return edit(*args)
    except errors.CfError as exc:
        return "%s %d" % (type(exc).__name__, exc.code)


def check(name, expected, actual):
    print("%s\t%r\t%r" % (name, expected, actual))


def block(host, line, nl="\n"):
    return "%s {%s\t%s%s}%s" % (host, nl, line, nl, nl)


P = block("p.example.com", "respond p")
Q = block("q.example.com", "respond q")
X = "\trespond x\n"


def around(name, a):
    """A block for a.example.com between two plain ones: set and remove of
    its neighbour leave it whole, set and remove of it take it whole."""
    text = P + "\n" + a + "\n" + Q
    check(name + ": set of the next block keeps it", P + "\n" + a + "\n" + block("q.example.com", "respond x"),
          outcome(caddyfile.set_site, text, "q.example.com", BODY))
    check(name + ": remove of the next block keeps it", P + "\n" + a,
          outcome(caddyfile.remove_site, text, "q.example.com"))
    check(name + ": set replaces it whole", P + "\n" + block("a.example.com", "respond x") + "\n" + Q,
          outcome(caddyfile.set_site, text, "a.example.com", BODY))
    check(name + ": remove takes it whole", P + "\n" + Q, outcome(caddyfile.remove_site, text, "a.example.com"))


def refused(name, text, host="a.example.com", code=5):
    """Neither set nor remove of the host touches the text."""
    what = "Refused 5" if code == 5 else "UsageError 2"
    check(name + ": set is refused", what, outcome(caddyfile.set_site, text, host, BODY))
    check(name + ": remove is refused", what, outcome(caddyfile.remove_site, text, host))


# ---- line ends ----

crlf = (block("p.example.com", "respond p", "\r\n") + "\r\n" + block("a.example.com", "respond a", "\r\n") + "\r\n"
        + block("q.example.com", "respond q", "\r\n"))
check("CRLF: set of a block keeps CRLF and every other byte",
      crlf.replace("respond a", "respond x"), outcome(caddyfile.set_site, crlf, "a.example.com", BODY))
check("CRLF: an appended block ends its lines with CRLF",
      crlf + "\r\nhttps://new.example.com {\r\n\trespond x\r\n}\r\n",
      outcome(caddyfile.set_site, crlf, "new.example.com", BODY))
check("CRLF: remove takes the block and one blank line",
      block("p.example.com", "respond p", "\r\n") + "\r\n" + block("q.example.com", "respond q", "\r\n"),
      outcome(caddyfile.remove_site, crlf, "a.example.com"))

bare = P + "\n" + Q.rstrip("\n")
check("no final newline: set of the last block keeps it so", P + "\n" + "q.example.com {\n\trespond x\n}",
      outcome(caddyfile.set_site, bare, "q.example.com", BODY))
check("no final newline: an appended block comes after one blank line",
      bare + "\n\nhttps://new.example.com {\n" + X + "}\n", outcome(caddyfile.set_site, bare, "new.example.com", BODY))
check("no final newline: remove of the last block leaves the one before", P,
      outcome(caddyfile.remove_site, bare, "q.example.com"))

check("a text ending in blank lines gets one blank line before an appended block",
      P + "\nhttps://new.example.com {\n" + X + "}\n", outcome(caddyfile.set_site, P + "\n\n\n", "new.example.com", BODY))
check("…with CRLF too", block("p.example.com", "respond p", "\r\n") + "\r\nhttps://new.example.com {\r\n\trespond x\r\n}\r\n",
      outcome(caddyfile.set_site, block("p.example.com", "respond p", "\r\n") + "\r\n\r\n", "new.example.com", BODY))

# ---- tokens that hold braces ----

around("a backtick string", "a.example.com {\n\trespond `{\n} not a brace\n` 200\n}\n")
around("an escaped quote", 'a.example.com {\n\theader X-Note "a \\" } b"\n}\n')
around("two heredocs", "a.example.com {\n\trespond <<ONE\n\t\t}\n\t\tONE 200\n\theader X <<TWO\n\t\t{\n\t\tTWO\n}\n")
around("a heredoc closed by its marker and an argument", "a.example.com {\n\trespond <<HTML\n\t\t}\n\t\tHTML 200\n}\n")
around("an import inside a site", "a.example.com {\n\timport tls_config\n\timport common a.example.com\n}\n")

placeholder = P + "\n{$SITE} {\n\trespond s\n}\n\n" + Q
check("a placeholder address: set of another host keeps its block",
      P + "\n{$SITE} {\n\trespond s\n}\n\n" + block("q.example.com", "respond x"),
      outcome(caddyfile.set_site, placeholder, "q.example.com", BODY))
check("a placeholder address: remove of another host keeps its block", P + "\n{$SITE} {\n\trespond s\n}\n",
      outcome(caddyfile.remove_site, placeholder, "q.example.com"))
check("a placeholder address: a new host is appended after it",
      placeholder + "\nhttps://new.example.com {\n" + X + "}\n",
      outcome(caddyfile.set_site, placeholder, "new.example.com", BODY))

# ---- what is refused ----

refused("an unclosed quote", P + '\na.example.com {\n\trespond "x }\n}\n', "p.example.com")
refused("an unclosed backtick", P + "\na.example.com {\n\trespond `x }\n}\n", "p.example.com")
refused("an unclosed heredoc", P + "\na.example.com {\n\trespond <<END\n\t\tx\n}\n", "p.example.com")
refused("a heredoc whose marker only starts a word (HTMLX)",
        P + "\na.example.com {\n\trespond <<HTML\n\t\tx\n\t\tHTMLX\n}\n", "p.example.com")
refused("a heredoc whose marker follows text on its line",
        P + "\na.example.com {\n\trespond <<HTML\n\t\t<p>HTML\n}\n", "p.example.com")
refused("a stray closing brace", P + "}\n\n" + Q, "q.example.com")
refused("host:443", P + "\n" + block("a.example.com:443", "respond a"))
refused("a trailing dot", P + "\n" + block("a.example.com.", "respond a"))
check("host:443: set of another host keeps its block", P + "\n" + block("a.example.com:443", "respond a") + "\n"
      + block("q.example.com", "respond x"),
      outcome(caddyfile.set_site, P + "\n" + block("a.example.com:443", "respond a") + "\n" + Q, "q.example.com", BODY))

# ---- bodies ----

check("a body's lines inside a backtick string keep their bytes",
      ["\trespond `line one", "    indented", "   ", "` 200"], caddyfile.body("respond `line one\n    indented\n   \n` 200\n"))
check("a body's heredoc keeps its lines, the line that opens it is indented with the rest",
      ["\theader X a", "\trespond <<HTML", "        <p>x</p>", "        HTML 200"],
      caddyfile.body("    header X a\n    respond <<HTML\n        <p>x</p>\n        HTML 200\n"))
check("a body's common indentation is replaced by one tab, a heredoc's lines left out of it",
      ["\trespond <<HTML", "<p>x</p>", "HTML 200", "\tlog"], caddyfile.body("  respond <<HTML\n<p>x</p>\nHTML 200\n  log\n"))
