# Deploying the Shoko plugin with JellyOps

These manifests deploy a Jellyfin v12 instance with the Shokofin plugin (and, in
embedded mode, a Shoko Server) via the [JellyOps](../../jellyops) operator.

## Prerequisites

- A Kubernetes cluster **≥ 1.33** with **image volumes** enabled and a CRI runtime
  that supports them (recent containerd / CRI-O).
- The **JellyOps operator + CRDs** installed (`jellyfin.jellyops.io/v1alpha1`).
- An **RWX** storage class for the shared media (`15-media-pvc.yaml`) and an **RWO**
  class for Shoko's config (`10-shoko-config-pvc.yaml`).
- A published **plugin image** — run [`../docker/build-push.sh`](../docker/build-push.sh)
  (or let the `plugin-image.yml` workflow publish it) and pin the printed `@sha256`
  digest into `30-jellyfinplugin.yaml`.

## Apply order

```sh
kubectl apply -f 00-namespace.yaml
kubectl apply -f 10-shoko-config-pvc.yaml     # embedded mode only
kubectl apply -f 15-media-pvc.yaml            # edit storageClassName first
kubectl apply -f 35-shoko-credentials.yaml    # edit credentials first
kubectl apply -f 20-jellyfin.yaml             # v12 fork server image
kubectl apply -f 30-jellyfinplugin.yaml       # EMBEDDED (runs Shoko Server)
# or, INSTEAD of 30:
# kubectl apply -f 31-jellyfinplugin-external.yaml   # EXTERNAL (bring your own Shoko)
kubectl apply -f 40-networkpolicy.yaml        # optional
```

Then watch reconciliation:

```sh
kubectl -n media get jellyfin,jellyfinplugin
kubectl -n media describe jellyfinplugin shoko
```

## Modes

- **Embedded** (`30-jellyfinplugin.yaml`) — the CR runs a Shoko Server companion
  workload + Service + config PVC. Shokofin points at `http://shoko-server.media.svc:8111`.
- **External** (`31-jellyfinplugin-external.yaml`) — only Shokofin is delivered; set
  `SHOKO_URL` to your existing Shoko Server. Apply this **instead of** `30`.

## Notes

- `spec.image` in `20-jellyfin.yaml` **must** be a Jellyfin **v12** build (the
  CrunchyMonkies fork, `ghcr.io/crunchymonkies/jellyfin`); stock 10.x fails the ABI gate.
  The fork is headless — add a `spec.web` block if you need the web UI.
- Media must be visible at the **same absolute path** (`/media`) to both Jellyfin and
  Shoko Server (identity path mapping) — that is why the media PVC is `ReadWriteMany`.
- Credentials are best-effort: if the install hook can't mint an API key, Jellyfin still
  boots — finish setup in **Jellyfin → Shoko** plugin settings, or via the Shoko web UI.
