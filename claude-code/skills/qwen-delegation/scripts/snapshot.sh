#!/usr/bin/env bash
# Record or compare a working directory's state for auditing a delegated task.
#   snapshot.sh save <dir>   record file list, per-file hashes, git status and HEAD
#   snapshot.sh diff <dir>   show what changed since the last save
set -euo pipefail
cmd=${1:?usage: snapshot.sh save|diff <dir>}; dir=$(cd "${2:?dir}" && pwd)
store=${TMPDIR:-/tmp}/qwen-snapshots/$(printf %s "$dir" | md5sum | cut -c1-12)
export LC_ALL=C

state() {
  (cd "$dir" && find . -path ./.git -prune -o -name __pycache__ -prune -o -name .pytest_cache -prune -o -type f -print0 \
    | sort -z | xargs -0 -r md5sum)
}

case $cmd in
  save)
    mkdir -p "$store"
    state > "$store/files"
    git -C "$dir" status --short 2>/dev/null > "$store/status" || : > "$store/status"
    git -C "$dir" rev-parse HEAD 2>/dev/null > "$store/head" || : > "$store/head"
    echo "saved $(wc -l < "$store/files") files, $(wc -l < "$store/status") dirty entries -> $store"
    ;;
  diff)
    [[ -f $store/files ]] || { echo "no snapshot for $dir" >&2; exit 1; }
    now=$(mktemp); state > "$now"
    echo "== deleted";  join -v1 -1 2 -2 2 <(sort -k2 "$store/files") <(sort -k2 "$now") | cut -d' ' -f1
    echo "== added";    join -v2 -1 2 -2 2 <(sort -k2 "$store/files") <(sort -k2 "$now") | cut -d' ' -f1
    echo "== changed";  join -1 2 -2 2 <(sort -k2 "$store/files") <(sort -k2 "$now") | awk '$2!=$3{print $1}'
    echo "== previously dirty entries (should normally still be dirty)"; cat "$store/status"
    echo "== git status now"; git -C "$dir" status --short 2>/dev/null || true
    old=$(cat "$store/head"); if [[ -n $old ]]; then echo "== commits since snapshot"; git -C "$dir" log --oneline "$old..HEAD" 2>/dev/null || true; fi
    rm -f "$now"
    ;;
  *) echo "usage: snapshot.sh save|diff <dir>" >&2; exit 2 ;;
esac
