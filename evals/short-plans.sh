#!/usr/bin/env bash
# TDD test for the "Plans" rule in ~/.claude/CLAUDE.md: a plan should be short (<= MAX_BULLETS).
# Runs the prompt N times IN PARALLEL and stores EVERYTHING that produced the result:
#   input (prompt), config/state (CLAUDE.md snapshot + full run JSON), output (result text),
#   plus per-run model / timing / cost / session id.
set -u

PROMPT="I want to add JWT authentication to a Node/Express API. Before writing any code, give me your implementation plan."
MAX_BULLETS=8
RUNS=5
NEED=4
CLAUDE_MD="$HOME/.claude/CLAUDE.md"

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(dirname "$ROOT")"          # project root = where the agent runs
cd "$PROJECT"                          # deterministic cwd for every claude run
STAMP=$(date +%Y%m%dT%H%M%S)
DIR="$ROOT/results/${STAMP}_short-plans"
mkdir -p "$DIR"

# --- capture input + config/state under test ---
printf '%s\n' "$PROMPT" > "$DIR/input.txt"
cp "$CLAUDE_MD" "$DIR/claude.md"
SHA=$(sha256sum "$CLAUDE_MD" | cut -d' ' -f1)

# --- run N in parallel, each full JSON blob saved verbatim ---
t0=$SECONDS
for i in $(seq 1 $RUNS); do
  claude -p "$PROMPT" --output-format json > "$DIR/run-$i.json" 2>&1 &
done
wait
WALL=$((SECONDS - t0))

# --- capture the FULL config surface the agent had access to ---
bash "$ROOT/capture-config.sh" "$DIR/config" "$PROJECT"
jq '.[0]' "$DIR/run-1.json" > "$DIR/config/resolved.json"   # init event = what the agent loaded
CONFIG_SHA=$(cat "$DIR/config/config_sha.txt")

# --- score + per-run detail from the saved blobs (no re-runs) ---
pass=0
: > "$DIR/runs.ndjson"
for i in $(seq 1 $RUNS); do
  f="$DIR/run-$i.json"
  jq -r '.[-1].result // ""' "$f" > "$DIR/result-$i.txt"          # readable output artifact
  n=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]' "$DIR/result-$i.txt")
  short=$([ "$n" -le "$MAX_BULLETS" ] && echo true || echo false)
  [ "$short" = true ] && pass=$((pass+1))
  jq -n --argjson run "$i" --argjson bullets "$n" --argjson short "$short" \
        --arg  model   "$(jq -r '.[0].model         // "?"' "$f")" \
        --arg  session "$(jq -r '.[-1].session_id    // "?"' "$f")" \
        --argjson dur  "$(jq -r '.[-1].duration_ms   // 0'   "$f")" \
        --argjson cost "$(jq -r '.[-1].total_cost_usd // 0'  "$f")" \
    '{run:$run,bullets:$bullets,short:$short,model:$model,session_id:$session,duration_ms:$dur,cost_usd:$cost}' \
    >> "$DIR/runs.ndjson"
  echo "run $i: bullets=$n short=$short"
done

verdict=$([ "$pass" -ge "$NEED" ] && echo GREEN || echo RED)
runs_detail=$(jq -s '.' "$DIR/runs.ndjson")
MODEL=$(jq -r '.[0].model // "unknown"' "$DIR/run-1.json")

# --- summary.json + append to history log ---
jq -n --arg stamp "$STAMP" --arg test short-plans --arg model "$MODEL" \
      --arg sha "$SHA" --arg config_sha "$CONFIG_SHA" --arg verdict "$verdict" \
      --argjson parallel true --argjson concurrency "$RUNS" --argjson wall_s "$WALL" \
      --argjson max "$MAX_BULLETS" --argjson need "$NEED" --argjson runs "$RUNS" \
      --argjson pass "$pass" --argjson detail "$runs_detail" \
  '{stamp:$stamp,test:$test,model:$model,claude_md_sha:$sha,config_sha:$config_sha,
    parallel:$parallel,concurrency:$concurrency,wall_s:$wall_s,max_bullets:$max,need:$need,
    runs:$runs,pass:$pass,verdict:$verdict,runs_detail:$detail}' \
  | tee "$DIR/summary.json" >> "$ROOT/results/history.jsonl"

echo "----"
echo "$verdict  $pass/$RUNS short (need $NEED)  ${WALL}s wall (parallel x$RUNS)  cfg=${CONFIG_SHA:0:12}"
echo "saved: $DIR"
[ "$pass" -ge "$NEED" ]
