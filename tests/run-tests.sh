#!/usr/bin/env bash
# Docker tests for init.sh. Needs docker and git; fixtures are local bare repos copied into a volume.
#   IMG=ai-agent-init:dev-amd64 PLATFORM=linux/amd64 [V1_IMG=<image of an earlier version>] tests/run-tests.sh
IMG=${IMG:-ai-agent-init:dev-amd64}
PLATFORM=${PLATFORM:-linux/amd64}
V1_IMG=${V1_IMG:-}
W=$(mktemp -d "${TMPDIR:-/tmp}/ai-init-tests.XXXXXX")
RUNID=$$
SRCVOL=aiit-src-$RUNID
VOLS="$SRCVOL"
PASS=0; FAIL=0
cleanup() { docker volume rm -f $VOLS >/dev/null 2>&1; rm -rf "$W"; }
trap cleanup EXIT

DR() { docker run --rm --platform "$PLATFORM" "$@"; }
GIT() { git -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t "$@"; }
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | tail -15 | sed 's/^/       | /'; }
info() { echo "  info $1"; }

# ---- fixtures -------------------------------------------------------------------------------------
writefiles() { # DIR MODULE MARKER
  local d=$1 module=$2 marker=$3
  mkdir -p "$d/skills/$module-skill" "$d/dev.getlola/agents"
  cat > "$d/plugin.json" <<FIXEOF
{"\$schema":"https://agent-plugins.org/schemas/1.0.0/plugin.schema.json","name":"$module","version":"0.1.0","description":"test fixture $module","extensions":{"dev.getlola":{"agents":"./dev.getlola/agents","instructions":"./dev.getlola/AGENTS.md"}}}
FIXEOF
  printf -- '---\nname: %s-skill\ndescription: Marker skill for tests. Use when asked which marker is installed.\n---\n\nMarker: %s\n' "$module" "$marker" > "$d/skills/$module-skill/SKILL.md"
  printf -- '---\ndescription: Test agent %s\n---\n\nTest agent.\n' "$module" > "$d/dev.getlola/agents/$module-agent.md"
  printf '# %s instructions\n\nInstructions marker: %s\n' "$module" "$marker" > "$d/dev.getlola/AGENTS.md"
  cat > "$d/mcp.json" <<FIXEOF
{"\$schema":"https://agent-plugins.org/schemas/1.0.0/mcp.schema.json","mcpServers":{"$module-srv":{"type":"stdio","command":"node","args":["-e","process.stdin.resume()"]}}}
FIXEOF
}
publish() { # NAME: bare-clone the work repo and copy it into the source volume
  local name=$1 c=aiit-cp-$RUNID
  rm -rf "$W/bare/$name.git"; mkdir -p "$W/bare"
  git clone -q --bare "$W/work/$name" "$W/bare/$name.git"
  DR --user 0 --entrypoint sh -v "$SRCVOL:/src" "$IMG" -c "rm -rf /src/$name.git" >/dev/null 2>&1
  docker create --platform "$PLATFORM" --name "$c" --entrypoint sh -v "$SRCVOL:/src" "$IMG" >/dev/null
  docker cp "$W/bare/$name.git" "$c:/src/$name.git"
  docker rm "$c" >/dev/null
  DR --user 0 --entrypoint sh -v "$SRCVOL:/src" "$IMG" -c "chown -R 1000:1000 /src" >/dev/null 2>&1
}
mkrepo() { # NAME MODULE MARKER
  local d="$W/work/$1"; rm -rf "$d"; mkdir -p "$d"
  writefiles "$d" "$2" "$3"
  ( cd "$d" && git init -q -b main && git add -A && GIT commit -q -m "$3" )
  publish "$1"
}
bump() { # NAME MODULE MARKER [BRANCH]: new commit on BRANCH (default main); HEAD stays on main
  local d="$W/work/$1" br=${4:-main}
  ( cd "$d" && git checkout -q "$br" 2>/dev/null || git checkout -q -b "$br"
    writefiles "$d" "$2" "$3"; git add -A; GIT commit -q -m "$3"; git checkout -q main )
  publish "$1"
}

# ---- homes ----------------------------------------------------------------------------------------
hv() { echo "aiit-home-$RUNID-$1"; }
newhome() { # NAME
  local v; v=$(hv "$1"); VOLS="$VOLS $v"; docker volume create "$v" >/dev/null
  DR --user 0 --entrypoint sh -v "$v:/home/user" "$IMG" -c 'chown 1000:1000 /home/user && touch /home/user/.keep && chown 1000:1000 /home/user/.keep' >/dev/null 2>&1
}
inh() { DR --user 1000 --entrypoint sh -v "$(hv "$1"):/home/user" -v "$SRCVOL:/src" "$IMG" -c "$2" 2>&1; }
runinit() { # NAME [ENV=VAL ...] -> OUT, RC
  local h; h=$(hv "$1"); shift
  local args=(); local e; for e in "$@"; do args+=(-e "$e"); done
  OUT=$(DR --user 1000 "${args[@]}" -v "$h:/home/user" -v "$SRCVOL:/src" "$IMG" 2>&1); RC=$?
}
runinit_v1() { # NAME ENV=VAL ... with the earlier-version image
  local h; h=$(hv "$1"); shift
  local args=(); local e; for e in "$@"; do args+=(-e "$e"); done
  OUT=$(DR --user 1000 "${args[@]}" -v "$h:/home/user" -v "$SRCVOL:/src" "$V1_IMG" 2>&1); RC=$?
}
seed_user() { inh "$1" 'mkdir -p ~/.claude/skills/user-skill && printf "USERTEXT\n" > ~/.claude/CLAUDE.md && printf "name: user-skill\n" > ~/.claude/skills/user-skill/SKILL.md && printf "{\"userKey\":1,\"mcpServers\":{\"user-srv\":{\"type\":\"stdio\",\"command\":\"true\"}}}\n" > ~/.claude.json && chmod 600 ~/.claude.json' >/dev/null; }

# ---- assertions -----------------------------------------------------------------------------------
t_rc0()    { [ "$RC" = 0 ] && ok "$1: exit 0" || bad "$1: exit $RC" "$OUT"; }
t_out()    { if printf '%s' "$OUT" | grep -qF -- "$2"; then ok "$1"; else bad "$1 (output lacks: $2)" "$OUT"; fi; }
t_no_out() { if printf '%s' "$OUT" | grep -qF -- "$2"; then bad "$1 (output has: $2)" "$OUT"; else ok "$1"; fi; }
t_in()     { if inh "$1" "$3" >/dev/null 2>&1; then ok "$2"; else bad "$2" "$(inh "$1" "$3" 2>&1)"; fi; }
srv()      { echo "python3 -I -c \"import json,sys;d=json.load(open('/home/user/.claude.json'))['mcpServers'];sys.exit(0 if '$1' in d else 1)\""; }
t_srv()    { t_in "$1" "$1: MCP server $2 present" "$(srv "$2")"; }
t_no_srv() { t_in "$1" "$1: MCP server $2 absent" "! $(srv "$2")"; }
t_user_kept() { # NAME: everything the user had before is still there
  t_in "$1" "$1: user text in CLAUDE.md kept" 'grep -q USERTEXT ~/.claude/CLAUDE.md'
  t_in "$1" "$1: user skill kept" 'test -f ~/.claude/skills/user-skill/SKILL.md'
  t_in "$1" "$1: user MCP server and other keys kept" "python3 -I -c \"import json,sys;d=json.load(open('/home/user/.claude.json'));sys.exit(0 if d.get('userKey')==1 and 'user-srv' in d['mcpServers'] else 1)\""
}

echo "image: $IMG ($PLATFORM)"
docker volume create "$SRCVOL" >/dev/null

echo "T1 no config repo set"
newhome t1; runinit t1
t_rc0 T1; t_out "T1 says nothing to do" "nothing to do"; t_in t1 "T1 nothing installed" 'test ! -e ~/.lola'

echo "T2 default repo: first install"
mkrepo D d D1
newhome t2; seed_user t2
runinit t2 AI_CONFIG_DEFAULT_REPO_URL=/src/D.git
t_rc0 T2; t_out "T2 mode=install origin=default" "origin=default mode=install"
t_in t2 "T2 skill installed" 'grep -q "Marker: D1" ~/.claude/skills/d-skill/SKILL.md'
t_in t2 "T2 agent installed" 'test -f ~/.claude/agents/d-agent.md'
t_in t2 "T2 instructions block installed" 'grep -q "Instructions marker: D1" ~/.claude/CLAUDE.md'
t_srv t2 d-srv; t_user_kept t2
t_in t2 "T2 status file says ok" 'grep -q "^ok " ~/.lola/.ai-agent-init-status'
t_in t2 "T2 .claude.json mode 600" 'test "$(stat -c %a ~/.claude.json)" = 600'

echo "T3 restart, then a new commit"
runinit t2 AI_CONFIG_DEFAULT_REPO_URL=/src/D.git
t_rc0 T3; t_out "T3 restart uses the update path" "mode=update"
bump D d D2
runinit t2 AI_CONFIG_DEFAULT_REPO_URL=/src/D.git
t_rc0 T3b; t_in t2 "T3 new commit picked up (skill)" 'grep -q "Marker: D2" ~/.claude/skills/d-skill/SKILL.md'
t_in t2 "T3 new commit picked up (instructions)" 'grep -q "Instructions marker: D2" ~/.claude/CLAUDE.md'
t_user_kept t2

echo "T4 non-default ref"
mkrepo R r M1
( cd "$W/work/R" && git checkout -q -b feat )
bump R r F1 feat
newhome t4
runinit t4 AI_CONFIG_DEFAULT_REPO_URL=/src/R.git AI_CONFIG_DEFAULT_REPO_REF=feat
t_rc0 T4; t_in t4 "T4 ref honoured on install" 'grep -q "Marker: F1" ~/.claude/skills/r-skill/SKILL.md'
bump R r F2 feat
runinit t4 AI_CONFIG_DEFAULT_REPO_URL=/src/R.git AI_CONFIG_DEFAULT_REPO_REF=feat
t_rc0 T4b; t_in t4 "T4 ref honoured on update" 'grep -q "Marker: F2" ~/.claude/skills/r-skill/SKILL.md'

echo "T5 personal repo replaces the default"
mkrepo P p P1
runinit t2 AI_CONFIG_REPO_URL=/src/P.git AI_CONFIG_DEFAULT_REPO_URL=/src/D.git
t_rc0 T5; t_out "T5 reports the switch" "config source changed"; t_out "T5 origin=personal mode=switch" "origin=personal mode=switch"
t_in t2 "T5 default skill removed" 'test ! -e ~/.claude/skills/d-skill'
t_in t2 "T5 default agent removed" 'test ! -e ~/.claude/agents/d-agent.md'
t_in t2 "T5 default instructions removed" '! grep -q "d instructions" ~/.claude/CLAUDE.md'
t_in t2 "T5 personal skill installed" 'grep -q "Marker: P1" ~/.claude/skills/p-skill/SKILL.md'
t_in t2 "T5 personal instructions installed" 'grep -q "Instructions marker: P1" ~/.claude/CLAUDE.md'
t_srv t2 p-srv; t_no_srv t2 d-srv; t_user_kept t2
runinit t2 AI_CONFIG_REPO_URL=/src/P.git AI_CONFIG_DEFAULT_REPO_URL=/src/D.git
t_rc0 T5b; t_out "T5 same personal source: update path" "origin=personal mode=update"

echo "T6 personal removed: back to the default"
runinit t2 AI_CONFIG_DEFAULT_REPO_URL=/src/D.git
t_rc0 T6; t_out "T6 origin=default mode=switch" "origin=default mode=switch"
t_in t2 "T6 personal skill removed" 'test ! -e ~/.claude/skills/p-skill'
t_in t2 "T6 default skill back" 'grep -q "Marker: D2" ~/.claude/skills/d-skill/SKILL.md'
t_srv t2 d-srv; t_no_srv t2 p-srv; t_user_kept t2

echo "T7 home written by an earlier version (no source record)"
if [ -n "$V1_IMG" ] && [ "$PLATFORM" = linux/amd64 ]; then
  newhome t7a; runinit_v1 t7a AI_CONFIG_REPO_URL=/src/D.git
  t_rc0 "T7 earlier-version run"; t_in t7a "T7 earlier version installed the skill" 'test -f ~/.claude/skills/d-skill/SKILL.md'
  runinit t7a AI_CONFIG_DEFAULT_REPO_URL=/src/D.git
  t_rc0 T7a; t_out "T7 same source: update path" "mode=update"; t_in t7a "T7 record written" 'test -f ~/.lola/.ai-agent-init-source'
  newhome t7b; runinit_v1 t7b AI_CONFIG_REPO_URL=/src/D.git
  runinit t7b AI_CONFIG_DEFAULT_REPO_URL=/src/P.git
  t_rc0 T7b; t_out "T7 different source: switch" "mode=switch"; t_in t7b "T7 old skill gone, new present" 'test ! -e ~/.claude/skills/d-skill && test -f ~/.claude/skills/p-skill/SKILL.md'
else info "skipped (set V1_IMG, amd64 only)"; fi

echo "T8 invalid MCP entry (type http is not an agent-plugin type)"
mkrepo W w W1
( cd "$W/work/W" && python3 -I - <<'PYEOF'
import json
d = json.load(open("mcp.json"))
d["mcpServers"]["bad-srv"] = {"type": "http", "url": "https://example.com/mcp"}
json.dump(d, open("mcp.json", "w"))
PYEOF
  git add -A; GIT commit -q -m "bad mcp entry" )
publish W
newhome t8; runinit t8 AI_CONFIG_DEFAULT_REPO_URL=/src/W.git
t_rc0 T8; t_out "T8 Lola warning is shown in the init log" "lola:"
t_in t8 "T8 status records the warning" 'grep -Eq "warnings=[1-9]" ~/.lola/.ai-agent-init-status'
t_srv t8 w-srv; t_no_srv t8 bad-srv
runinit t8 AI_CONFIG_DEFAULT_REPO_URL=/src/W.git
t_rc0 T8b; t_out "T8 restart (update path) still reports the warning" "lola:"

echo "T9 unreachable repo"
newhome t9a; runinit t9a AI_CONFIG_REPO_URL=/src/nope.git
t_rc0 T9a; t_out "T9 failure is reported" "FAILED"; t_in t9a "T9 status says failed" 'grep -q "^failed " ~/.lola/.ai-agent-init-status'
t_in t9a "T9 nothing left registered" 'test -z "$(ls ~/.lola/modules 2>/dev/null)"'
newhome t9b; runinit t9b AI_CONFIG_DEFAULT_REPO_URL=/src/D.git
runinit t9b AI_CONFIG_REPO_URL=/src/nope.git AI_CONFIG_DEFAULT_REPO_URL=/src/D.git
t_rc0 T9b; t_out "T9 switch to an unreachable source is refused" "not reachable"
t_in t9b "T9 the working install is kept" 'test -f ~/.claude/skills/d-skill/SKILL.md'

echo "T10 credentials in the URL are never printed or stored"
newhome t10; runinit t10 AI_CONFIG_REPO_URL=https://user:SECRETTOKEN123@127.0.0.1:1/x.git
t_rc0 T10; t_no_out "T10 token not in the init log" "SECRETTOKEN123"
t_in t10 "T10 token not in the status file" '! grep -q SECRETTOKEN123 ~/.lola/.ai-agent-init-status'
t_in t10 "T10 token not anywhere in the home volume" '! grep -rq SECRETTOKEN123 /home/user'

echo "T11 things removed from the config repo"
mkrepo E e E1
( cd "$W/work/E" && mkdir -p skills/e-extra && printf -- '---\nname: e-extra\ndescription: extra skill\n---\n' > skills/e-extra/SKILL.md \
  && python3 -I - <<'PYEOF'
import json
d = json.load(open("mcp.json"))
d["mcpServers"]["e-srv2"] = {"type": "stdio", "command": "node", "args": ["-e", "1"]}
json.dump(d, open("mcp.json", "w"))
PYEOF
  git add -A; GIT commit -q -m "extras" )
publish E
newhome t11; runinit t11 AI_CONFIG_DEFAULT_REPO_URL=/src/E.git
t_rc0 T11; t_srv t11 e-srv2; t_in t11 "T11 extra skill installed" 'test -f ~/.claude/skills/e-extra/SKILL.md'
( cd "$W/work/E" && git rm -q -r skills/e-extra && python3 -I - <<'PYEOF'
import json
d = json.load(open("mcp.json")); del d["mcpServers"]["e-srv2"]; json.dump(d, open("mcp.json", "w"))
PYEOF
  git add -A; GIT commit -q -m "drop extras" )
publish E
runinit t11 AI_CONFIG_DEFAULT_REPO_URL=/src/E.git
t_rc0 T11b; t_no_srv t11 e-srv2; t_srv t11 e-srv
if inh t11 'test -e ~/.claude/skills/e-extra' >/dev/null 2>&1; then info "T11 a skill removed from the repo STAYS in ~/.claude/skills after update (Lola does not prune)"; else info "T11 a skill removed from the repo is removed by update"; fi

echo "T12 opt-out with AI_CONFIG_DISABLED=true"
newhome t12a; runinit t12a AI_CONFIG_DISABLED=true AI_CONFIG_REPO_URL=/src/nope.git
t_rc0 T12a; t_out "T12 says it is disabled" "disabled by AI_CONFIG_DISABLED=true"
t_no_out "T12 never tried the (unreachable) repo" "FAILED"
t_in t12a "T12 status says ok disabled" 'grep -Eq "^ok [^ ]+ disabled$" ~/.lola/.ai-agent-init-status'
t_in t12a "T12 nothing registered" 'test -z "$(ls ~/.lola/modules 2>/dev/null)"'
newhome t12b; seed_user t12b
runinit t12b AI_CONFIG_DEFAULT_REPO_URL=/src/D.git
t_rc0 T12b-install; t_in t12b "T12 default installed first" 'grep -q "Marker: D2" ~/.claude/skills/d-skill/SKILL.md'
bump D d D3
runinit t12b AI_CONFIG_DISABLED=true AI_CONFIG_DEFAULT_REPO_URL=/src/D.git
t_rc0 T12b-disabled; t_out "T12 disabled after an install" "left untouched"
t_in t12b "T12 installed config left in place" 'grep -q "Marker: D2" ~/.claude/skills/d-skill/SKILL.md && test -f ~/.claude/agents/d-agent.md'
t_srv t12b d-srv; t_user_kept t12b
t_in t12b "T12 no update happened (new commit not picked up)" '! grep -q "Marker: D3" ~/.claude/skills/d-skill/SKILL.md'
runinit t12b AI_CONFIG_DISABLED=true AI_CONFIG_REPO_URL=/src/P.git AI_CONFIG_DEFAULT_REPO_URL=/src/D.git
t_rc0 T12b-beats-personal; t_in t12b "T12 the flag beats a personal repo (no switch)" 'test ! -e ~/.claude/skills/p-skill && test -f ~/.claude/skills/d-skill/SKILL.md'
runinit t12b AI_CONFIG_DEFAULT_REPO_URL=/src/D.git
t_rc0 T12b-reenable; t_out "T12 re-enable resumes on the update path" "origin=default mode=update"
t_in t12b "T12 re-enable picked up the new commit" 'grep -q "Marker: D3" ~/.claude/skills/d-skill/SKILL.md'
newhome t12c; runinit t12c AI_CONFIG_DISABLED=false AI_CONFIG_DEFAULT_REPO_URL=/src/D.git
t_rc0 T12c; t_out "T12 value false does not disable" "origin=default mode=install"; t_out "T12 value false is reported as ignored" "ignored"
t_in t12c "T12 value false: config installed" 'test -f ~/.claude/skills/d-skill/SKILL.md'
newhome t12d; runinit t12d AI_CONFIG_DISABLED= AI_CONFIG_DEFAULT_REPO_URL=/src/D.git
t_rc0 T12d; t_out "T12 empty value does not disable" "origin=default mode=install"; t_no_out "T12 empty value is not reported" "ignored"

echo; echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" = 0 ]
