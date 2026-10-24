[![MELPA](https://melpa.org/packages/kubel-badge.svg)](https://melpa.org/#/kubel)
[![abrochard](https://circleci.com/gh/abrochard/kubel.svg?style=svg)](https://app.circleci.com/pipelines/github/abrochard/kubel)

# kubel

Emacs extension for controlling Kubernetes with limited permissions.

> **Note:** this is a vibecoded fork of [abrochard/kubel](https://github.com/abrochard/kubel),
> largely written with an AI coding assistant. On top of upstream kubel it adds
> porcelains for Argo Workflows, Cilium/Hubble, KubeVirt (virtctl), Talos
> (talosctl) and Helm, plus rollout, set image and diff before apply commands.
> See [Other tools](#other-tools).

![screenshot](screenshot.png)

You can [watch how kubel started](https://www.youtube.com/watch?v=w3krYEeqnyk) or [read about it](https://gist.github.com/abrochard/dd610fc4673593b7cbce7a0176d897de).

## Features
We now support managing pretty much any resource!

- switch context and namespace
- show any resource (pods/services/deployments/etc)
- highlight a resource by name
- copy resource name to clipboard
- show and edit resource details
- show rollout history for a resource
- delete a resource
- tail container logs (possibly with `-f` follow flag)
- copy container log command to clipboard
- port forward a pod to your localhost
- exec into a pod using tramp
- quick run shell-command
- scale replicas
- multiple kubel buffers, each one with different context, namespace, and resource.

## Installation

To use this fork with [straight.el](https://github.com/radian-software/straight.el):

```elisp
(straight-use-package
 '(kubel :type git :host github :repo "noonker/kubel"))
```

Or with `use-package`:

```elisp
(use-package kubel
  :straight (:host github :repo "noonker/kubel"))
```

Upstream kubel is on Melpa, or copy and load the `kubel.el` file.

If you want to have the evil compatibility package, get it from Melpa as well or
load the `kubel-evil.el` file.

## Setup

```elisp
(require 'kubel)
(kubel-vterm-setup) ; If you wish to have vterm as an option when using exec
```

Or if one uses `use-package`

```elisp
(use-package kubel
  :after (vterm)
  :config (kubel-vterm-setup))
```

## Usage

To list the pods in your current context and namespace, call
```
M-x kubel
```
To set said namespace and context, respectively call
```
M-x kubel-set-namespace
M-x kubel-set-context
```
Note that context will autocomplete but not necessarily namespaces
depending on your permissions and cluster setup.
See the [customize section](#Customize) on how to tune `kubel-use-namespace-list`.

To switch to showing a different resource, use the `R` command or
```
M-x kubel-set-resource
```
This will let you select a resource and re-display the kubel buffer.


To programmatically open a session for a specific context/namespace/resource, call `kubel-open` from elisp

```lisp
(kubel-open "<context>" "<namespace>" "<OPTIONAL resource>")
```

Each kubel buffer will automatically be renamed using the following template:
```
*kubel session: |<context>|<namespace>|<resource>|*
```

## Shortcuts

On the kubel screen, place your cursor on a resource
```
enter => get resource details
C-u enter => describe resource
h => help popup
? => help popup
! => quick run shell-command
E => quick edit any resource
g => refresh
k => delete popup
r => rollout popup (history, status, restart, undo to revision, pause, resume)
I => set the image of a container
p => port forward pod
l => log popup
e => exec popup
j => jab deployment to force rolling update
S => scale resource replicas
C => set context
n => set namespace
R => set resource
K => set kubectl config file
F => set output format
f => set a substring filter for resource name
M-n => jump to the next highlighted resource
M-p => jump to previous highlighted resource
m => mark item
u => unmark item
M => mark all items
U => unmark all items
c => copy popup
$ => show process buffer
s => show only resources with specified label value
```

## Editing a resource

After describing a resource in YAML format, you can edit the buffer and hit `C-c C-c` to apply your changes.
The `kubectl diff` with the live resource is shown before confirming, set
`kubel-diff-before-apply` to nil to skip it.

For example, if you want to edit a deployment, you can switch the resource with `R` and select "Deployments", then press return with the cursor on the row you wish to edit, edit the buffer, and hit `C-c C-c` to apply.

Alternatively, you can hit `E` to then select the resource type and the resource name of what you want to edit.

## Other tools

Kubel also ships porcelains for tools of the Kubernetes ecosystem. Each one is a
separate file, opens a kubel-style buffer that supports the usual marking (`m`,
`u`, `M`, `U`), filtering (`f`), context (`C`), namespace (`n`), buffer (`b`) and
process buffer (`$`) commands, and has its own help popup on `h` / `?`. When
called from a kubel buffer, they reuse its context and namespace.

```elisp
(require 'kubel-argo)    ; M-x kubel-argo
(require 'kubel-cilium)  ; M-x kubel-cilium
(require 'kubel-virtctl) ; M-x kubel-virtctl
(require 'kubel-talos)   ; M-x kubel-talos
(require 'kubel-helm)    ; M-x kubel-helm
```

They are autoloaded when installed as a package, so the `require`s are only
needed when loading the files by hand.

### Argo Workflows (`kubel-argo`, requires `argo`)
```
R => switch between workflows, cron workflows, templates and cluster templates
enter => argo get (C-u for yaml)
a => actions popup: retry, resubmit, stop, terminate, suspend, resume, submit from cron/template
l => log popup (follow, tail, container, grep, since)
w => watch workflow
k => delete popup
```

### Cilium (`kubel-cilium`, requires `cilium`, optionally `hubble`)
Lists Cilium endpoints by default.
```
R => switch to another cilium.io resource (policies, nodes, identities...)
a => cilium popup: status, features, config, version, BGP peers/routes,
     ClusterMesh and encryption status, connectivity test, sysdump, hubble UI
o => hubble observe popup for the pod under cursor, the namespace, or the cluster
```
Hubble connects to the relay of the buffer context through its own port-forward
(`-P`, on by default). Turn it off to use an already running
`cilium hubble port-forward` or the server configured for `hubble`.

### KubeVirt (`kubel-virtctl`, requires `virtctl`)
Lists virtual machines by default.
```
R => switch to another kubevirt.io resource (VMIs, data volumes, migrations...)
a => lifecycle popup: start, stop, restart, soft reboot, pause, unpause, migrate
e => console popup: serial console, ssh, vnc
i => guest info popup: OS info, filesystems, users, object graph
p => port forward VM
```

### Talos Linux (`kubel-talos`, requires `talosctl`)
In talos buffers the context is the talosctl context and the namespace is the
list of target nodes (empty to use the nodes of the talosconfig). Lists services by default.
```
R => switch to containers, k8s containers, processes or any `talosctl get rd` resource
enter => service status / resource yaml (C-u for json) / container logs
l => log popup for the service or container under cursor
S => service popup: start, stop, restart
a => node popup: dashboard, health, dmesg, events, version, memory, mounts,
     etcd members/status, reboot, shutdown
C => set talos context
n => set nodes
K => set talosconfig file
```

### Helm (`kubel-helm`, requires `helm`)
Lists the releases of all namespaces by default.
```
enter => user supplied values (C-u for all computed values)
v => get popup: values, manifest, notes, hooks, status, all
r => history popup: history, rollback to a selected revision
a => upgrade popup: reuse values (default) or values file, chart version,
     server dry run, wait, atomic; diff with the helm-diff plugin
k => uninstall popup (dry run, keep history)
G => helm repo update
n => set namespace, or *all*
```
Upgrades prompt for the chart, defaulting to the repo chart matching the release.

## Customize

- By default, kubel log tails from the last 100 lines, you can change the `kubel-log-tail-n` variable to set another line number.
- If you need to switch or set your kubectl config file by setting your `KUBECONFIG` environment variable, you can use the wrapper function `kubel-set-kubectl-config-file` or the `K` shortcut.
- Namespace listing for auto-completion is controlled by `kubel-use-namespace-list`:
  - auto - default, use `kubectl auth can-i list namespace` to determine if we can list namespaces
  - on - always assume we can list namespaces
  - off - always assume we cannot list namespaces

## Releases

See the [CHANGELOG.md](CHANGELOG.md) for the list of changes and maybe upcoming features.
