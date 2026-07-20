#!/usr/bin/env python3
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parent
LINK = re.compile(r"\[[^]]+\]\(([^)#]+)(?:#[^)]+)?\)")


def validate_skill(directory):
    path = directory / "SKILL.md"
    text = path.read_text(encoding="utf-8")
    if not text.startswith("---\n") or "\n---\n" not in text[4:]:
        raise ValueError(f"{path} has invalid frontmatter")
    frontmatter, body = text[4:].split("\n---\n", 1)
    fields = {}
    for line in frontmatter.splitlines():
        key, separator, value = line.partition(":")
        if not separator or not value.strip():
            raise ValueError(f"{path} has invalid frontmatter field")
        fields[key.strip()] = value.strip()
    if set(fields) != {"name", "description"} or fields["name"] != directory.name:
        raise ValueError(f"{path} name or frontmatter fields are invalid")
    for target in LINK.findall(body):
        if "://" in target:
            continue
        resolved = (directory / target).resolve()
        if not resolved.is_relative_to(ROOT.parent.resolve()) or not resolved.exists():
            raise ValueError(f"{path} has a broken local link: {target}")


def main():
    directories = sorted(path for path in ROOT.glob("remote-everything-*") if path.is_dir())
    if not directories:
        raise ValueError("no Remote Everything skills found")
    for directory in directories:
        validate_skill(directory)
    print(f"validated {len(directories)} skills")


if __name__ == "__main__":
    main()
