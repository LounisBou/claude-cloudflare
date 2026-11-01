"""The Caddyfile as text: its tokens, its top-level blocks, and the edits that
replace, remove or append one site block while every other byte stays.

The lexer follows Caddy's: tokens are split on whitespace; a "#" that starts a
token runs to the end of the line; a token that starts with a double quote or
a backtick runs to the closing one (a backslash escapes inside double quotes
and outside quotes); "<<MARKER" at the end of a line opens a heredoc that the
first line holding MARKER after its indentation, alone or followed by a space
("MARKER 200"), closes. A brace opens or closes a block only as a token of its
own and unquoted, so "{host}", "{$TOKEN}" or a "{" inside quotes, a comment or
a heredoc is a word.

Nothing here reads or writes a file: the edits take the text and give back
the new text, so the bytes outside the edited block come through untouched.
"""

import os
import re

from . import errors

_HEREDOC = re.compile(r"<<([A-Za-z0-9_-]+)\r?\n")
_SNIPPET = re.compile(r"^\(.+\)$")
_ROUTE = re.compile(r"^&\(.+\)$")
_LABEL = r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
_HOST = re.compile(r"^%s(?:\.%s)*$" % (_LABEL, _LABEL))


class Token:
    __slots__ = ("text", "start", "end", "line", "end_line", "quoted")

    def __init__(self, text, start, end, line, end_line, quoted):
        self.text = text
        self.start = start
        self.end = end
        self.line = line
        self.end_line = end_line
        self.quoted = quoted

    def is_open(self):
        return not self.quoted and self.text == "{"

    def is_close(self):
        return not self.quoted and self.text == "}"


class Block:
    """A top-level block: its address tokens (none for the global options),
    its kind, and where it lies, from its first address to its closing brace."""

    def __init__(self, header, open_, close):
        self.header = header
        self.addresses = [part for tok in header for part in tok.text.split(",") if part]
        first = header[0] if header else open_
        self.start = first.start
        self.end = close.end
        self.line = first.line
        self.end_line = close.line
        if not self.addresses:
            self.kind = "global"
        elif len(self.addresses) == 1 and _SNIPPET.match(self.addresses[0]):
            self.kind = "snippet"
        elif len(self.addresses) == 1 and _ROUTE.match(self.addresses[0]):
            self.kind = "route"
        else:
            self.kind = "site"


def _refuse(what, line):
    raise errors.Refused("the Caddyfile cannot be read safely: %s at line %d; nothing was changed" % (what, line))


def tokens(text, refuse=_refuse):
    found = []
    i, n, line = 0, len(text), 1
    while i < n:
        ch = text[i]
        if ch == "\n":
            line += 1
            i += 1
            continue
        if ch.isspace():
            i += 1
            continue
        if ch == "#":
            while i < n and text[i] != "\n":
                i += 1
            continue
        start, start_line, quoted = i, line, False
        heredoc = _HEREDOC.match(text, i)
        if ch in "\"`":
            quoted = True
            i += 1
            while i < n and text[i] != ch:
                if ch == '"' and text[i] == "\\" and i + 1 < n:
                    i += 1
                if text[i] == "\n":
                    line += 1
                i += 1
            if i >= n:
                refuse("a quote is never closed", start_line)
            i += 1
        elif heredoc:
            quoted = True
            marker = heredoc.group(1)
            i = heredoc.end()
            line += 1
            while True:
                if i >= n:
                    refuse("the heredoc %s is never closed" % marker, start_line)
                eol = text.find("\n", i)
                eol = n if eol < 0 else eol
                content = text[i:eol].lstrip(" \t")
                rest = content[len(marker):]
                if content.startswith(marker) and (not rest or rest[0].isspace()):
                    i = eol - len(content) + len(marker)
                    break
                i = eol + 1
                line += 1
        else:
            while i < n and not text[i].isspace():
                if text[i] == "\\" and i + 1 < n:
                    if text[i + 1] == "\n":
                        line += 1
                    i += 1
                i += 1
        found.append(Token(text[start:i], start, i, start_line, line, quoted))
    return found


def parse(text):
    """(blocks, loose): the top-level blocks in order, and the top-level lines
    that are not blocks (an import, or the directives of a site without braces),
    each as its tokens."""
    toks = tokens(text)
    blocks, loose = [], []
    i, n = 0, len(toks)
    while i < n:
        if toks[i].is_close():
            _refuse("a closing brace with no block open", toks[i].line)
        header = []
        if not toks[i].is_open():
            header.append(toks[i])
            i += 1
            # Addresses run to the end of the line, or on to the next one
            # after a trailing comma.
            while i < n and not toks[i].is_open() and not toks[i].is_close() and (
                    toks[i].line == header[-1].end_line or header[-1].text.endswith(",")):
                header.append(toks[i])
                i += 1
            if i >= n or not toks[i].is_open() or toks[i].line != header[-1].end_line:
                loose.append(header)
                continue
        depth, j = 0, i
        while j < n:
            if toks[j].is_open():
                depth += 1
            elif toks[j].is_close():
                depth -= 1
                if depth == 0:
                    break
            j += 1
        if j >= n:
            _refuse("a block is never closed", toks[i].line)
        blocks.append(Block(header, toks[i], toks[j]))
        i = j + 1
    return blocks, loose


def site_host(address):
    """The host an address serves over HTTPS on 443, or None: plain HTTP, a
    port of its own, no host, a wildcard or a placeholder have none."""
    scheme, sep, rest = address.lower().partition("://")
    if not sep:
        scheme, rest = "", scheme
    if scheme not in ("", "https"):
        return None
    rest = rest.split("/", 1)[0]
    if rest.startswith("["):
        return None
    host, sep, port = rest.rpartition(":")
    if not sep:
        host, port = rest, ""
    if port and port != "443":
        return None
    if not host or "*" in host or "{" in host:
        return None
    # "host." is the same name, fully qualified.
    return host[:-1] if host.endswith(".") else host


def _covers(address, host):
    pattern = address.lower().split("://", 1)[-1].split("/", 1)[0].split(":", 1)[0]
    return (pattern.startswith("*.") and host.endswith(pattern[1:])
            and host.count(".") == pattern.count("."))


def hosts(blocks):
    """Every host a site block serves over HTTPS, sorted, once each."""
    found = set()
    for block in blocks:
        if block.kind == "site":
            found.update(h for h in map(site_host, block.addresses) if h)
    return sorted(found)


def host_name(raw, wildcard=False):
    """A host as the commands take it: case and an https:// prefix ignored.
    A wildcard ("*.example.com") is taken only where wildcard is true (a
    read); elsewhere it is refused (exit 5): its block cannot be named without
    ambiguity. Anything else that is not a DNS name is a usage error."""
    host = raw.strip().lower()
    if host.startswith("https://"):
        host = host[len("https://"):]
    host = host.rstrip(".")
    name = host[2:] if wildcard and host.startswith("*.") else host
    if "*" in name:
        raise errors.Refused("%s is a wildcard: a wildcard block is edited by hand" % raw)
    if not _HOST.match(name) or len(host) > 253:
        raise errors.UsageError("%s is not a host name" % raw)
    return host


def serving(blocks, host):
    """The site blocks that serve the host: those naming it, else the
    wildcard ones covering it. For reading only."""
    named = [b for b in blocks if b.kind == "site" and (
        host in map(site_host, b.addresses) or host in (a.lower().split("://", 1)[-1] for a in b.addresses))]
    return named or [b for b in blocks if b.kind == "site" and any(_covers(a, host) for a in b.addresses)]


def target(text, blocks, loose, host):
    """The one block an edit of the host replaces or removes: the block whose
    only address is host or https://host, None when there is none. Exit 5 for
    anything that cannot be named without ambiguity: a block holding the host
    among other addresses or under another form (host:443), two blocks for it,
    or a site written without braces. A wildcard block covering the host is
    left alone: a block of the host's own takes precedence over it in Caddy."""
    for line in loose:
        if line[0].text != "import":
            raise errors.Refused(
                "line %d of the Caddyfile is outside any block (a site without braces?): "
                "an edit could not tell the sites apart" % line[0].line)
    exact = []
    for block in blocks:
        if block.kind != "site":
            continue
        if host in map(site_host, block.addresses):
            if len(block.addresses) == 1 and block.addresses[0].lower() in (host, "https://" + host):
                exact.append(block)
                continue
            if len(block.addresses) == 1:
                raise errors.Refused("%s is written %s in the block of line %d: edit that block by hand"
                                     % (host, block.addresses[0], block.line))
            raise errors.Refused("%s is in the block of line %d with other addresses (%s): edit that block by hand"
                                 % (host, block.line, ", ".join(block.addresses)))
    if len(exact) > 1:
        raise errors.Refused("%s has %d blocks (lines %s): edit them by hand"
                             % (host, len(exact), ", ".join(str(b.line) for b in exact)))
    return exact[0] if exact else None


def set_site(text, host, lines):
    """The text with the host's block given the lines, or a block appended for it."""
    blocks, loose = parse(text)
    block = target(text, blocks, loose, host)
    return append(text, host, lines) if block is None else replace(text, block, lines)


def remove_site(text, host):
    """The text without the host's block; exit 2 when it has none."""
    blocks, loose = parse(text)
    block = target(text, blocks, loose, host)
    if block is None:
        raise errors.UsageError("no site block for %s in the Caddyfile" % host)
    return remove(text, block)


def _newline(text):
    return "\r\n" if "\r\n" in text else "\n"


def body(raw):
    """A block's body as a file gives it: its braces checked, its common
    indentation replaced by one tab. The lines inside a token that runs over
    several (a backtick string, a heredoc) keep their bytes and count for no
    indentation. Exit 2 for an empty or unbalanced body."""
    lines = raw.replace("\r\n", "\n").split("\n")
    while lines and not lines[0].strip():
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()
    if not lines:
        raise errors.UsageError("the body is empty: caddy-site-remove removes a block")

    def unbalanced(what, line):
        raise errors.UsageError("the body cannot be used: %s at line %d" % (what, line))

    depth, inner = 0, set()
    for tok in tokens("\n".join(lines), refuse=unbalanced):
        inner.update(range(tok.line + 1, tok.end_line + 1))
        if tok.is_open():
            depth += 1
        elif tok.is_close():
            depth -= 1
            if depth < 0:
                unbalanced("a closing brace closes the site block", tok.line)
    if depth:
        unbalanced("a block is never closed", len(lines))
    outer = [line for k, line in enumerate(lines, 1) if k not in inner and line.strip()]
    margin = len(os.path.commonprefix([line[:len(line) - len(line.lstrip())] for line in outer]))
    return [line if k in inner else ("\t" + line[margin:] if line.strip() else "")
            for k, line in enumerate(lines, 1)]


def _block_text(address, lines, nl):
    return address + " {" + nl + nl.join(lines) + nl + "}"


def replace(text, block, lines):
    """The block's body swapped for the given lines, its address kept as written."""
    nl = _newline(text)
    address = text[block.header[0].start:block.header[-1].end]
    return text[:block.start] + _block_text(address, lines, nl) + text[block.end:]


def append(text, host, lines):
    """A new block https://<host> at the end, after one blank line: the
    blank lines that end the text are that one."""
    nl = _newline(text)
    new = _block_text("https://" + host, lines, nl) + nl
    kept = text.splitlines(True)
    while kept and not kept[-1].strip():
        kept.pop()
    if not kept:
        return new
    head = "".join(kept)
    return head + ("" if head.endswith("\n") else nl) + nl + new


def _line_start(text, at):
    return text.rfind("\n", 0, at) + 1


def _line_end(text, at):
    """The offset just past the newline that ends the line holding at."""
    eol = text.find("\n", at)
    return len(text) if eol < 0 else eol + 1


def remove(text, block):
    """The text without the block. Whole lines go when the block owns them,
    and of the blank lines around it only one stays."""
    start, end = block.start, block.end
    line_start = _line_start(text, start)
    if not text[line_start:start].strip():
        start = line_start
    line_end = _line_end(text, end)
    if not text[end:line_end].strip():
        end = line_end
    if start == line_start and start > 0:
        before = _line_start(text, start - 1)
        after_blank = end >= len(text) or not text[end:_line_end(text, end)].strip()
        if not text[before:start].strip() and after_blank:
            start = before
    return text[:start] + text[end:]


def upstreams(text, block):
    """The upstreams of the block's reverse_proxy directives, in order, once each."""
    found = []
    after = block.header[-1].end if block.header else block.start
    inside = [t for t in tokens(text[:block.end]) if t.start > after]
    for k, tok in enumerate(inside):
        if tok.quoted or tok.text != "reverse_proxy":
            continue
        for arg in inside[k + 1:]:
            if arg.line != tok.line or arg.is_open() or arg.is_close():
                break
            if arg.text.startswith(("@", "/", "*")) and arg is inside[k + 1]:
                continue
            if arg.text not in found:
                found.append(arg.text)
    return found
