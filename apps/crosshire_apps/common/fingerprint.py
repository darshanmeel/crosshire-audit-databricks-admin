"""Normalise free text (error messages) so no values survive, then hash it."""
import hashlib
import re

MAX_TEMPLATE_CHARS = 400

# Order matters: strip the specific shapes before the generic number rule eats their digits.
_RULES = [
    (re.compile(r"[\w.+-]+@[\w-]+(\.[\w-]+)+"), "<email>"),
    (re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"), "<uuid>"),
    (re.compile(r"\b[a-z][a-z0-9+.-]*://\S+"), "<path>"),
    (re.compile(r"(?<![\w<])(?:/[^\s/:'\"`,;()\[\]]+){2,}/?"), "<path>"),
    (re.compile(r"\b[A-Za-z]:\\\S+"), "<path>"),
    (re.compile(r"'[^']*'|\"[^\"]*\"|`[^`]*`"), "<str>"),
    (re.compile(r"\b0x[0-9a-fA-F]+\b"), "<num>"),
    (re.compile(r"\b[0-9a-fA-F]{16,}\b"), "<hex>"),
    (re.compile(r"\d+(\.\d+)?"), "<num>"),
]
_SPACES = re.compile(r"\s+")


def template(text):
    """Message with values replaced by placeholders; None stays None."""
    if text is None:
        return None
    out = text
    for pattern, placeholder in _RULES:
        out = pattern.sub(placeholder, out)
    out = _SPACES.sub(" ", out).strip()
    return out[:MAX_TEMPLATE_CHARS]


def fingerprint(text):
    """Short stable hash of the template, so equal errors group together."""
    t = template(text)
    if t is None:
        return None
    return hashlib.sha256(t.encode("utf-8")).hexdigest()[:16]
