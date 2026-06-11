# Usage

Deploying the published image on a MikroTik router and operating it: networking,
authentication, MagicDNS, and automatic updates. This uses the prebuilt image
from the registry — you don't need to build anything.

To build the image yourself, see [DEVELOPMENT.md](DEVELOPMENT.md). For the
reasoning behind these choices, see [DESIGN.md](DESIGN.md).

## Deploy on MikroTik (RouterOS)

Verified on RouterOS 7.21.2 (arm64, CRS418). Commands are grouped into
copy-paste blocks, defaults should fit most configurations.

> Because the image has no built-in updater (the `clientupdate` feature is
> [intentionally compiled out](DESIGN.md#why-the-built-in-updater-is-removed)),
> updates are handled by a small script that recreates container when
> the update is published — see [step 7](#7-enable-automatic-updates).

### 0. Prerequisites

- RouterOS >7.13 with the **container** package installed.
- Container mode enabled ([documentation](https://manual.mikrotik.com/docs/System%20Information%20and%20Utilities/device-mode/#changing-mode-of-device-mode)):

  ```
  /system/device-mode/update container=yes
  ```

### 1. Networking (veth + routing)

Gives the container an internal IP and configures routing to the tailnet.
Pick a subnet that doesn't clash with your LAN.

```
/interface/veth/add name=veth-tailscale address=172.20.0.2/24 gateway=172.20.0.1
/interface/bridge/add name=containers
/ip/address/add address=172.20.0.1/24 interface=containers
/interface/bridge/port/add bridge=containers interface=veth-tailscale
/ip/route/add dst-address=100.64.0.0/10 gateway=172.20.0.2 comment=Tailnet
```

If you want the router to have access to subnets shared by other tailscale nodes,
add route for each one.

```
/ip/route/add dst-address=[subnet CIDR] gateway=172.20.0.2 comment="Another network via tailscale"
```

If you want to share your LAN via tailscale, add it as an advertised route in
[step 5](#5-authenticate). You may also need additional firewall configuration
to accept connections to or from tailnet if you have one configured.
You should not need any additional NAT rules.

### 2. Extraction scratch dir (tmpfs)

Put the image extraction scratch dir on **tmpfs** (RAM) so the pull/extract
happen in RAM and doesn't fill up or wear out flash:

```
/disk/add type=tmpfs tmpfs-max-size=256M slot=tmp
/container/config/set tmpdir=tmp
```

### 3. Persistent state mount (the only thing on flash)

Only the tiny `tailscaled.state` (node identity / key) needs to persist. Mount
just that directory:

```
/container/mounts/add list=tailscale_state src=tailscale/state dst=/var/lib/tailscale
```

### 4. Add and start the container

```
/container/add \
    remote-image=gitea.lumpiasty.xyz/lumpiasty/mikrotik-tailscale:stable \
    interface=veth-tailscale \
    root-dir=tailscale/root \
    mountlists=tailscale_state \
    logging=yes \
    start-on-boot=yes \
    name=tailscale
```

Wait for the pull/extract to finish (`status=stopped`), then start it:

```
/container/print              ;# wait until status=stopped
/container/start [find where name=tailscale]
/log/print where message~"tailscale"
```

The daemon is now running but **not yet authenticated**.

### 5. Authenticate

> This image runs `tailscaled` via a tiny entrypoint (which enables IP
forwarding, then `exec`s the daemon) and does **not** bundle Tailscale's
`containerboot` wrapper, so the `TS_AUTHKEY` environment variable is **not**
read automatically. You authenticate with `tailscale up --authkey=...` after the
container starts.

Enter the container shell and bring Tailscale up with your auth key.
Use `tailscale up --help` to see list of commands, customize it to your needs,
add subnets (eg. your LAN) or exit-node advertisements in command below.

```
/container/shell [find where name=tailscale]
# inside the container — CHANGE ME: your key (and adjust routes/subnet):
tailscale up --authkey=tskey-auth-CHANGEME \
  --accept-routes \
  --snat-subnet-routes=false \
  --advertise-routes=172.20.0.0/24 \
  --advertise-exit-node
exit
```

The node now appears in your Tailscale admin console. Approve the advertised
routes / exit node there. Because the auth state is written to the persisted
`tailscaled.state`, you only do this once — it survives reboots and updates.

### 6. Enable automatic updates

First, edit the `CONFIG` block at the top of `routeros/update-tailscale.rsc` if
you changed any names in the steps above. The defaults match this guide
(`name=tailscale`, `root-dir=tailscale/root`, `mountlists=tailscale_state`,
`interface=veth-tailscale`).

Copy the file to the router (Winbox **Files** drag-and-drop, or SFTP), then
create a **named script** from it and schedule it:

```
# Create the named script from the uploaded file's contents.
/system/script/add name=update-tailscale source=[/file/get update-tailscale.rsc contents]

# Run it daily.
/system/scheduler/add name=update-tailscale interval=1d \
    on-event="/system/script/run update-tailscale" \
    comment="Check for mikrotik-tailscale image updates"
```

If you later upload a changed version of the file, refresh the script:

```
/system/script/set update-tailscale source=[/file/get update-tailscale.rsc contents]
```

What it does on each run:

1. Reads the current `:stable` manifest digest from the registry (anonymous —
   the package is public).
2. Compares it to the digest stored from the last deploy.
3. **Unchanged → does nothing** (no pull, no flash writes).
4. **Changed → recreates the container** from the new image and records the new
   digest.

Since `:stable` only moves on a meaningful release, the router never re-pulls
for build-system-only changes — see
[DESIGN.md → Versioning & releases](DESIGN.md#versioning--releases).

> The digest fetch/compare logic is verified against the registry; the RouterOS
> container/file API calls (marked in the script) should be smoke-tested once on
> your device, since those idioms vary slightly by RouterOS version.

## MagicDNS

To use MagicDNS name resolution, configure MikroTik's DNS to forward `.ts.net`
queries to Tailscale's magic DNS resolver:

```
/ip dns static
add name="ts.net" type=FWD forward-to=100.100.100.100 match-subdomain=yes
```

When this is configured, you can connect to other tailscale machines using
`[device name].[tailnet name].ts.net`. You can see and change assigned
Tailnet DNS name in Tailscale admin panel under DNS tab.

## Logging

The container logs to the RouterOS log (topic `container`) via `logging=yes`.

Upstream `tailscaled` is notoriously chatty: by default it would emit a line
for every accepted connection (`Accept: TCP{...}`), every netcheck report, and
every WireGuard handshake/keepalive — several lines per minute on an active
node ([tailscale#12158](https://github.com/tailscale/tailscale/issues/12158)).
This image filters those verbose (`[v1]`/`[v2]`-tagged) messages out at the
source, so only meaningful messages (startup, auth, route changes, warnings,
errors) reach the RouterOS log. See
[DESIGN.md → Log verbosity filtering](DESIGN.md#log-verbosity-filtering) for
how and why.

To temporarily get the verbose logs back for debugging (e.g. NAT-traversal
issues), set the `TS_LOG_VERBOSITY` environment variable and recreate the
container with the envlist attached:

```
/container/envs/add list=tailscale_envs name=TS_LOG_VERBOSITY value=1
/container/set [find where name=tailscale] envlist=tailscale_envs
/container/stop [find where name=tailscale]
/container/start [find where name=tailscale]
```

Any value ≥ 1 disables the filter (and raises the daemon's own verbosity by
the same amount). Remove the variable and restart to silence it again:

```
/container/envs/remove [find where name=TS_LOG_VERBOSITY]
/container/stop [find where name=tailscale]
/container/start [find where name=tailscale]
```

## Updating

You don't normally do anything: when a new release is published, the
auto-update script ([step 6](#6-enable-automatic-updates)) detects the changed
`:stable` image on its next scheduled run and recreates the container. Your
node identity and settings persist across the update via the state mount.

To force an immediate check instead of waiting for the schedule:

```
/system/script/run update-tailscale
```

To pin a specific version instead of tracking `:stable`, set `remote-image` (and
the script's `imageRef`) to an immutable tag like
`...mikrotik-tailscale:v1.98.3-mt.1`.
