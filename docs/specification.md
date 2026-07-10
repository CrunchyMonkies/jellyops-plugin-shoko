# JellyOps Plugin for Shoko — Specification

> Status: Draft `v0.1` · Operator API: `jellyfin.jellyops.io/v1alpha1` · **Target server: Jellyfin v12 (.NET 10)** · Target audience: platform/operations engineers running anime libraries on a jellyops-managed Jellyfin.

---

## 1. Overview & Goals

**jellyops-plugin-shoko** packages the [Shoko](https://github.com/ShokoAnime/) anime
metadata stack for delivery to a [JellyOps](../jellyops/)-managed Jellyfin instance. It is
a *plugin package* — not an operator change — expressed entirely as a `JellyfinPlugin`
custom resource that the operator already knows how to reconcile. Enabling anime metadata
becomes a single `kubectl apply`; disabling it is a `kubectl delete`.

The package delivers two things through one CR:

1. **Shokofin** — the official Jellyfin plugin (`Shokofin.dll`) that enriches an anime
   library with metadata sourced from a running **Shoko Server**. It is mounted into the
   Jellyfin pod as an OCI **image volume**.
2. **Shoko Server** *(optional, embedded mode)* — the indexing/metadata backend, deployed
   as a **companion workload** (Deployment + Service + PVC) alongside Jellyfin, exactly the
   way the reference plugin `jellycode` ships its transcode worker pool. In **external
   mode** the package deploys only Shokofin and points it at a Shoko Server you already run.

JellyOps ships **no Shoko-specific logic**. Everything below is expressed through the
generic `JellyfinPluginSpec` surface (`pluginImage`, `injection`, `meta`, `config`,
`install`, `workloads`, `services`). This document is the design contract for the package;
the operator spec ([`../jellyops/docs/specification.md`](../jellyops/docs/specification.md))
is the authority for how those fields are reconciled.

> **Targets Jellyfin v12 / .NET 10.** This package targets Jellyfin **v12** (plugin ABI
> `12.0.0.0`, framework `net10.0`) — the same server generation the reference plugin
> jellycode targets. Two consequences follow, both detailed in §4.4 and §5: the bound
> `Jellyfin` instance must run a **v12 / .NET 10 server image** (`Jellyfin.spec.image` is
> overridden, not stock 10.x), and the package consumes a **v12-rebuilt Shokofin** — the
> upstream Shokofin `dev` branch today still targets `net9;net8` / ABI `1.0.0.0`
> (Jellyfin 10.10/10.11), which the operator's ABI gate would refuse to load on a v12
> server. Producing that v12 Shokofin build is a packaging prerequisite (§5.1).

### 1.1 Goals

- **One-CR anime metadata** — a single `JellyfinPlugin` turns a plain Jellyfin instance
  into a Shoko-backed anime library.
- **Selectable topology** — `embedded` (operator also runs Shoko Server) or `external`
  (bring-your-own Shoko Server), chosen by whether the CR declares the Shoko Server
  workload/service.
- **Declarative configuration & credentials** — Shokofin's connection settings and Shoko's
  AniDB login are seeded from a Kubernetes **Secret**; no click-ops required for a
  reproducible bring-up.
- **GitOps-friendly** — image digests, config, and credentials all live in CRs/Secrets;
  upgrades are digest bumps that the operator rolls out.

### 1.2 Non-goals

- **Not a fork of Shoko or Shokofin.** The package consumes prebuilt Shokofin and Shoko
  Server images; it does not build or modify them.
- **No operator changes.** Nothing here requires JellyOps to learn about Shoko; if it did,
  the package would be wrong. All behavior rides the generic plugin contract.
- **No AniDB/TMDB account provisioning.** The user supplies AniDB credentials; the package
  only wires them in.
- **Not a stock-10.x package.** This package targets **Jellyfin v12** and, like jellycode,
  **requires a v12 / .NET 10 server image** (`Jellyfin.spec.image` overridden) plus a
  **v12-rebuilt Shokofin** (ABI `12.0.0.0`, `net10.0`). Sourcing/maintaining the v12
  Jellyfin server image is out of scope — that is the instance's prerequisite, documented
  in §4.4.

### 1.3 Glossary

| Term | Meaning |
|------|---------|
| **Shokofin** | The Jellyfin plugin (`Shokofin.dll`) that talks to Shoko Server. Delivered as an image volume. |
| **Shoko Server** | The anime indexing/metadata backend (`ghcr.io/shokoanime/server`), REST + SignalR on `:8111`. |
| **Embedded mode** | Topology where the `JellyfinPlugin` CR also deploys Shoko Server as a companion workload. |
| **External mode** | Topology where only Shokofin is delivered; it targets a pre-existing Shoko Server URL. |
| **VFS** | Shokofin's Virtual File System — a tree of symlinks it builds under Jellyfin's config so Jellyfin sees Shoko-resolved library structure. Requires a **writable** location and symlink capability. |
| **SignalR** | Realtime channel Shokofin opens to Shoko Server for file/refresh events. |
| **Identity path mapping** | The constraint that Jellyfin and Shoko Server observe the same media at the same absolute path. |

---

## 2. Personas & User Stories

- **As a platform engineer**, I apply one `JellyfinPlugin` CR and get an anime library
  whose episodes, series, images, and tags come from Shoko — including, in embedded mode, a
  Shoko Server I never had to write raw manifests for.
- **As a platform engineer**, I already run Shoko Server for other tooling, so I choose
  external mode: the CR delivers only Shokofin and points it at my existing `:8111`.
- **As a platform engineer**, I upgrade Shokofin (or Shoko Server) by bumping an image
  digest; the operator performs a controlled Jellyfin rollout / workload update and reports
  the loaded version in status.
- **As a platform engineer**, I rotate my AniDB password by updating one Secret; the next
  reconcile re-seeds it.
- **As a platform engineer**, I disable Shoko by deleting the CR; the operator removes the
  Shokofin image volume on the next rollout and gracefully drains and deletes the Shoko
  Server workload.

---

## 3. Architecture

### 3.1 Component diagram

```
                         ┌──────────────────────────────────────────────┐
   kubectl apply ─────▶  │            jellyops controller-manager        │
   JellyfinPlugin (shoko)│   JellyfinReconciler  ·  JellyfinPluginRecon. │
                         └───────────────┬──────────────────┬───────────┘
                                         │ owns/reconciles   │
        ┌────────────────────────────────┼───────────────────┼────────────────────────┐
        ▼                                ▼                    ▼                         ▼
┌──────────────────────────┐   ┌────────────────────┐  ┌──────────────┐   ┌──────────────────────┐
│ Jellyfin Deploy (:8096)  │   │ Service            │  │ PVCs:        │   │ Shoko Server Deploy  │
│  ┌────────────────────┐  │   │  shoko-server :8111│  │ jellyfin     │   │  (embedded mode)     │
│  │ init: stage copy   │  │   └─────────┬──────────┘  │ config/cache │   │  ghcr.io/shokoanime/ │
│  │ init: seed config  │  │             │             └──────────────┘   │  server  :8111       │
│  └─────────┬──────────┘  │             │                                 │  ┌────────────────┐  │
│  image volume: Shokofin  │             │  REST + SignalR (HTTP :8111)    │  │ PVC .shoko db  │  │
│  /config/plugins/Shoko_* │             └─────────────────────────────────┤  └────────────────┘  │
│  writable /config (VFS)  │◀──── Shokofin dials Shoko Server ────────────  │  media (RWX, same    │
└───────────┬──────────────┘                                                │  abs path as Jelly)  │
            │ shared RWX media (identity path)                              └──────────┬───────────┘
            └───────────────────────────────────────────────────────────────────────┘
```

Everything in the two right-hand boxes (the `shoko-server` Service, the Shoko Server
Deployment, its PVC, and the shared media mount) is **plugin-provided and present only in
embedded mode**. In external mode the CR declares no Shoko Server workload/service, and
Shokofin's `Url` points at an out-of-cluster server; the Jellyfin pod + Shokofin image
volume are all the package contributes.

### 3.2 Reconciliation & ownership

Handled entirely by the operator's existing reconcilers — the package adds no controllers:

- **`JellyfinReconciler`** composes the Jellyfin pod template: base container + config/cache
  PVCs + the Shokofin image volume + the `imageVolumeCopy` staging init container + the
  `spec.install` config-seed init container.
- **`JellyfinPluginReconciler`** validates ABI (`meta.targetAbi 12.0.0.0` vs the running
  v12 Jellyfin), and — in embedded mode — owns the Shoko Server Deployment and Service, wiring
  owner references and a finalizer for graceful teardown.
- Reconcilers are level-triggered and idempotent; a bad plugin never takes the instance
  down (fail-open for the instance, fail-closed for the plugin).

### 3.3 Plugin lifecycle state machine

Reused verbatim from the operator (`../jellyops/docs/specification.md` §3.3), with the
`Installing` phase carrying Shoko's config seed:

```
 Pending ──ABI ok & image valid──▶ Injecting ──files staged──▶ Installing
                                                                   │ seed Shokofin.xml / AniDB
                                                                   ▼
                                                            WorkloadsReady ──Shoko :8111 ready──▶ Loaded
```

`WorkloadsReady` gates on the Shoko Server Deployment reaching its desired ready replicas
(embedded mode); in external mode there is no workload, so the phase passes through once the
files are staged and config seeded. Each transition is a `status.condition` + Kubernetes
`Event` on the `JellyfinPlugin`.

### 3.4 Networking

- **Jellyfin HTTP** `:8096` — unchanged; the operator's only required port.
- **Shoko Server** `:8111` — REST API **and** SignalR. In embedded mode the package
  declares a `ClusterIP` Service (`spec.services[]`); Shokofin resolves it at
  `http://shoko-server.<ns>.svc:8111`. In external mode this is a user-provided URL.
- **Direction** — Shokofin is the client: it *dials* Shoko Server. Shoko Server needs no
  inbound access to Jellyfin.
- **Operator → instance API** — untouched; if `Jellyfin.spec.api` is set, the operator's
  `JellyfinAPIReconciler` still manages libraries over `:8096`.
- **NetworkPolicy** (recommended, §10) — confine `:8111` to the Jellyfin pod (and, if you
  expose the Shoko web UI, an ingress).

---

## 4. The `JellyfinPlugin` Resource for Shoko

CRD group `jellyfin.jellyops.io/v1alpha1`. The package is one `JellyfinPlugin` object. The
only difference between topologies is whether `spec.workloads`/`spec.services` (the Shoko
Server) are present.

### 4.1 Embedded mode (default — operator runs Shoko Server)

```yaml
apiVersion: jellyfin.jellyops.io/v1alpha1
kind: JellyfinPlugin
metadata:
  name: shoko
  namespace: media
  labels:
    jellyfin.jellyops.io/instance: home-media
spec:
  jellyfinRef: { name: home-media }

  # ── Shokofin plugin files (image volume) ──────────────────────────────
  pluginImage:
    reference: ghcr.io/crunchymonkies/shokofin-plugin@sha256:<digest>
    pullPolicy: IfNotPresent
    subPath: /plugin                       # Shokofin.dll + deps live under /plugin (§5)
  meta:
    guid: 5216ccbf-d24a-4eb3-8a7e-7da4230b7052
    name: "Shoko"
    version: "<shokofin-v12-version>"       # → on-disk folder "Shoko_<version>"
    targetAbi: "12.0.0.0"                    # Jellyfin v12; bound instance MUST be a v12 build (§4.4)
    framework: "net10.0"
  injection: imageVolumeCopy               # writable plugin dir: Jellyfin writes meta.json
                                           # status AND Shokofin builds a VFS of symlinks (§5.2)

  # ── Seed Shokofin's Shokofin.xml (declarative) ────────────────────────
  # NOTE: Jellyfin derives the file name from the Shokofin.dll assembly -> Shokofin.xml,
  # and PluginConfiguration maps Url -> <Host> and PublicUrl -> <PublicHost>.
  config:                                  # rendered into /config/plugins/configurations/Shokofin.xml
    <PluginConfiguration>
      <Host>http://shoko-server.media.svc:8111</Host>
      <SignalR_AutoConnectEnabled>true</SignalR_AutoConnectEnabled>
      <SignalR_RefreshEnabled>true</SignalR_RefreshEnabled>
      <SignalR_FileEvents>true</SignalR_FileEvents>
    </PluginConfiguration>

  # ── Seed config + inject the API key before Jellyfin starts (§8) ──────
  install:
    # No inline script. jellyops auto-runs the standard hooks baked into the plugin
    # image (firstrun.sh once, bootstrap.sh every start) from the staged plugin dir;
    # this block only supplies the helper image + env/secrets they read.
    image:
      reference: alpine:3
    env:
      - name: SHOKO_URL
        value: http://shoko-server.media.svc:8111
      - name: ANIDB_USERNAME
        valueFrom: { secretKeyRef: { name: shoko-creds, key: anidb-username } }
      - name: ANIDB_PASSWORD
        valueFrom: { secretKeyRef: { name: shoko-creds, key: anidb-password } }
      - name: SHOKO_USERNAME
        valueFrom: { secretKeyRef: { name: shoko-creds, key: shoko-username } }
      - name: SHOKO_PASSWORD
        valueFrom: { secretKeyRef: { name: shoko-creds, key: shoko-password } }
    runOnce: true                          # marker under /config; skip on later restarts
    failurePolicy: Ignore                  # Jellyfin still boots if bootstrap fails (fail-open)
    timeoutSeconds: 300

  # ── Shoko Server companion workload + service (embedded only) ─────────
  services:
    - name: shoko-server
      selector: workload                   # points at the shoko-server pods
      ports: [{ name: http, port: 8111, targetPort: 8111 }]
  workloads:
    - name: shoko-server
      image:
        reference: ghcr.io/shokoanime/server@sha256:<digest>
        pullPolicy: IfNotPresent
      replicas: 1                          # Shoko Server is single-writer (SQLite by default)
      ports: [{ name: http, containerPort: 8111 }]
      env:
        - { name: PUID, value: "1000" }
        - { name: PGID, value: "100" }
        - { name: TZ,   value: "Etc/UTC" }
      resources:
        requests: { cpu: "250m", memory: 512Mi }
      volumeMounts:
        - { name: shoko-config, mountPath: /home/shoko/.shoko }   # db + config + images (PVC)
        - { name: media,        mountPath: /media, readOnly: true } # SAME abs path as Jellyfin (§7)
```

> **PVC for `/home/shoko/.shoko`.** The Shoko Server workload needs a persistent claim for
> its database/config/images. It is declared as a `PluginWorkload` volume mount backed by a
> PVC the operator provisions and owns (see the operator's `PVCSpec` handling). `shm_size`
> ≈ 256Mi is recommended by Shoko for hashing; express it via an `emptyDir` `medium: Memory`
> volume at `/dev/shm` if the workload image honors it.

### 4.2 External mode (bring-your-own Shoko Server)

Identical to §4.1 **minus** `spec.workloads` and `spec.services`, with `config.Url` (and the
install hook's `SHOKO_URL`) pointing at the existing server:

```yaml
spec:
  jellyfinRef: { name: home-media }
  pluginImage:
    reference: ghcr.io/crunchymonkies/shokofin-plugin@sha256:<digest>
    subPath: /plugin
  meta: { guid: 5216ccbf-d24a-4eb3-8a7e-7da4230b7052, name: "Shoko", version: "<v>", targetAbi: "12.0.0.0", framework: "net10.0" }
  injection: imageVolumeCopy
  # Config is seeded by the baked firstrun.sh hook (auto-run by jellyops), which
  # writes <Host>/<PublicHost>/<SignalR_*> into Shokofin.xml from the env below.
  install:
    image:
      reference: alpine:3
    env:
      - { name: SHOKO_URL, value: http://shoko.lan:8111 }
      - name: SHOKO_APIKEY                 # external servers often already have a key
        valueFrom: { secretKeyRef: { name: shoko-creds, key: shoko-apikey } }
    runOnce: true
    failurePolicy: Ignore
  # no workloads / services — Shoko Server is managed outside the cluster
```

### 4.3 Field mapping

| Shoko package need | `JellyfinPluginSpec` field | Notes |
|--------------------|----------------------------|-------|
| Deliver `Shokofin.dll` | `pluginImage` + `meta` | image volume; `subPath: /plugin` |
| Writable plugin dir (VFS, meta.json) | `injection: imageVolumeCopy` | §5.2 |
| Point Shokofin at Shoko | `config` (`<Host>…`) | seeds `Shokofin.xml` (assembly-derived name; `Url`→`<Host>`, `PublicUrl`→`<PublicHost>`) |
| Inject API key / first-run | `install` (init container) + Secret | §8 |
| Run Shoko Server (embedded) | `workloads[]` | Deployment owned by operator |
| Expose Shoko `:8111` (embedded) | `services[]` | `ClusterIP` |

### 4.4 Jellyfin v12 prerequisite & ABI gate

This package targets **Jellyfin v12 / .NET 10**, so — exactly like jellycode (operator
spec §4.4) — the bound instance is **not** stock 10.x:

- **The bound `Jellyfin` instance must run a v12 / .NET 10 server image.** Set
  `Jellyfin.spec.image` to a v12 build (e.g. the `crunchymonkies` v12 image the local
  `jellyfin-src` tree carries, `AssemblyVersion 12.0.0`). Sourcing and maintaining that
  server image is the *instance's* prerequisite, out of scope for this package.
- **Generic ABI gate.** The operator validates `meta.targetAbi (12.0.0.0)` against the
  running server. On a stock 10.x server the gate marks the Shoko plugin `Failed` and emits
  an event — it never mounts an unloadable plugin, and never takes the instance down.
- **A v12-rebuilt Shokofin is required.** Upstream Shokofin's `dev` branch still targets
  `net9;net8` against `Jellyfin.Controller 10.11.11 / 10.10.7` with `targetAbi 1.0.0.0`
  (`../Shokofin/Shokofin/Shokofin.csproj`, `../Shokofin/build.yaml`) — that build **will
  not load on v12**. The package therefore consumes a Shokofin recompiled for v12
  (`TargetFramework net10.0`, the v12 `Jellyfin.Controller`, `targetAbi 12.0.0.0`); see
  §5.1. Until upstream ships v12 support, producing this build is part of packaging.

---

## 5. Shokofin Plugin Packaging

The `pluginImage` is an ordinary OCI image whose filesystem contains one Jellyfin plugin
directory — the same contract as any jellyops plugin (`../jellyops/docs/specification.md`
§5).

### 5.1 Image layout

- Place `Shokofin.dll` and its runtime dependencies under **`/plugin`** in the image and
  set `pluginImage.subPath: /plugin`. (Root-level is also valid; `/plugin` is the
  recommended convention.)
- The on-disk folder the operator mounts is **`Shoko_<version>`**, derived from
  `meta.name`/`meta.version` — matching how Jellyfin names plugin folders.
- Build artifacts come from a **v12 build of Shokofin** — the same `Shokofin.dll` (+ deps)
  the project's build produces (`../Shokofin/build.yaml`), but recompiled for
  `TargetFramework net10.0` against the **v12 `Jellyfin.Controller`**, with `build.yaml`
  `targetAbi` bumped to `12.0.0.0`. The package repackages that output into an image layer
  instead of a zip. (Upstream `dev` targets `net9;net8` / ABI `1.0.0.0` today — §4.4 —
  so this v12 build is produced as part of packaging until upstream ships it.)

### 5.2 Injection mode — `imageVolumeCopy` (required)

Image volumes are **read-only**, but Shokofin needs a **writable** plugin/config area for
two reasons:

1. Jellyfin writes plugin **status back into `meta.json`** on load (the generic caveat,
   operator spec §6.2).
2. Shokofin builds a **VFS of symlinks** (`VFS_*`, `CanCreateSymbolicLinks`) that Jellyfin
   traverses; this tree must be created on a writable, symlink-capable filesystem.

`injection: imageVolumeCopy` mounts the image read-only at a staging path and copies it into
the writable `/config` plugins dir via an init container before Jellyfin boots. The image
volume stays the immutable, digest-pinned source of truth; the writable copy exists only so
Jellyfin and Shokofin can mutate runtime state. Plain `imageVolume` is **not recommended**
here because of the VFS write requirement (tracked in §13).

### 5.3 Image labels (self-description)

Mirror `meta.json` as image labels so the operator can validate without unpacking:

| Label | Value |
|-------|-------|
| `io.jellyops.plugin.guid` | `5216ccbf-d24a-4eb3-8a7e-7da4230b7052` |
| `io.jellyops.plugin.name` | `Shoko` |
| `io.jellyops.plugin.version` | `<shokofin-v12-version>` |
| `io.jellyops.plugin.targetAbi` | `12.0.0.0` |
| `io.jellyops.plugin.framework` | `net10.0` |
| `io.jellyops.plugin.subPath` | `/plugin` |

---

## 6. Shoko Server Companion Workload (embedded mode)

Modeled as one generic `PluginWorkload` + one `PluginService`; the operator owns both.

- **Image** — `ghcr.io/shokoanime/server` (digest-pinned). Docker Hub `shokoanime/server`
  is an equivalent source.
- **Port** — `8111` (Web UI, REST `/api/v3`, and SignalR share this port).
- **Config/data** — a PVC mounted at **`/home/shoko/.shoko`** holds the SQLite database,
  configuration, and downloaded images. Persisting this is mandatory; losing it forces a
  re-index.
- **Env** — `PUID`/`PGID` (file ownership for the shared media mount) and `TZ`.
- **Media** — mounted at the **same absolute path** the Jellyfin pod uses (§7), read-only
  is fine for indexing/hashing.
- **Replicas** — `1`. Shoko Server is single-writer against its database; do not scale.
- **Readiness probe** — HTTP GET on `:8111` (e.g. `/api/v3/Init/Status`); `WorkloadsReady`
  gates on this.

Shokofin resolves the server through the Service DNS name
`http://shoko-server.<namespace>.svc:8111`, which is what `spec.config.<Url>` and the
install hook's `SHOKO_URL` are set to in §4.1.

---

## 7. Shared Media & Path Mapping

Shoko Server **indexes files by absolute path** and hashes them; Shokofin then exposes those
files to Jellyfin (directly or via its VFS symlinks) using paths Shoko reported. For the
links to resolve, **Jellyfin and Shoko Server must see the same media at the same absolute
path** — identity path mapping, the same constraint jellycode documents for its workers
(operator spec §8.2).

Recommendations:

- **Shared RWX media.** Back the anime library with an NFS media folder using
  `nfs.provision: true` on the `Jellyfin` CR (operator spec §4.5), which yields a
  `ReadWriteMany` PV/PVC the operator can mount into **both** the Jellyfin pod and the Shoko
  Server workload at an identical `mountPath` (e.g. `/media/anime`). An existing RWX PVC
  works equally well.
- **Identical mount paths.** The `volumeMounts[].mountPath` for media on the Shoko Server
  workload (§4.1) must byte-for-byte match the Jellyfin instance's library `mountPath`.
- **Read-only media.** Mount media read-only on both sides; Shoko only needs to read to
  hash/index, Jellyfin only to play.
- **VFS location.** Shokofin's VFS lives under Jellyfin's writable `/config` by default
  (`VFS_CustomLocation` can relocate it); it does not need to be shared with Shoko Server.

External mode inherits the same rule: the external Shoko Server must have indexed the media
at paths that match the Jellyfin pod's view, or Shokofin's links will not resolve.

---

## 8. Configuration & Credential Bootstrap (declarative)

The package seeds all runtime configuration from Kubernetes objects so a bring-up is
reproducible. Two layers: a **declarative XML seed** (`spec.config`) and an **imperative
install hook** (`spec.install`) that injects secrets and drives Shoko's first-run.

### 8.1 The Secret

```yaml
apiVersion: v1
kind: Secret
metadata: { name: shoko-creds, namespace: media }
type: Opaque
stringData:
  anidb-username: "<anidb-user>"       # embedded first-run login
  anidb-password: "<anidb-pass>"
  shoko-username: "Default"            # Shoko local user (embedded first-run)
  shoko-password: "<shoko-pass>"
  shoko-apikey:   "<existing-key>"     # external mode, or after first mint
```

Keys are consumed via `secretKeyRef` in `spec.install.env` (§4.1). The operator's RBAC for
Secrets is scoped to watched namespaces; the values are never written to status or logs.

### 8.2 What the install hook does

The install init container runs before Jellyfin starts, in the Jellyfin image (so it sees
the real `/config` layout), with `runOnce: true` and `failurePolicy: Ignore`:

1. **Wait** for `SHOKO_URL` `:8111` to answer (`/api/v3/Init/Status`).
2. **Embedded first-run** (only if the server reports uninitialized): create the initial
   Shoko user and register the **AniDB** login from `ANIDB_USERNAME`/`ANIDB_PASSWORD` via
   Shoko's REST init endpoints.
3. **Obtain an API key** — authenticate as `SHOKO_USERNAME`/`SHOKO_PASSWORD` and mint (or
   reuse) an API key; in external mode, use `SHOKO_APIKEY` directly.
4. **Patch** `<ApiKey>` and `<Username>` into the already-seeded
   `/config/plugins/configurations/Shokofin.xml`.
5. **Marker** — drop the `runOnce` marker under `/config` so restarts don't repeat first-run.

Because `failurePolicy: Ignore`, a bootstrap failure emits a `Warning` event and leaves the
`Installed` condition false, but **Jellyfin still boots** — the operator's fail-open bias for
the instance is preserved. Set `failurePolicy: Fail` only if a missing API key should block
startup.

### 8.3 Manual fallback

If you prefer click-ops (or the automated first-run proves brittle across Shoko versions —
§14): omit the AniDB env and the bootstrap script, apply the CR, then

1. open Shoko Server `:8111`, complete the web-UI first-run + AniDB login, and copy an API
   key; and
2. open Jellyfin → Shokofin config and paste the `Url` + API key (or pre-seed `Url` via
   `spec.config` and paste only the key).

The CR still wires all networking and storage; only credential entry is manual.

---

## 9. Lifecycle, Rollout & Teardown

- **Load is startup-only.** Jellyfin discovers plugins at boot, so enabling, upgrading, or
  reconfiguring Shokofin is a **controlled Jellyfin Deployment rollout**, not a hot-reload.
  Status walks `Injecting → Installing → Loaded`.
- **Upgrades** — bump `pluginImage.reference` (new digest) to upgrade Shokofin, or the
  `workloads[].image` digest to upgrade Shoko Server. The operator re-stages / updates and
  reports the new version in `Jellyfin.status.loadedPlugins`.
- **Teardown** — deleting the `JellyfinPlugin` removes the Shokofin image volume on the next
  Jellyfin rollout and, in embedded mode, the operator's **finalizer** gracefully terminates
  the Shoko Server workload (scale-down honoring `terminationGracePeriodSeconds`) before
  deleting its Deployment and Service. The Shoko Server PVC persists per its reclaim policy
  so an accidental delete doesn't destroy the index.

### 9.1 Status conditions (operator-provided)

| Condition | Meaning for this package |
|-----------|--------------------------|
| `ABICompatible` | `12.0.0.0` matches the running Jellyfin v12 server. |
| `Injected` | Shokofin files present in the running Jellyfin pod. |
| `Installed` | Config seed + credential bootstrap succeeded (or was skipped via `runOnce`). |
| `WorkersAvailable` | Embedded Shoko Server Deployment meets desired ready replicas (always satisfied in external mode). |

---

## 10. Security & Hardening

- **Credentials in Secrets only** — AniDB and Shoko credentials live in `shoko-creds`;
  injected via `secretKeyRef`, never baked into the image or CR, never logged/statused.
- **NetworkPolicy** — confine Shoko Server `:8111` to the Jellyfin pod (label selector) and,
  if you expose the Shoko web UI, an ingress controller. Deny other ingress to `:8111`.
- **Non-root Shoko Server** — run under `PUID`/`PGID`; drop capabilities; apply a
  `RuntimeDefault` seccomp profile. Media mounted read-only.
- **Digest-pinned images** — reference both the Shokofin plugin image and
  `ghcr.io/shokoanime/server` by `@sha256:…` for immutable, reproducible rollouts;
  cosign verification is a Phase 2 admission gate (operator spec §9).
- **Plugin trust** — only cluster admins create `JellyfinPlugin`s; the image volume is
  read-only source of truth (the writable copy is derived at boot).

---

## 11. Observability

- **Shoko Server health** — probe `:8111` init/queue status; alert on the readiness probe
  and on hashing/import queue backlog (surfaced via Shoko's own API/metrics if enabled).
- **Shokofin ↔ Shoko link** — the `SignalR` connection state is the key liveness signal for
  metadata freshness; surface `Installed=false` / repeated bootstrap `Warning` events.
- **Operator surface** — the plugin's phase conditions/events (§9.1) make `kubectl describe
  jellyfinplugin shoko` the primary debugging view; alert on `WorkersAvailable=false`
  (embedded) and `ABICompatible=false`.

---

## 12. Compatibility & Versioning

- **ABI / framework** — this package's Shokofin is built for **Jellyfin v12**:
  `targetAbi 12.0.0.0`, framework `net10.0`, compiled against the v12 `Jellyfin.Controller`.
  The bound `Jellyfin` instance **must** be a v12 / .NET 10 server image
  (`Jellyfin.spec.image` overridden — §4.4). For reference, upstream Shokofin `dev` currently
  targets `net9;net8` / `Jellyfin.Controller 10.11.11`/`10.10.7` / ABI `1.0.0.0`
  (`../Shokofin/Shokofin/Shokofin.csproj`) — a 10.x build, not compatible with v12.
- **Shokofin ↔ Shoko Server** — pin a tested pair (Shokofin version ↔ Shoko Server version)
  and upgrade them together; Shokofin's API expectations track Shoko Server's REST/SignalR
  surface.
- **Image-volume prerequisites** — inherited from the operator: image volumes are beta in
  Kubernetes **1.33** (GA **1.36**) and require a CRI runtime with image-volume support
  (recent containerd/CRI-O). A hard cluster prerequisite for the delivery mechanism.

---

## 13. Roadmap / Phasing

- **Phase 1 (this spec)** — embedded and external topologies via one `JellyfinPlugin`;
  Shokofin delivered as `imageVolumeCopy`; Shoko Server companion workload + Service + PVC;
  declarative `Shokofin.xml` seed + Secret-driven credential/first-run install hook; identity
  path mapping; status via operator conditions.
- **Phase 2** — hardened, well-tested first-run automation across Shoko versions; a
  `ClusterJellyfinPluginType` catalog entry so the CR is boilerplate-free; investigate a
  read-only VFS location so plain `imageVolume` becomes viable; optional Shoko web-UI ingress
  with auth; richer observability (queue-depth metrics, Grafana dashboard); shared Shoko
  Server across multiple Jellyfin instances.

---

## 14. Open Questions / Risks

- **v12 Shokofin availability** — no upstream Shokofin build targets Jellyfin v12 / `net10.0`
  yet (`dev` is `net9;net8` / ABI `1.0.0.0`). The package depends on a v12 recompile (§5.1);
  its stability tracks how cleanly Shokofin's source ports to the v12 `Jellyfin.Controller`
  API surface. Any breaking API change upstream between now and v12 GA may require patches.
- **v12 ABI churn** — Jellyfin v12 is pre-release; its plugin ABI (`12.0.0.0`) and .NET 10
  runtime can still shift. Pin the Shokofin plugin image, the Shoko Server image, **and** the
  v12 Jellyfin server image by digest, and re-validate the ABI gate on every server bump.
- **Writable plugin dir for the VFS** — Shokofin's symlink VFS requires a writable,
  symlink-capable location; `imageVolumeCopy` provides it under `/config`. Confirm the
  target Jellyfin image permits symlink creation there; if a read-only VFS location is
  possible, plain `imageVolume` could become the default (Phase 2).
- **AniDB ban risk** — a first mass-index/hash can trip AniDB rate limits/bans if
  misconfigured. The package must not hammer AniDB; the install hook only *registers*
  credentials and lets Shoko schedule work per its own throttling.
- **First-run automation stability** — Shoko's init/REST surface can change between versions;
  the bootstrap script (§8.2) is the most version-sensitive component. `failurePolicy:
  Ignore` + the manual fallback (§8.3) contain the blast radius.
- **Identity path mapping** — Shokofin links resolve only if Jellyfin and Shoko Server share
  absolute media paths. The package must validate/document matching mount paths; non-identity
  mapping is out of scope until Shoko/Shokofin expose translation.
- **Single-writer Shoko Server** — the SQLite-backed server is `replicas: 1`; HA/shared Shoko
  is a Phase 2 concern, not a Phase 1 guarantee.

---

## Appendix A — Source-of-truth references

Every concrete value asserted above traces to a file in a sibling repo or the Shoko docs.

| Claim | Source of truth |
|-------|-----------------|
| guid `5216ccbf-d24a-4eb3-8a7e-7da4230b7052`, name `Shoko`, artifact `Shokofin.dll` | `../Shokofin/build.yaml`, `../Shokofin/manifest.json` |
| Connection fields `Url`/`PublicUrl`/`ApiKey`/`Username`/`WebPrefix`; SignalR + VFS config; `<PluginConfiguration>` XML root | `../Shokofin/Shokofin/Configuration/PluginConfiguration.cs` |
| **Target: Jellyfin v12** (server `AssemblyVersion 12.0.0`) | `../jellyfin-src/SharedVersion.cs` |
| **Target ABI `12.0.0.0` / framework `net10.0`** (peer plugin precedent) | `../jellycode/src/Plugin/meta.json` |
| Current upstream Shokofin targets `net9;net8` / `Jellyfin.Controller 10.11.11`/`10.10.7` / ABI `1.0.0.0` (the 10.x build this package must **replace** with a v12 rebuild) | `../Shokofin/Shokofin/Shokofin.csproj`, `../Shokofin/build.yaml` |
| Shoko Server image `ghcr.io/shokoanime/server`, port `8111`, config `/home/shoko/.shoko`, env `PUID`/`PGID`/`TZ`, `shm_size 256m`, media mount | Shoko docs — *Installing Shoko Server* (docker compose) |
| `JellyfinPluginSpec` fields (`pluginImage`/`injection`/`meta`/`config`/`install`/`workloads`/`services`), image-volume mechanics, path-mapping precedent, lifecycle/finalizer semantics | `../jellyops/docs/specification.md` §4, §5, §6, §7, §8 |
