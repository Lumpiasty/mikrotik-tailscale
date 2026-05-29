# =============================================================================
# mikrotik-tailscale: automatic container update check
# =============================================================================
# Checks the Gitea registry for a new :stable image and, only if the published
# image actually changed, recreates the container. Designed for RouterOS 7.x
# (tested target: 7.21.2, arm64). Requires RouterOS >= 7.13 for the :deserialize
# command used to parse the registry token JSON.
#
# HOW IT DECIDES "something changed":
#   It fetches the manifest digest of the :stable tag from the registry and
#   compares it to the digest stored from the last successful deploy. The
#   :stable tag only moves on a MEANINGFUL release (Tailscale bump -> mt.1, or a
#   manual mt.N); dependency-only rebuilds never republish, so the digest is a
#   reliable "should I update" signal. No update -> no pull -> no flash wear.
#
# AUTH:
#   The Gitea package is public, but the Docker v2 API still needs a bearer
#   token. Gitea issues an anonymous token from /v2/token for public repos, so
#   no credentials are stored here.
#
# INSTALL (one-time):
#   1. Edit the CONFIG section below to match your deployment.
#   2. Upload this file to the router, then create a NAMED SCRIPT from it:
#        /system/script/add name=update-tailscale \
#            source=[/file/get update-tailscale.rsc contents]
#      NOTE: do NOT use "/import file=update-tailscale.rsc" — :import merely
#      *executes* the file's commands once (running an update immediately); it
#      does NOT create a reusable /system/script object. The scheduler below
#      runs the script by name, so it must exist as a named script.
#      (If you later edit the file, re-run the add with the ; replace it via
#       /system/script/set, or remove+add.)
#   3. Schedule it: see the /system/scheduler command at the bottom of this file.
#
# The script is idempotent and safe to run on a schedule.
# =============================================================================

:local scriptName "update-tailscale"

# ----------------------------------------------------------------------------
# CONFIG  -- edit these to match your setup
# ----------------------------------------------------------------------------
# Registry / image
:local regHost   "gitea.lumpiasty.xyz"
:local repo      "lumpiasty/mikrotik-tailscale"
:local tag       "stable"
# Full image reference RouterOS uses to pull (must include the tag).
:local imageRef  "gitea.lumpiasty.xyz/lumpiasty/mikrotik-tailscale:stable"

# Where the last-deployed digest is remembered between runs.
:local stateFile "tailscale-image.digest"

# --- /container add parameters (must match your working deployment) ---------
# These are reused verbatim when recreating the container. They MUST match the
# values used in the deployment guide (docs/USAGE.md) so the new container is
# identical to the one being replaced.
:local cName      "tailscale"
:local cRootDir   "tailscale/root"
:local cMountList "tailscale_state"
:local cInterface "veth-tailscale"
:local cLogging   yes
:local cStartOnBoot yes
# ----------------------------------------------------------------------------

:log info "$scriptName: checking for image updates"

# --- 0. Don't run concurrently -----------------------------------------------
# A slow pull/extract could overlap the next scheduled run; bail if another
# instance of this script is already running.
:if ([/system/script/job/print count-only as-value where script=[:jobname]] > 1) do={
  :log warning "$scriptName: another instance is already running; exiting"
  :error "already running"
}

# --- 1. Get an (anonymous) registry bearer token ----------------------------
# The response body is JSON ({"token":"..."}); parse it with :deserialize
# (RouterOS >= 7.13) instead of fragile string slicing.
#
# NOTE: the URL has NO "&service=..." parameter on purpose. In RouterOS "&" is
# the logical-AND operator and breaks the url= argument ("Please provide IP
# address or host"), even inside a quoted string. Gitea issues a usable token
# from just ?scope=..., so the service= param is omitted to avoid the "&".
:local tokenUrl "https://$regHost/v2/token?scope=repository:$repo:pull"
:local token ""
:onerror e in={
  :local tr [/tool fetch url=$tokenUrl as-value output=user]
  :if (($tr->"status") = "finished") do={
    :local obj [:deserialize from=json value=($tr->"data")]
    :set token ($obj->"token")
  }
} do={
  :log error "$scriptName: token fetch failed: $e"
  :error "token fetch failed"
}
:if ([:typeof $token] != "str" || [:len $token] = 0) do={
  :log error "$scriptName: could not parse registry token"
  :error "no token"
}

# --- 2. Fetch the :stable manifest and read its digest -----------------------
# We request the OCI index media type and read the Docker-Content-Digest
# response header, which is the canonical manifest-list digest.
:local manUrl "https://$regHost/v2/$repo/manifests/$tag"
:local hdrs "Authorization:Bearer $token,Accept:application/vnd.oci.image.index.v1+json"
:local newDigest ""
:onerror e in={
  :local mr [/tool fetch url=$manUrl http-header-field=$hdrs as-value output=user-with-headers]
  :if (($mr->"status") = "finished") do={
    # output=user-with-headers returns ALL response headers as one flat string,
    # ";"-separated, e.g. "Name: value;Name: value;...". There is no keyed
    # lookup, so we substring-match. Two pitfalls this handles:
    #   - Header NAME case is not guaranteed (HTTP/2 lowercases names; header
    #     names are case-insensitive anyway) -> lowercase the blob first.
    #   - Some header VALUES contain ";" (e.g. strict-transport-security:
    #     "max-age=...; includeSubDomains"). We anchor on the digest key and
    #     read to the next ";"; the digest value (sha256:<hex>) has no ";",
    #     so this is safe.
    :local rh [:convert transform=lc ($mr->"http-headers")]
    :local key "docker-content-digest: "
    :local p [:find $rh $key]
    :if ([:typeof $p] != "nil") do={
      :local rest [:pick $rh ($p + [:len $key]) [:len $rh]]
      :local q [:find $rest ";"]
      :if ([:typeof $q] = "nil") do={ :set q [:len $rest] }
      :set newDigest [:pick $rest 0 $q]
    }
  }
} do={
  :log error "$scriptName: manifest fetch failed: $e"
  :error "manifest fetch failed"
}
:if ([:len $newDigest] = 0) do={
  :log error "$scriptName: could not read Docker-Content-Digest"
  :error "no digest"
}
:log info "$scriptName: registry :stable digest = $newDigest"

# --- 3. Compare with the last-deployed digest --------------------------------
:local oldDigest ""
:if ([:len [/file find where name=$stateFile]] > 0) do={
  :set oldDigest [/file get [/file find where name=$stateFile] contents]
}

:if ($newDigest = $oldDigest) do={
  :log info "$scriptName: image unchanged; nothing to do"
  :error "noop"
}
:log info "$scriptName: image changed ($oldDigest -> $newDigest); updating"

# --- 4. Recreate the container -----------------------------------------------
:local cid [/container find where name=$cName]
:if ([:len $cid] > 0) do={
  :log info "$scriptName: stopping and removing existing container"
  :onerror e in={ /container stop $cid } do={ :log warning "$scriptName: stop: $e" }
  # Retry the REMOVE itself until it succeeds (up to ~30s). /container/remove
  # errors while the container is still running, so retrying the remove is
  # self-correcting: it waits for the stop to settle without us having to know
  # the exact status string. On success :retry stops; on persistent failure the
  # do={} block runs.
  :onerror e in={
    :retry command={ /container remove $cid } delay=1 max=30
  } do={
    :log error "$scriptName: remove failed after retries: $e"
    :error "remove failed"
  }
}

# Pull happens implicitly on add when remote-image is given.
:log info "$scriptName: adding new container from $imageRef"
:onerror e in={
  /container add \
    remote-image=$imageRef \
    interface=$cInterface \
    root-dir=$cRootDir \
    mountlists=$cMountList \
    logging=$cLogging \
    start-on-boot=$cStartOnBoot \
    name=$cName
} do={
  :log error "$scriptName: container add failed: $e"
  :error "add failed"
}

# Start the container. After /container/add the image is still extracting, and
# /container/start errors until extraction finishes, so we retry the START
# itself (up to ~4min) — self-correcting, no need to poll an exact status
# string. (If start-on-boot causes RouterOS to auto-start it once extraction
# completes, a later manual start simply errors and :retry stops once it's
# running / the do={} block runs.)
:local ncid [/container find where name=$cName]
:onerror e in={
  :retry command={ /container start $ncid } delay=2 max=120
} do={
  :log warning "$scriptName: container start did not succeed within timeout (may still be extracting or already running): $e"
}

# --- 5. Persist the new digest so we don't update again next run -------------
# We record the digest once the new container exists. Even if the start above
# is still settling, the container is created from the new image, so we should
# not re-pull on the next run.
:if ([:len [/file find where name=$stateFile]] > 0) do={
  /file set [/file find where name=$stateFile] contents=$newDigest
} else={
  /file add name=$stateFile contents=$newDigest
}
:log info "$scriptName: updated to $newDigest"

# =============================================================================
# SCHEDULING (after creating the named script per INSTALL step 2 above)
# =============================================================================
# Create a scheduler entry that runs the named script daily:
#
#   /system/scheduler add name=update-tailscale interval=1d \
#       on-event="/system/script run update-tailscale" \
#       comment="Check for mikrotik-tailscale image updates"
#
# Adjust interval to taste (e.g. 6h, 1d, 7d). The check is cheap (one small
# HTTPS request); it only pulls/recreates when the :stable digest changed.
#
# To test once, by hand:
#   /system/script run update-tailscale
# =============================================================================
