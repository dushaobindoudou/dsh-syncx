#!/usr/bin/env python3
"""dsh-syncx secret scanner / redactor / restorer.

Subcommands
  scan PATH... [--json] [--min-severity high|medium]
      Walk paths (files or dirs), report findings. Exit 2 when a finding at
      or above --min-severity is present (default: high).
  redact PATH... [--map-out FILE] [--json]
      Rewrite files in place, replacing every high-severity secret with a
      stable placeholder. --map-out receives {placeholder: secret} JSON
      (the caller encrypts it and keeps it out of git).
  substitute FILE --map FILE [--json]
      Reverse of redact: put real values back from the local mapping.
  count-placeholders PATH...
      Print how many __REDACTED_* placeholders remain (restore helper).

Design
  - Placeholder = __REDACTED_<RULE>_<sha256(secret)[:8]>__
  - Never touches *.enc / *.sha256 / secret.key / node_modules / .git
  - Env-var references (DEEPSEEK_API_KEY, ${VAR}, keyRef, apiKeyEnv,
    secretStore: keychain, passphrase: {mode: auto}, paths) are NOT secrets.
"""

import hashlib
import json
import os
import re
import sys

PLACEHOLDER_RE = re.compile(r"__REDACTED_([A-Z0-9_]+?)_([0-9a-f]{8})__")
SKIP_DIRS = {".git", "node_modules", "backups", ".dsh-backup"}
SKIP_FILE_SUFFIXES = (".enc", ".sha256", ".key", ".png", ".jpg", ".jpeg", ".gif", ".pdf", ".tgz", ".zip")
SKIP_NAMES = {"secret.key"}
MAX_BYTES = 4 * 1024 * 1024

# --- pattern rules (literal token shapes) ----------------------------------
PATTERN_RULES = [
    ("private-key-block", r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY( BLOCK)?-----", "high"),
    ("openai-key", r"\bsk-(?:ant-|proj-)?[A-Za-z0-9_\-]{20,}", "high"),
    ("anthropic-key", r"\bsk-ant-[A-Za-z0-9_\-]{20,}", "high"),
    ("github-pat", r"\bgithub_pat_[A-Za-z0-9_]{20,}", "high"),
    ("github-token", r"\bgh[pousr]_[A-Za-z0-9]{20,}", "high"),
    ("gitlab-token", r"\bglpat-[A-Za-z0-9_\-]{20,}", "high"),
    ("slack-token", r"\bxox[abposr]-[A-Za-z0-9-]{10,}", "high"),
    ("slack-webhook", r"https://hooks\.slack\.com/services/[A-Za-z0-9/_-]{20,}", "high"),
    ("discord-webhook", r"https://(?:ptb\.|canary\.)?discord(?:app)?\.com/api/webhooks/[A-Za-z0-9/_-]{20,}", "high"),
    ("google-api-key", r"\bAIza[0-9A-Za-z_\-]{35}\b", "high"),
    ("aws-access-key", r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b", "high"),
    ("aws-secret-key", r"\baws[_-]?secret[_-]?access[_-]?key\b\s*[:=]\s*[\"']?[A-Za-z0-9/+=]{40}", "high"),
    ("huggingface-token", r"\bhf_[A-Za-z0-9]{30,}\b", "high"),
    ("nvidia-key", r"\bnvapi-[A-Za-z0-9_\-]{20,}\b", "high"),
    ("telegram-bot-token", r"\b\d{6,12}:[A-Za-z0-9_-]{35}\b", "high"),
    ("jwt", r"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\b", "high"),
    ("ssh-private-key", r"\bssh-(?:rsa|ed25519|dss)\s+AAAA[A-Za-z0-9+/=]{20,}", "high"),
    ("eth-private-key", r"\b0x[0-9a-fA-F]{64}\b", "high"),
    ("bearer-literal", r"(?i)\bbearer\s+[A-Za-z0-9._\-]{24,}", "high"),
    ("hex-blob-64", r"\b[0-9a-fA-F]{64}\b", "medium"),
]

# --- contextual rules: key that implies a secret, with a real value ---------
SECRET_KEY_RE = re.compile(
    r"(?i)(?:^|[\s,{])[\"']?"
    r"(token|api[_-]?key|apikey|access[_-]?key|secret[_-]?key|client[_-]?secret|"
    r"secret|password|passwd|passphrase|auth[_-]?token|access[_-]?token|"
    r"refresh[_-]?token|session[_-]?key|signing[_-]?key|private[_-]?key|"
    r"mnemonic|seed[_-]?phrase|webhook(?:[_-]?url)?|authorization)"
    r"[\"']?\s*:\s*(.+)$"
)

SAFE_KEYS = {
    "apikeyenv", "keyref", "secretstore", "vaultpath", "displayname", "name",
    "id", "baseurl", "model", "provider", "mode", "kind", "type", "network",
    "tradingmode", "signer", "web3account", "tradingaddress", "datadir",
    "names", "label", "url", "endpoint", "path", "file", "version",
}
SAFE_VALUES = {
    "", "auto", "keychain", "none", "null", "true", "false", "inherit", "env",
    "in-history", "ask", "never", "system", "live", "testnet", "web3",
}
ENV_NAME_RE = re.compile(r"^[A-Z][A-Z0-9_]{2,}$")
VAR_REF_RE = re.compile(r"^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?$")
PATH_RE = re.compile(r"^[~/.]\S*$")
PLACEHOLDER_LIKE_RE = re.compile(r"^[\"']?__REDACTED_[A-Z0-9_]+_[0-9a-f]{8}__[\"']?$")
HEX_HASH_KEYS_RE = re.compile(r"(?i)(sha256|sha1|checksum|digest|integrity|hash|fingerprint|etag|rev|commit)")


def placeholder(rule, secret):
    digest = hashlib.sha256(secret.encode("utf-8", "surrogatepass")).hexdigest()[:8]
    return "__REDACTED_%s_%s__" % (rule.upper().replace("-", "_"), digest)


def iter_files(paths):
    for p in paths:
        p = os.path.expanduser(p)
        if os.path.isdir(p):
            for root, dirs, files in os.walk(p):
                dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
                for f in sorted(files):
                    fp = os.path.join(root, f)
                    if f in SKIP_NAMES or f.endswith(SKIP_FILE_SUFFIXES):
                        continue
                    try:
                        if os.path.getsize(fp) > MAX_BYTES:
                            continue
                    except OSError:
                        continue
                    yield fp
        elif os.path.isfile(p):
            if p.endswith(SKIP_FILE_SUFFIXES) or os.path.basename(p) in SKIP_NAMES:
                continue
            yield p


def _strip_scalar(raw):
    """Return (start, end, quoted) of the scalar value inside a raw tail."""
    s = 0
    while s < len(raw) and raw[s] in " \t":
        s += 1
    if s >= len(raw):
        return None
    quote = raw[s] if raw[s] in "\"'" else ""
    if quote:
        end = raw.find(quote, s + 1)
        if end == -1:
            return None
        return s, end + 1, True
    m = re.search(r"\s+#", raw[s:])
    end = s + (m.start() if m else len(raw) - s)
    v = raw[s:end].strip()
    if not v:
        return None
    return s, s + len(v) if end == len(raw) and not v.endswith(" ") else s + len(raw[s:end].rstrip()), False


def find_line_secrets(line, filename=""):
    """Return [(start, end, rule, severity, secret, quoted, key)] for one line."""
    hits = []

    # 1) contextual key: value
    m = SECRET_KEY_RE.search(line)
    if m:
        key = m.group(1).lower().replace("-", "").replace("_", "")
        if key not in SAFE_KEYS and not HEX_HASH_KEYS_RE.search(filename):
            span = _strip_scalar(m.group(2))
            if span:
                start, end, quoted = span
                base = m.start(2)
                raw = line[base:base + end]
                value = raw.strip()
                if quoted:
                    value = value[1:-1]
                if (
                    value
                    and len(value) >= 12
                    and value.lower() not in SAFE_VALUES
                    and not ENV_NAME_RE.match(value)
                    and not VAR_REF_RE.match(value)
                    and not PLACEHOLDER_LIKE_RE.match(value)
                    and not PATH_RE.match(value)
                    # prose (spaces, parentheses, quotes-in-prose) is documentation, not a token
                    and " " not in value and "\t" not in value
                    and not value.startswith(("link:", "file:", "http://127.0.0.1", "http://localhost"))
                    and not HEX_HASH_KEYS_RE.search(filename)
                    # a plain 64-hex value under a key like `token` is still a secret
                ):
                    hits.append((base + start, base + end, "contextual-" + m.group(1).lower(), "high", value, quoted, m.group(1)))

    # 2) literal token shapes
    for rule, pattern, severity in PATTERN_RULES:
        for pm in re.finditer(pattern, line):
            secret = pm.group(0)
            if PLACEHOLDER_RE.search(secret):
                continue
            if rule == "hex-blob-64" and (HEX_HASH_KEYS_RE.search(filename) or HEX_HASH_KEYS_RE.search(line)):
                continue
            if any(h[0] <= pm.start() < h[1] for h in hits):
                continue
            hits.append((pm.start(), pm.end(), rule, severity, secret, False, ""))
    return hits


def scan_paths(paths, min_severity="high"):
    order = {"low": 0, "medium": 1, "high": 2}
    threshold = order[min_severity]
    findings = []
    for fp in iter_files(paths):
        try:
            with open(fp, "r", encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        for lineno, line in enumerate(text.splitlines(), 1):
            for start, end, rule, severity, secret, _quoted, key in find_line_secrets(line, fp):
                if order[severity] < threshold:
                    continue
                findings.append({
                    "file": fp,
                    "line": lineno,
                    "rule": rule,
                    "severity": severity,
                    "key": key,
                    "preview": _mask(secret),
                })
    return findings


def _mask(secret):
    if len(secret) <= 10:
        return "*" * len(secret)
    return secret[:4] + "…" + secret[-3:] + " (%d chars)" % len(secret)


def redact_paths(paths):
    """In-place redaction. Returns (findings, mapping)."""
    mapping = {}
    findings = []
    for fp in iter_files(paths):
        try:
            with open(fp, "r", encoding="utf-8") as fh:
                text = fh.read()
        except (OSError, UnicodeDecodeError):
            continue
        out_lines = []
        changed = False
        for lineno, line in enumerate(text.splitlines(True), 1):
            body = line.rstrip("\n")
            nl = "\n" if line.endswith("\n") else ""
            hits = [h for h in find_line_secrets(body, fp) if h[3] == "high"]
            if not hits:
                out_lines.append(line)
                continue
            pieces = []
            cursor = 0
            for start, end, rule, severity, secret, quoted, key in sorted(hits, key=lambda h: h[0]):
                if start < cursor:
                    continue
                ph = placeholder(rule, secret)
                mapping[ph] = secret
                pieces.append(body[cursor:start])
                pieces.append(ph if not quoted else '"%s"' % ph)
                cursor = end
            pieces.append(body[cursor:])
            out_lines.append("".join(pieces) + nl)
            changed = True
            findings.append({"file": fp, "line": lineno, "rule": hits[0][2], "placeholder": placeholder(hits[0][2], hits[0][4])})
        if changed:
            with open(fp, "w", encoding="utf-8") as fh:
                fh.write("".join(out_lines))
    return findings, mapping


def substitute_paths(paths, mapping):
    count = 0
    unresolved = []
    for fp in iter_files(paths):
        try:
            with open(fp, "r", encoding="utf-8") as fh:
                text = fh.read()
        except (OSError, UnicodeDecodeError):
            continue

        def repl(m):
            nonlocal count
            key = m.group(0)
            if key in mapping:
                count += 1
                return mapping[key]
            unresolved.append({"file": fp, "placeholder": key})
            return key

        new = PLACEHOLDER_RE.sub(repl, text)
        if new != text:
            with open(fp, "w", encoding="utf-8") as fh:
                fh.write(new)
    return count, unresolved


def count_placeholders(paths):
    total = 0
    by_file = {}
    for fp in iter_files(paths):
        try:
            with open(fp, "r", encoding="utf-8") as fh:
                text = fh.read()
        except (OSError, UnicodeDecodeError):
            continue
        n = len(PLACEHOLDER_RE.findall(text))
        if n:
            by_file[fp] = n
            total += n
    return total, by_file


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 64
    cmd = argv[1]
    args = []
    opts = {}
    i = 2
    while i < len(argv):
        a = argv[i]
        if a.startswith("--"):
            key = a[2:]
            if key in ("map-out", "map", "min-severity"):
                opts[key] = argv[i + 1]
                i += 2
                continue
            opts[key] = True
            i += 1
            continue
        args.append(a)
        i += 1

    if cmd == "scan":
        findings = scan_paths(args, opts.get("min-severity", "high"))
        if opts.get("json"):
            print(json.dumps({"findings": findings, "count": len(findings)}, ensure_ascii=False, indent=2))
        else:
            for f in findings:
                print("%-6s %s:%s  %s  %s" % (f["severity"].upper(), f["file"], f["line"], f["rule"], f["preview"]))
            print("%d finding(s)" % len(findings))
        return 2 if findings and opts.get("min-severity", "high") == "high" else 0

    if cmd == "redact":
        findings, mapping = redact_paths(args)
        if opts.get("map-out"):
            with open(opts["map-out"], "w", encoding="utf-8") as fh:
                json.dump(mapping, fh, ensure_ascii=False, indent=2)
            os.chmod(opts["map-out"], 0o600)
        if opts.get("json"):
            print(json.dumps({"redacted": findings, "secrets": len(mapping)}, ensure_ascii=False, indent=2))
        else:
            for f in findings:
                print("REDACTED %s:%s  %s -> %s" % (f["file"], f["line"], f["rule"], f["placeholder"]))
            print("%d location(s), %d unique secret(s) redacted" % (len(findings), len(mapping)))
        return 0

    if cmd == "substitute":
        mapping = {}
        if opts.get("map"):
            try:
                mapping = json.load(open(opts["map"], encoding="utf-8"))
            except (OSError, ValueError):
                mapping = {}
        count, unresolved = substitute_paths(args, mapping)
        if opts.get("json"):
            print(json.dumps({"restored": count, "unresolved": unresolved}, ensure_ascii=False, indent=2))
        else:
            print("restored %d secret(s) from local mapping" % count)
            for u in unresolved:
                print("UNRESOLVED %s  %s" % (u["file"], u["placeholder"]))
        return 0

    if cmd == "count-placeholders":
        total, by_file = count_placeholders(args)
        if opts.get("json"):
            print(json.dumps({"total": total, "files": by_file}, ensure_ascii=False, indent=2))
        else:
            print(json.dumps(by_file, ensure_ascii=False, indent=2))
            print("total %d placeholder(s)" % total)
        return 0

    print("unknown subcommand: %s" % cmd, file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
