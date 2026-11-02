#!/usr/bin/env python3
"""Converts factory's config YAML to JSON on stdout, deterministically, with the standard library only.

It reads the YAML subset the factory templates use, and rejects anything else with a line number rather
than guessing:
  - block mappings (`key: value`, `key:` followed by an indented block)
  - block sequences (`- value`, `- key: value` with further keys indented under the first)
  - flow sequences and flow mappings on one line (`[a, "b c"]`, `{k: v, n: [1, 2]}`), nested
  - scalars: "double" (with \\ escapes), 'single' ('' escape), plain; plain true/false/null/~ and
    integers/floats are typed, everything else is a string (no YAML 1.1 yes/no/on/off booleans)
  - literal (|) and folded (>) block scalars
  - comments: a line starting with #, or ` #` after a value outside quotes
Usage: yaml2json.py <file>   (exit 0 and JSON, or exit 2 and `yaml2json: <file>:<line>: <reason>`)
"""
import json
import re
import sys


class YamlError(Exception):
    def __init__(self, line, msg):
        super().__init__(f"{line}: {msg}")


def strip_comment(s):
    """Removes a trailing ` # comment` outside quotes."""
    out, q, i = [], None, 0
    while i < len(s):
        c = s[i]
        if q:
            out.append(c)
            if q == '"' and c == "\\" and i + 1 < len(s):
                out.append(s[i + 1])
                i += 2
                continue
            if c == q:
                if q == "'" and i + 1 < len(s) and s[i + 1] == "'":
                    out.append("'")
                    i += 2
                    continue
                q = None
        else:
            if c in "\"'" and (i == 0 or s[i - 1] in " \t[{,:"):
                q = c
            elif c == "#" and (i == 0 or s[i - 1] in " \t"):
                break
            out.append(c)
        i += 1
    return "".join(out).rstrip()


def plain(s, line):
    s = s.strip()
    if s in ("", "~", "null", "Null", "NULL"):
        return None
    if s in ("true", "True", "TRUE"):
        return True
    if s in ("false", "False", "FALSE"):
        return False
    if re.fullmatch(r"[-+]?\d+", s):
        return int(s)
    if re.fullmatch(r"[-+]?(\d+\.\d*|\.\d+)([eE][-+]?\d+)?", s):
        return float(s)
    if s[0] in "&*!|>%@`":
        raise YamlError(line, f"unsupported plain scalar {s!r}; quote it")
    return s


def quoted(s, i, line):
    """Parses a quoted scalar starting at s[i]; returns (value, next index)."""
    q = s[i]
    i += 1
    out = []
    while i < len(s):
        c = s[i]
        if q == '"' and c == "\\":
            if i + 1 >= len(s):
                break
            d = s[i + 1]
            out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\", "/": "/", "r": "\r", "0": "\0"}.get(d, "\\" + d))
            i += 2
            continue
        if c == q:
            if q == "'" and i + 1 < len(s) and s[i + 1] == "'":
                out.append("'")
                i += 2
                continue
            return "".join(out), i + 1
        out.append(c)
        i += 1
    raise YamlError(line, "unterminated quoted string")


def flow(s, i, line):
    """Parses a flow value at s[i] (a [...] or {...} or scalar); returns (value, next index)."""
    while i < len(s) and s[i] == " ":
        i += 1
    if i >= len(s):
        raise YamlError(line, "missing value")
    c = s[i]
    if c == "[":
        i += 1
        items = []
        while True:
            while i < len(s) and s[i] == " ":
                i += 1
            if i < len(s) and s[i] == "]":
                return items, i + 1
            v, i = flow(s, i, line)
            items.append(v)
            while i < len(s) and s[i] == " ":
                i += 1
            if i < len(s) and s[i] == ",":
                i += 1
                continue
            if i < len(s) and s[i] == "]":
                return items, i + 1
            raise YamlError(line, "expected , or ] in flow sequence")
    if c == "{":
        i += 1
        m = {}
        while True:
            while i < len(s) and s[i] == " ":
                i += 1
            if i < len(s) and s[i] == "}":
                return m, i + 1
            if s[i] in "\"'":
                k, i = quoted(s, i, line)
            else:
                j = i
                while j < len(s) and s[j] not in ":,}":
                    j += 1
                k = s[i:j].strip()
                i = j
            if i >= len(s) or s[i] != ":":
                raise YamlError(line, f"expected : after key {k!r} in flow mapping")
            v, i = flow(s, i + 1, line)
            m[str(k)] = v
            while i < len(s) and s[i] == " ":
                i += 1
            if i < len(s) and s[i] == ",":
                i += 1
                continue
            if i < len(s) and s[i] == "}":
                return m, i + 1
            raise YamlError(line, "expected , or } in flow mapping")
    if c in "\"'":
        return quoted(s, i, line)
    j = i
    while j < len(s) and s[j] not in ",]}":
        j += 1
    return plain(s[i:j], line), j


def scalar_or_flow(s, line):
    s = s.strip()
    if s[:1] in "[{\"'":
        v, i = flow(s, 0, line)
        if s[i:].strip():
            raise YamlError(line, f"unexpected text after value: {s[i:].strip()!r}")
        return v
    return plain(s, line)


KEY = re.compile(r"""^("(?:[^"\\]|\\.)*"|'(?:[^']|'')*'|[^\s"'#:\[\]{},][^:#]*?)\s*:(?:\s+(.*))?$""")


class Parser:
    def __init__(self, text):
        self.lines = []  # (number, indent, content)
        self.raw = text.split("\n")
        for n, raw in enumerate(self.raw, 1):
            if "\t" in raw[: len(raw) - len(raw.lstrip())]:
                raise YamlError(n, "tab in indentation")
            content = strip_comment(raw)
            if not content.strip() or content.strip() == "---":
                continue
            self.lines.append((n, len(content) - len(content.lstrip()), content.strip()))
        self.pos = 0

    def peek(self):
        return self.lines[self.pos] if self.pos < len(self.lines) else None

    def parse(self):
        if not self.lines:
            return {}
        v = self.block(self.lines[0][1])
        if self.peek():
            n, _, c = self.peek()
            raise YamlError(n, f"unexpected content {c!r} (check indentation)")
        return v

    def block(self, indent):
        n, ind, c = self.peek()
        if c.startswith("- ") or c == "-":
            return self.seq(ind)
        return self.mapping(ind)

    def block_scalar(self, style, parent_indent, line):
        """Reads the raw lines of a | or > scalar after `line`."""
        out, start = [], line  # line numbers are 1-based; raw is 0-based
        i = start
        ind = None
        while i < len(self.raw):
            r = self.raw[i]
            if r.strip() == "":
                out.append("")
                i += 1
                continue
            cur = len(r) - len(r.lstrip())
            if cur <= parent_indent:
                break
            if ind is None:
                ind = cur
            out.append(r[ind:])
            i += 1
        while out and out[-1] == "":
            out.pop()
        # skip the consumed lines in the logical stream
        while self.peek() and self.peek()[0] <= i:
            self.pos += 1
        if style == "|":
            return "\n".join(out) + "\n"
        return " ".join(x for x in out if x) + "\n"

    def value_after_key(self, rest, indent, n):
        if rest is None or rest == "":
            nxt = self.peek()
            if nxt and nxt[1] > indent:
                return self.block(nxt[1])
            if nxt and nxt[1] == indent and (nxt[2].startswith("- ") or nxt[2] == "-"):
                return self.seq(indent)
            return None
        if rest in ("|", "|-", ">", ">-"):
            v = self.block_scalar(rest[0], indent, n)
            return v.rstrip("\n") if rest.endswith("-") else v
        return scalar_or_flow(rest, n)

    def mapping(self, indent):
        m = {}
        while True:
            p = self.peek()
            if not p or p[1] < indent:
                return m
            n, ind, c = p
            if ind > indent:
                raise YamlError(n, "unexpected indentation")
            if c.startswith("- "):
                return m
            k = KEY.match(c)
            if not k:
                raise YamlError(n, f"expected `key: value`, got {c!r}")
            key = k.group(1)
            if key[:1] in "\"'":
                key = quoted(key, 0, n)[0]
            if key in m:
                raise YamlError(n, f"duplicate key {key!r}")
            self.pos += 1
            m[key] = self.value_after_key(k.group(2), indent, n)

    def seq(self, indent):
        items = []
        while True:
            p = self.peek()
            if not p or p[1] < indent:
                return items
            n, ind, c = p
            if ind > indent:
                raise YamlError(n, "unexpected indentation in sequence")
            if not (c.startswith("- ") or c == "-"):
                return items
            rest = c[1:].strip()
            self.pos += 1
            if rest == "":
                nxt = self.peek()
                items.append(self.block(nxt[1]) if nxt and nxt[1] > indent else None)
                continue
            k = KEY.match(rest)
            if k:  # KEY never matches a flow value or a quoted scalar that merely contains a colon
                # `- key: value` starts a mapping whose other keys sit at the key's column
                item_indent = ind + (len(c) - len(rest))
                key = k.group(1)
                if key[:1] in "\"'":
                    key = quoted(key, 0, n)[0]
                m = {key: self.value_after_key(k.group(2), item_indent, n)}
                nxt = self.peek()
                if nxt and nxt[1] == item_indent and not nxt[2].startswith("- "):
                    more = self.mapping(item_indent)
                    for kk in more:
                        if kk in m:
                            raise YamlError(n, f"duplicate key {kk!r}")
                    m.update(more)
                items.append(m)
            else:
                items.append(scalar_or_flow(rest, n))


def main():
    if len(sys.argv) != 2:
        print("usage: yaml2json.py <file>", file=sys.stderr)
        return 2
    path = sys.argv[1]
    try:
        with open(path, encoding="utf-8") as f:
            data = Parser(f.read()).parse()
    except OSError as e:
        print(f"yaml2json: {path}: {e.strerror}", file=sys.stderr)
        return 2
    except YamlError as e:
        print(f"yaml2json: {path}:{e}", file=sys.stderr)
        return 2
    json.dump(data, sys.stdout, ensure_ascii=False, sort_keys=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
