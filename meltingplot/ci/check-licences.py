#!/usr/bin/env python3
"""Check every licence of every package against meltingplot/grant.yaml.

grant compares the licence string of a package as a whole. A Debian package
whose copyright file names many licences arrives as one expression, "A AND B
AND LicenseRef-vendor-terms", and a pattern like Apache-* matched all of it as
soon as it began with Apache-2.0. This takes grant's own report apart instead
and decides per licence:

- a licence whose name looks like a vendor's own terms (the review patterns
  in grant.yaml: proprietary, binary-redist, EULA, ...) passes only for a
  package listed under accept, with the reason a person gave;
- any other licence passes when an entry of allow matches it as a whole;
- a LicenseRef-* that is neither passes: Debian names its licence texts that
  way (LicenseRef-Expat, LicenseRef-BSD-3-clause-Regents, ...), and the
  review patterns are what keeps a vendor's terms among them from passing.

Everything else fails the check, with the packages it was found in, so a new
licence needs a decision before an image ships.

    check-licences.py <grant.yaml> <grant report .json> [<summary .md>]
"""
import fnmatch
import json
import re
import sys

import yaml

SPLIT = re.compile(r"\s+(?:AND|OR|WITH)\s+")


def atoms(expression):
    for part in SPLIT.split(expression):
        part = part.strip().strip("()").strip()
        if part:
            yield part


def main():
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__.strip().splitlines()[-1].strip())
    policy = yaml.safe_load(open(sys.argv[1]))
    report = json.load(open(sys.argv[2]))
    summary = sys.argv[3] if len(sys.argv) == 4 else None

    # A string with whitespace in allow is a whole expression grant matches;
    # here only single licences count.
    allow = [a for a in policy.get("allow", []) if not re.search(r"\s", a)]
    own = policy.get("meltingplot") or {}
    review = [re.compile(p) for p in own.get("review-patterns", [])]
    accept = own.get("accept") or {}

    unknown = {}   # licence -> packages
    vendor = {}    # (package, licence) -> True
    packages = report["run"]["targets"][0]["evaluation"]["findings"]["packages"]
    for pkg in packages:
        name = pkg["name"]
        for lic in pkg.get("licenses", []):
            for atom in atoms(lic.get("id") or ""):
                if any(r.search(atom) for r in review):
                    ok = [a for a in (accept.get(name) or {}).get("licences", [])
                          if fnmatch.fnmatchcase(atom, a)]
                    if not ok:
                        vendor[(name, atom)] = True
                elif any(fnmatch.fnmatchcase(atom, a) for a in allow):
                    pass
                elif atom.startswith("LicenseRef-"):
                    pass
                else:
                    unknown.setdefault(atom, set()).add(name)

    lines = ["## Licences", ""]
    lines.append(f"{len(packages)} packages; {len(unknown)} licences outside "
                 f"grant.yaml, {len(vendor)} vendor terms without a decision.")
    if unknown:
        lines += ["", "Licences outside the allow list:"]
        for atom in sorted(unknown):
            lines.append(f"- {atom}: {', '.join(sorted(unknown[atom]))}")
    if vendor:
        lines += ["", "Vendor terms without an accept entry:"]
        for name, atom in sorted(vendor):
            lines.append(f"- {name}: {atom}")
    text = "\n".join(lines) + "\n"
    print(text, end="")
    if summary:
        with open(summary, "a") as f:
            f.write(text)
    sys.exit(1 if unknown or vendor else 0)


if __name__ == "__main__":
    main()
