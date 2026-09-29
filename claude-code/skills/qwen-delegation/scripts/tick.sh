#!/usr/bin/env bash
# After a check: bump the ledger's audit counter and every open entry's `since`, in one step.
#   tick.sh                 a check with no recurrence
#   tick.sh L8 L10          these entries recurred: reset their `since` to 0
#   tick.sh --deep ...      a spot-check or deep check (only these count for L8/L10-style entries)
set -euo pipefail
ledger="$(dirname "$0")/../ledger.md"
python3 - "$ledger" "$@" <<'PY'
import re, sys
path, args = sys.argv[1], sys.argv[2:]
deep = "--deep" in args; recurred = {a for a in args if a != "--deep"}
diff_only = {"L8", "L10"}   # detectable only by reading the diff or probing
text = open(path).read()
text = re.sub(r"audits: (\d+)", lambda m: f"audits: {int(m.group(1)) + 1}", text, count=1)
out = []
for line in text.splitlines():
    m = re.match(r"\| (L\d+) \|", line)
    if m:
        cells = line.split("|")
        status, since = cells[-3].strip(), cells[-2].strip()
        n = re.match(r"\d+", since)
        if m.group(1) in recurred:
            cells[-2] = " 0 "; cells[-3] = " open "
        elif status == "open" and n and (deep or m.group(1) not in diff_only):
            k = int(n.group()) + 1
            cells[-2] = f" {k}{since[len(n.group()):]} "
            if k >= 5: cells[-3] = " held "
        line = "|".join(cells)
    out.append(line)
open(path, "w").write("\n".join(out) + "\n")
print(re.search(r"audits: \d+", text).group(), "| recurred:", sorted(recurred) or "none")
PY
