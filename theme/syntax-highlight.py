#!/usr/bin/env python3
#
# Custom cgit syntax highlighting filter using Pygments.
# Outputs CSS-class-only HTML (no inline <style> block) so our
# theme's CSS variables control the colors in both light and dark mode.
#
import sys
import io
from pygments import highlight
from pygments.util import ClassNotFound
from pygments.lexers import TextLexer, guess_lexer, guess_lexer_for_filename
from pygments.formatters import HtmlFormatter

sys.stdin = io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8", errors="replace")
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

data = sys.stdin.read()
filename = sys.argv[1] if len(sys.argv) > 1 else ""

# Use CSS classes only — no inline styles, no embedded <style> block.
# Our cgit.css defines .highlight .xx rules using CSS custom properties
# that adapt to light/dark mode automatically.
formatter = HtmlFormatter(
    nowrap=False,
    nobackground=True,
    classprefix="",
    cssclass="highlight",
    style="default",  # ignored since we only use class names
)

try:
    lexer = guess_lexer_for_filename(filename, data)
except ClassNotFound:
    if data[:2] == "#!":
        lexer = guess_lexer(data)
    else:
        lexer = TextLexer()
except TypeError:
    lexer = TextLexer()

sys.stdout.write(highlight(data, lexer, formatter))
