# ai-agent-init

Init container that delivers AI agent configuration (Claude Code skills, agents, instructions, MCP
servers) to a Dev Spaces workspace. It clones a config repo in the
[agent-plugin](https://agent-plugins.org) layout and installs it into the home directory with
[Lola](https://github.com/LobsterTrap/lola) (pinned commit, since agent-plugin support is unreleased).

## Which repo it installs

| Variable | Set by | Meaning |
|---|---|---|
| `AI_CONFIG_REPO_URL`, `AI_CONFIG_REPO_REF` | the user (Secret in their namespace) | personal config repo |
| `AI_CONFIG_DEFAULT_REPO_URL`, `AI_CONFIG_DEFAULT_REPO_REF` | the admin (ConfigMap synced to every namespace) | recommended default |

The personal pair wins when set, otherwise the default pair is used. The ref always comes from the pair
the URL came from. Nothing set: the init does nothing.

Each pair is a repo and a ref:

- `…_REPO_URL`: the git URL of the config repo, for example `https://github.com/<org>/<repo>.git`.
- `…_REPO_REF`: the git ref to check out. A branch name, a tag or a commit SHA, for example `main` or `v1.2.0`.
  Optional: with no ref the init clones the repo's default branch.
- The ref is a separate variable because Lola takes it as `--ref`. Changing only the ref (another branch or tag)
  takes the same switch path as changing the URL.

## What it does on each start

- **install**: nothing installed yet. `lola mod add`, `lola install -a claude-code -s user`.
- **update**: same source as last time. `lola mod update`, `lola update` (new commits arrive, removed skills go).
- **switch**: different source. Checks the new source is reachable, then `lola uninstall` + `lola mod rm`
  for the old module and installs the new one.

Lola writes user-scope MCP servers to `~/.mcp.json`; Claude Code reads `~/.claude.json`. `adapt_mcp.py`
syncs them and remembers which names it added, so a removed or switched-away server is removed again.
`lola_warnings.py` reports entries Lola dropped (Lola itself prints these only during `mod add`).

It never fails the workspace start because of a script failure: every failure path exits 0. The result is in
`~/.lola/.ai-agent-init-status` (`ok|failed <time> <module> origin=… mode=… warnings=… url=…`). URLs are printed
and stored without embedded credentials.

## Limits

- Claude Code only (`-a claude-code`). `settings.json` (hooks, permissions, env) is not carried.
- Reusing the name of a managed MCP server for one you added by hand lets the adapter overwrite and later remove it.
- A container that cannot start at all (image not pullable, wrong architecture) does block the workspace pod.
  Publish multi-arch (amd64 + arm64) images and pin them by digest.

## Build and test

```
docker buildx build --platform linux/amd64 --load -t ai-agent-init:dev-amd64 .
IMG=ai-agent-init:dev-amd64 PLATFORM=linux/amd64 tests/run-tests.sh
# optional: V1_IMG=<image of an earlier version> adds the upgrade test (amd64 only)
```

The tests need Docker and git. They build local fixture repos, run the image against them as uid 1000 and
check the files in the home volume (install, restart, new commit, non-default ref, personal over default and
back, unreachable repo, credentials in URLs, invalid MCP entries, items removed from the repo).

The two Python helpers (`adapt_mcp.py`, `lola_warnings.py`) also have unit tests that need no Docker and no
dependencies (standard library only):

```
python3 -m unittest discover -s tests/unit -v
```

GitHub Actions runs both layers on every pull request and on pushes to `main` (`.github/workflows/ci.yml`).
