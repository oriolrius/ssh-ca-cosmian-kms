#!/usr/bin/env python3
"""Pre-render fenced ```mermaid blocks to PNG for the PDF build.

Reads a Markdown file, renders each mermaid block to a PNG via
@mermaid-js/mermaid-cli (npx), and writes a copy of the Markdown with each block
replaced by an image reference (absolute path, so pandoc needs no resource-path
entry for them). On GitHub the original ```mermaid fences render natively; this
step only affects the PDF pipeline.

Usage: render_mermaid.py <input.md> <output.md> <asset_dir> <puppeteer_config.json>
"""
import hashlib
import os
import re
import subprocess
import sys

src, out, asset_dir, pptr = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
os.makedirs(asset_dir, exist_ok=True)

block = re.compile(r"^```mermaid[ \t]*\n(.*?)\n```[ \t]*$", re.MULTILINE | re.DOTALL)


def render(match: "re.Match") -> str:
    code = match.group(1)
    digest = hashlib.sha1(code.encode("utf-8")).hexdigest()[:12]
    mmd = os.path.join(asset_dir, f"m-{digest}.mmd")
    png = os.path.join(asset_dir, f"m-{digest}.png")
    with open(mmd, "w", encoding="utf-8") as fh:
        fh.write(code + "\n")
    subprocess.run(
        ["npx", "-y", "@mermaid-js/mermaid-cli",
         "-i", mmd, "-o", png, "-p", pptr,
         "-b", "white", "-s", "2"],
        check=True,
    )
    return f"![]({os.path.abspath(png)})"


text = open(src, encoding="utf-8").read()
text = block.sub(render, text)
with open(out, "w", encoding="utf-8") as fh:
    fh.write(text)
print(f"render_mermaid: {src} -> {out} (assets in {asset_dir})")
