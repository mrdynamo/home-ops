# Emby SSE Plugin Update

Copy `~/downloads/Emby.Plugin.Sse.0.4.1.dll` into the Emby PVC at
`/config/plugins/Emby.Plugin.Sse.dll`.

Emby runs as UID/GID `1000:1000` (see
[kubernetes/apps/default/emby/app/helmrelease.yaml](../kubernetes/apps/default/emby/app/helmrelease.yaml)).
The PVC's `fsGroup` is `1000`, so any file written into `/config/plugins/`
must end up owned by `1000:1000` — otherwise Emby may fail to read it on
next start.

The copy pod uses `readOnlyRootFilesystem: true`, so the only writable
surface inside it is the PVC mount at `/config`. `kubectl cp` extracts
into a temp dir, so the target path must live under `/config` (not
`/tmp`, which is on the read-only rootfs).

## Steps

### 1. Scale down Emby

Releases the RWO PVC attachment so the copy pod can claim it.

```bash
kubectl -n default scale deployment/emby --replicas=0
kubectl -n default wait pod -l app.kubernetes.io/name=emby --for=delete --timeout=120s
```

### 2. Launch a helper pod that mounts the Emby PVC

Runs as `1000:1000` so writes land owned correctly, with
`readOnlyRootFilesystem: true` matching Emby's security posture.

```bash
kubectl -n default run emby-plugin-copy \
  --image=alpine:3.20 \
  --restart=Never \
  --overrides='{
  "spec": {
    "securityContext": {"runAsUser": 1000, "runAsGroup": 1000, "fsGroup": 1000},
    "containers": [{
      "name": "copy",
      "image": "alpine:3.20",
      "command": ["sleep", "3600"],
      "volumeMounts": [
        {"name": "config", "mountPath": "/config"}
      ],
      "securityContext": {"runAsUser": 1000, "runAsGroup": 1000, "allowPrivilegeEscalation": false, "readOnlyRootFilesystem": true, "capabilities": {"drop": ["ALL"]}}
    }],
    "volumes": [
      {"name": "config", "persistentVolumeClaim": {"claimName": "emby"}}
    ]
  }
}'
```

### 3. Wait for the helper pod to be Ready

```bash
kubectl -n default wait pod emby-plugin-copy --for=condition=Ready --timeout=120s
```

### 4. Copy the DLL into the pod

Target a path under `/config` because that's the only writable surface
in the pod (everything else is `readOnlyRootFilesystem`).

```bash
kubectl -n default cp \
  ~/downloads/Emby.Plugin.Sse.0.4.1.dll \
  emby-plugin-copy:/config/plugins/Emby.Plugin.Sse.0.4.1.dll \
  -c copy
```

### 5. Rename to the canonical plugin name and fix ownership/perms

Emby's plugin loader matches the DLL filename against the plugin's
manifest class name, so the `0.4.1` version suffix must be dropped.
`kubectl cp` extracts as `root:root`, so `chown` is required.

```bash
kubectl -n default exec emby-plugin-copy -c copy -- sh -c '
  mv /config/plugins/Emby.Plugin.Sse.0.4.1.dll /config/plugins/Emby.Plugin.Sse.dll &&
  chown 1000:1000 /config/plugins/Emby.Plugin.Sse.dll &&
  chmod 0644 /config/plugins/Emby.Plugin.Sse.dll &&
  ls -la /config/plugins/Emby.Plugin.Sse.dll
'
```

### 6. Delete the helper pod

Releases the Longhorn RWO attachment so Emby can reattach on scale-up.

```bash
kubectl -n default delete pod emby-plugin-copy --wait=true
```

### 7. Scale Emby back up

```bash
kubectl -n default scale deployment/emby --replicas=1
kubectl -n default wait deployment/emby --for=condition=Available --timeout=300s
```

### 8. Verify

Log into the Emby UI and check **Dashboard → Plugins** — SSE 0.4.1
should appear in the list.

## Alternative: stream via stdin

If `kubectl cp`'s tar extraction ever gives trouble again, this avoids
the read-only-rootfs problem entirely by piping the file directly into
the pod's stdin:

```bash
cat ~/downloads/Emby.Plugin.Sse.0.4.1.dll | \
  kubectl -n default exec -i emby-plugin-copy -c copy -- \
  sh -c 'cat > /config/plugins/Emby.Plugin.Sse.dll && chown 1000:1000 /config/plugins/Emby.Plugin.Sse.dll && chmod 0644 /config/plugins/Emby.Plugin.Sse.dll'
```
