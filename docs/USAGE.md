# Usage

Deploying the published image on a MikroTik router and operating it: networking,
authentication, MagicDNS, and automatic updates. This uses the prebuilt image
from the registry — you don't need to build anything.

To build the image yourself, see [DEVELOPMENT.md](DEVELOPMENT.md). For the
reasoning behind these choices, see [DESIGN.md](DESIGN.md).

## Deploy on MikroTik (RouterOS)

Verified on RouterOS 7.21.2 (arm64, CRS418). Commands are grouped into
copy-paste blocks; **only the values marked `CHANGE ME` need editing**.

> Because the image has no built-in updater (the `clientupdate` feature is
> [intentionally compiled out](DESIGN.md#why-the-built-in-updater-is-removed)),
> updates are handled by a small script that only re-pulls when the published
> image actually changed — see [step 7](#7-enable-automatic-updates).

### 0. Prerequisites

- RouterOS 7.x with the **container** package installed.
- Container mode enabled (needs physical access — press reset / cold-boot when
  prompted):

  ```
  /system/device-mode/update container=yes
  ```

- A Tailscale **auth key** from the admin console
  (**Settings → Keys**, reusable, optionally tagged). You'll use it in step 6.

### 1. Networking (veth + bridge + NAT)

Gives the container an internal IP and outbound internet via NAT. Pick a subnet
that doesn't clash with your LAN.

```
/interface/veth/add name=veth-tailscale address=172.20.0.2/24 gateway=172.20.0.1
/interface/bridge/add name=containers
/ip/address/add address=172.20.0.1/24 interface=containers
/interface/bridge/port/add bridge=containers interface=veth-tailscale
/ip/firewall/nat/add chain=srcnat action=masquerade src-address=172.20.0.0/24
```

### 2. Extraction scratch dir (tmpfs)

Put the image extraction scratch dir on **tmpfs** (RAM) so the pull/extract
never writes to flash:

```
/disk/add type=tmpfs tmpfs-max-size=256M slot=tmp
/container/config/set tmpdir=tmp
```

> **No `registry-url` change needed.** This guide puts the full registry host in
> `remote-image` (step 5), and RouterOS pulls directly from that host — the
> global `registry-url` is ignored when the image reference includes a host.
> This is intentional: it leaves your existing `registry-url` untouched, so
> other containers (e.g. ones pulling from Docker Hub or ghcr.io) keep working,
> and multiple registries can be used side by side.

### 3. Authentication note (no env needed)

This image runs `tailscaled` directly and does **not** bundle Tailscale's
`containerboot` wrapper, so the `TS_AUTHKEY` environment variable is **not**
read automatically. You authenticate with `tailscale up --authkey=...` after the
container starts (step 6) — this keeps the image minimal and needs no env list.

### 4. Persistent state mount (the only thing on flash)

Only the tiny `tailscaled.state` (node identity / key) needs to persist. Mount
just that directory:

```
/container/mounts/add list=tailscale_state src=tailscale/state dst=/var/lib/tailscale
```

`src=tailscale/state` is on internal storage. This holds `tailscaled.state`
(and `derpmap.cached.json`), written only on auth / key rotation / prefs
change — **not** on every netmap update, because netmap disk-caching is omitted
([why](DESIGN.md#why-netmap-disk-caching-is-removed)). Flash wear is therefore
minimal. If you want *zero* persistent writes, point `src` at a tmpfs disk slot
instead and accept re-authentication after a reboot.

### 5. Add and start the container

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

### 6. Authenticate

Enter the container shell and bring Tailscale up with your auth key. You can set
subnet routes / exit-node advertisement in the same command:

```
/container/shell [find where name=tailscale]
# inside the container — CHANGE ME: your key (and adjust routes/subnet):
tailscale up --authkey=tskey-auth-CHANGEME \
  --advertise-routes=192.168.88.0/24 \
  --advertise-exit-node
exit
```

The node now appears in your Tailscale admin console. Approve the advertised
routes / exit node there. Because the auth state is written to the persisted
`tailscaled.state`, you only do this once — it survives reboots and updates.

### 7. Enable automatic updates

First, edit the `CONFIG` block at the top of `routeros/update-tailscale.rsc` if
you changed any names in the steps above. The defaults match this guide
(`name=tailscale`, `root-dir=tailscale/root`, `mountlists=tailscale_state`,
`interface=veth-tailscale`).

Copy the file to the router (Winbox **Files** drag-and-drop, or SFTP), then
create a **named script** from it and schedule it:

```
# Create the named script from the uploaded file's contents.
# (Do NOT use `/import` — that just runs the file once and does not create a
#  reusable script for the scheduler to call.)
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

This avoids writing to `/etc/resolv.conf` inside the container (which would
happen if `--accept-dns` is passed to `tailscale up`). The container resolves
Tailscale node names; the rest of the router uses its own DNS.

## Updating

You don't normally do anything: when a new release is published, the
auto-update script ([step 7](#7-enable-automatic-updates)) detects the changed
`:stable` image on its next scheduled run and recreates the container. Your
node identity and settings persist across the update via the state mount.

To force an immediate check instead of waiting for the schedule:

```
/system/script/run update-tailscale
```

To pin a specific version instead of tracking `:stable`, set `remote-image` (and
the script's `imageRef`) to an immutable tag like
`...mikrotik-tailscale:v1.98.3-mt.1`.
