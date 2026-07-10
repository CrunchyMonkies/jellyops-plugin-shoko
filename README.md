# jellyops-plugin-shoko

A [JellyOps](../jellyops) plugin package that delivers the **[Shokofin](https://github.com/ShokoAnime/Shokofin)**
Jellyfin plugin — and, optionally, a **[Shoko Server](https://shokoanime.com/)** — to a
JellyOps-managed **Jellyfin v12 (.NET 10)** instance as a `JellyfinPlugin` custom resource.

It is the Shoko analogue of the reference [`jellycode`](../jellycode) package: the operator
ships no Shoko-specific logic; everything here rides the generic plugin contract
(`pluginImage`, `injection`, `meta`, `install`, `workloads`, `services`).

See [`docs/specification.md`](docs/specification.md) for the full design.

## What it delivers

- **Shokofin** as an OCI **image-volume** payload (mounted read-only, staged into the
  writable plugins dir via `injection: imageVolumeCopy`).
- **Embedded mode** (default): a **Shoko Server** companion workload + Service + config PVC.
- **External mode**: Shokofin only, pointed at an existing Shoko Server.
- Declarative **config + credential bootstrap** via jellyops **standard hook scripts
  baked into the plugin image** (the JellyOps CRD has no `spec.config`). The operator
  auto-runs `firstrun.sh` (once per instance — seeds `Shokofin.xml` + mints the API key)
  and `bootstrap.sh` (every start — re-asserts the connection); the CR only supplies
  env/secrets via `install.env`. Jellyfin reads Shokofin's config from `Shokofin.xml`
  (name derived from the `Shokofin.dll` assembly) and maps the connection URL to the
  `<Host>` element and the public URL to `<PublicHost>`. Beyond the connection/SignalR
  settings, `firstrun.sh` can optionally seed library-structure, VFS, third-party-ID and
  tag/genre/collection settings via `SHOKO_*` env vars (see `scripts/firstrun.sh`);
  anything left unset keeps Shokofin's built-in default.

## Layout

```
docker/
  Dockerfile.plugin      FROM scratch; plugin dir (Shokofin.dll + deps + meta.json + hook scripts) at root
  build-push.sh          download the Shokofin release zip, bake in the hooks -> build --provenance=false -> push
scripts/
  firstrun.sh            baked once-per-instance hook: seed Shokofin.xml + mint API key
  bootstrap.sh           baked every-start hook: re-assert the Shoko connection
k8s/                     namespace, PVCs, Secret, Jellyfin CR, JellyfinPlugin CR (embedded + external), NetworkPolicy
.github/workflows/
  plugin-image.yml       CI: package the Shokofin release into the plugin image on tag push
docs/specification.md    design contract
```

## Requirements

- **Jellyfin v12 fork** server image — `ghcr.io/crunchymonkies/jellyfin` (built by the
  jellyfin-src `crunchymonkies-publish.yml` workflow). Shokofin targets ABI `12.0.0.0`;
  stock Jellyfin 10.x fails the operator's ABI gate.
- Kubernetes **≥ 1.33** with image volumes enabled; the JellyOps operator + CRDs installed.

## Build the plugin image

The payload is **not compiled here** — it is the published Shokofin v12 release artifact
(`shoko_<version>_for_12.0.zip`), repackaged into a `FROM scratch` image whose root is the
Jellyfin plugin directory.

```sh
# Requires: docker, gh (authenticated). Defaults: v6.0.5 from CrunchyMonkies/Shokofin,
# pushed to ghcr.io/crunchymonkies/jellyops-plugin-shoko/plugin
docker/build-push.sh
# Build locally without pushing:
PUSH=false docker/build-push.sh
```

CI (`.github/workflows/plugin-image.yml`) does the same on a `v*` tag push (or manual
dispatch), publishing to `ghcr.io/<owner>/jellyops-plugin-shoko/plugin` and printing the
digest to the run summary.

## Deploy

Pin the pushed image digest into `k8s/30-jellyfinplugin.yaml`, edit storage classes and
`k8s/35-shoko-credentials.yaml`, then follow [`k8s/README.md`](k8s/README.md):

```sh
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/10-shoko-config-pvc.yaml
kubectl apply -f k8s/15-media-pvc.yaml
kubectl apply -f k8s/35-shoko-credentials.yaml
kubectl apply -f k8s/20-jellyfin.yaml
kubectl apply -f k8s/30-jellyfinplugin.yaml     # or 31-...-external.yaml
```

## How it works

1. The operator mounts the plugin image and copies it (with the baked `firstrun.sh` /
   `bootstrap.sh` hooks) into `/config/plugins/Shoko_<version>/`.
2. The operator's hook runner executes the baked hooks before Jellyfin starts, using the
   env/secrets from `install.env`:
   - `firstrun.sh` (once per instance) seeds `Shokofin.xml` (`<Host>` + SignalR, plus any
     optional `SHOKO_*` settings), waits for Shoko Server, optionally runs the AniDB
     first-run, and mints an API key from the `shoko-creds` Secret.
   - `bootstrap.sh` (every start) re-asserts `<Host>`/`<PublicHost>`/`<ApiKey>`.
   Both are fail-open (Jellyfin boots regardless).
3. In embedded mode the operator also reconciles the Shoko Server Deployment + Service and
   auto-mounts the instance's media into it read-only at the same path.

## License

Apache 2.0.
