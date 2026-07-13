#!/usr/bin/env bash
# Capture the FULL config surface a Claude Code agent has access to, for one eval run set.
# Everything here can change agent behavior, so everything here can be the bug source.
# Usage: capture-config.sh <dest_dir> <project_cwd>
set -u
DEST="$1"; PROJ="$2"
GLOBAL="$HOME/.claude"
mkdir -p "$DEST/files"

# Directories to NEVER capture (caches, vcs, build junk, vendored deps). Edit freely.
EXCLUDE_DIRS="node_modules .git cache caches .cache dist build out .next .venv venv __pycache__ .pytest_cache tmp coverage"
PRUNE=()
for d in $EXCLUDE_DIRS; do
  [ ${#PRUNE[@]} -eq 0 ] || PRUNE+=( -o )
  PRUNE+=( -path "*/$d/*" )
done

# 1) Verbatim copies of small, high-signal, behavior-shaping config.
copy() { [ -f "$1" ] && { mkdir -p "$DEST/files/$(dirname "$2")"; cp "$1" "$DEST/files/$2"; }; }
copy "$GLOBAL/CLAUDE.md"                  "global/CLAUDE.md"
copy "$GLOBAL/settings.json"              "global/settings.json"
copy "$GLOBAL/settings.local.json"        "global/settings.local.json"
copy "$PROJ/CLAUDE.md"                    "project/CLAUDE.md"
copy "$PROJ/CLAUDE.local.md"              "project/CLAUDE.local.md"
copy "$PROJ/.claude/settings.json"        "project/settings.json"
copy "$PROJ/.claude/settings.local.json"  "project/settings.local.json"
copy "$PROJ/.mcp.json"                    "project/mcp.json"

# 2) Content-hash manifest of the config the user actually authored/installed
#    (skills/agents/commands/rules/output-styles/hooks), global + project. Text/config
#    files only. sha pins exact content without copying it.
#    NOTE: we deliberately do NOT scan plugins/cache — it's a large store of mostly-inert
#    marketplace examples. Which plugins are actually LOADED is recorded authoritatively
#    by the agent's own init event (saved separately as resolved.json).
MAX_FILES=400          # hard cap: never hash more than this many files
MAX_FILE_KB=256        # skip any single file larger than this (config is never huge)

# Gather candidate paths first (pruned dirs, size-limited), so we can enforce the cap.
list="$DEST/.filelist"; : > "$list"
gather() {
  local base="$1"
  [ -d "$base" ] || return 0
  find "$base" \( "${PRUNE[@]}" \) -prune -o \
       -type f -size -"${MAX_FILE_KB}"k \( -name '*.md' -o -name '*.json' -o -name '*.toml' \
                  -o -name '*.yaml' -o -name '*.yml' -o -name '*.sh' -o -name '*.js' \
                  -o -name '*.mjs' -o -name '*.cjs' -o -name '*.ts' -o -name '*.py' \) \
       -print 2>/dev/null >> "$list"
}
for d in skills agents commands rules output-styles hooks; do gather "$GLOBAL/$d"; done
gather "$PROJ/.claude"
sort -u -o "$list" "$list"

total=$(wc -l < "$list")
if [ "$total" -gt "$MAX_FILES" ]; then
  echo "WARNING: $total config files found, capping at $MAX_FILES — the remaining $((total-MAX_FILES)) are NOT captured. Tighten EXCLUDE_DIRS." >&2
  head -n "$MAX_FILES" "$list" > "$list.tmp" && mv "$list.tmp" "$list"
fi

manifest="$DEST/manifest.tsv"; : > "$manifest"
while IFS= read -r f; do
  printf '%s\t%s\t%s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$(wc -c < "$f")" "$f" >> "$manifest"
done < "$list"
rm -f "$list"

# 3) One fingerprint for the entire config surface (copies + manifest).
{ cat "$manifest"; find "$DEST/files" -type f -exec sha256sum {} \; 2>/dev/null; } \
  | sha256sum | cut -d' ' -f1 > "$DEST/config_sha.txt"

echo "config captured: $(wc -l < "$manifest") hashed files, config_sha=$(cut -c1-12 "$DEST/config_sha.txt")"
