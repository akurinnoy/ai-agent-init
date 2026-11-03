# Admin guide: enable ai-agent-init for all workspaces

`ai-agent-init` installs an AI agent configuration repo (Claude Code skills, agents, instructions, MCP
servers) into every workspace home at start. The admin sets a recommended repo; a developer can replace it
with their own. See the [repo README](../../README.md) for how the init behaves.

Two objects enable it for a whole cluster, with no che-operator or DWO code change:

| File | What it is | Where it goes |
|---|---|---|
| [`checluster-patch.yaml`](checluster-patch.yaml) | the init container, added to `devEnvironments.initContainers` | the CheCluster |
| [`workspaces-config-configmap.yaml`](workspaces-config-configmap.yaml) | the recommended repo URL and ref | the Che namespace, copied to every user namespace |

## Prerequisites

- `persistUserHome` is enabled (the Che default). What happens when it is off is not tested.
- The image is pullable from every user namespace. `quay.io/okurinny/ai-agent-init` is public (anonymous pull
  checked on 2026-11-03 for amd64 and arm64, by tag and by digest). Pin by digest.
- The image is multi-arch (amd64 and arm64). Use the same index digest in the CheCluster entry.

## Enable

1. Create the ConfigMap in the Che namespace (edit the URL and ref first):
   `oc apply -n <che-namespace> -f workspaces-config-configmap.yaml`
2. Add the init container to the CheCluster. Look at the current list first:
   `oc get checluster <name> -n <che-namespace> -o jsonpath='{.spec.devEnvironments.initContainers}'`
   - Empty or absent: `oc patch checluster <name> -n <che-namespace> --type merge --patch-file checluster-patch.yaml`
   - Already has entries: a merge patch would replace the whole list. Append instead:
     `oc patch checluster <name> -n <che-namespace> --type json -p '[{"op":"add","path":"/spec/devEnvironments/initContainers/-","value":{...the entry from checluster-patch.yaml as JSON...}}]'`
3. Start a new workspace and verify (next section).

Creating a new automount ConfigMap restarted the running workspaces in a test namespace. The sync does that in
every namespace, so apply the ConfigMap in a quiet window. This was not measured at scale.

## Verify

For a new workspace `<name>` in a user namespace:

```
oc get pod -l controller.devfile.io/devworkspace_name=<name> -o jsonpath='{.items[0].spec.initContainers[*].name}'
oc logs -l controller.devfile.io/devworkspace_name=<name> -c ai-agent-init
```

Expected log lines: `[ai-agent-init] ok module=<name> origin=default mode=install warnings=0`. Inside the
workspace, `~/.lola/.ai-agent-init-status` holds the same result. Skills are in `~/.claude/skills`, agents in
`~/.claude/agents`, MCP servers in `~/.claude.json`.

## Operate

- **Change the recommended repo:** edit the ConfigMap. Running workspaces keep the old value until they restart.
- **Change the image:** build and push a new tag, read its index digest from the registry
  (`docker buildx imagetools inspect <image>:<tag>`), and replace the digest in the CheCluster entry.
- **Roll back:** remove the entry from `initContainers`, and delete the ConfigMap so the sync removes the copies.
  Files already installed in homes stay. Not tested.

## Developer override

A developer replaces the recommended repo by creating this Secret in their namespace (the personal pair wins over
the default pair; the ref comes from the pair the URL came from):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: ai-agent-config-repo
  labels:
    controller.devfile.io/mount-to-devworkspace: "true"
    controller.devfile.io/watch-secret: "true"
  annotations:
    controller.devfile.io/mount-as: env
stringData:
  AI_CONFIG_REPO_URL: https://github.com/<user>/<config-repo>.git
  AI_CONFIG_REPO_REF: main
```

Deleting the Secret and restarting the workspace switches back to the recommended repo. Private repos work
through the git credentials the workspace already has.

## Failure behavior

- A script failure never blocks the workspace start. It is logged and written to the status file
  (`failed <time> origin=… reason=…`).
- A container that cannot start at all (image not pullable, wrong architecture) does block the pod.
- An unreachable new repo during a switch leaves the existing install in place.
- Credentials embedded in a URL are not printed or stored.

## What was tested

Tested (Docker on amd64 and arm64, and a Dev Spaces cluster with DWO 1.1.0-dev.10):
default only, personal over default, restart, a new commit, a non-default ref, switching both ways with the old
config removed (files, instructions block, MCP servers), an invalid MCP entry reported as a warning, an
unreachable repo, credentials in the URL, and upgrading a home written by the first prototype.

Read from the che-operator source, not tested on a cluster: the CheCluster `initContainers` field reaching all
workspaces, and the ConfigMap sync (labels, copy, the DWO automount labels it adds).

Not tested: a private default repo for users without access, a public default repo (anonymous clone),
`persistUserHome` off, an unpullable image or wrong architecture blocking a pod, and the restart storm at scale.

## Known gaps

- No per-user opt-out. A developer can replace the recommended repo but cannot say "no config".
- Claude Code only. `settings.json` (hooks, permissions, env) is not carried.
- Users cannot edit the synced ConfigMap copy. How the controller reverts edits was not read in detail.
