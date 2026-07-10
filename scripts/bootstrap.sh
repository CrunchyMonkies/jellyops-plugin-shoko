#!/bin/sh
#
# Shokofin BOOTSTRAP hook — runs on EVERY pod startup. Baked into the plugin image
# root (plugin/bootstrap.sh) and auto-detected by the jellyops operator for
# imageVolumeCopy plugins; the CR only supplies env.
#
# Responsibility: keep Shokofin's connection wiring authoritative across restarts /
# Service-URL changes. It re-asserts <Host> (and <PublicHost> when provided), and
# re-asserts <ApiKey> when SHOKO_APIKEY is supplied. It does NOT reset the other
# settings — those are seeded once by firstrun.sh and remain UI-tunable afterward.
#
# Jellyfin reads Shokofin config from Shokofin.xml; the connection URL maps to the
# <Host> element and the public URL to <PublicHost> (Shoko.xml / <Url> is a no-op).
#
# Fail-open under the jellyops hook runner (failurePolicy: Ignore by default).
#
# Environment (from the shoko-creds Secret + the CR install.env):
#   SHOKO_URL        Shoko Server base URL                    [required]
#   SHOKO_PUBLIC_URL public URL for deep links                [optional]
#   SHOKO_APIKEY     pre-existing Shoko API key               [optional]
#   CONFIG_DIR       Jellyfin config dir (default: /config)   [optional]
#
set -eu

CONFIG_DIR="${CONFIG_DIR:-/config}"
CFG="${CONFIG_DIR}/plugins/configurations/Shokofin.xml"
: "${SHOKO_URL:?SHOKO_URL is required}"

log() { echo "[shoko-bootstrap] $*"; }

xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# set_elem TAG VALUE — replace <TAG>…</TAG> in $CFG in place, inserting before the
# closing tag if absent.
set_elem() {
  if grep -q "<$1>" "$CFG"; then
    sed -i "s#<$1>[^<]*</$1>#<$1>$2</$1>#" "$CFG"
  else
    sed -i "s#</PluginConfiguration>#  <$1>$2</$1>\n</PluginConfiguration>#" "$CFG"
  fi
}

# Defensive: if firstrun.sh has not produced a file yet (e.g. it was skipped),
# create a minimal connection config so Shokofin still comes up wired.
if [ ! -f "$CFG" ]; then
  mkdir -p "$(dirname "$CFG")"
  {
    printf '<?xml version="1.0" encoding="utf-8"?>\n'
    printf '<PluginConfiguration xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">\n'
    printf '  <Host>%s</Host>\n' "$(xml_escape "$SHOKO_URL")"
    printf '  <ApiKey></ApiKey>\n'
    printf '  <SignalR_AutoConnectEnabled>true</SignalR_AutoConnectEnabled>\n'
    printf '  <SignalR_RefreshEnabled>true</SignalR_RefreshEnabled>\n'
    printf '  <SignalR_FileEvents>true</SignalR_FileEvents>\n'
    printf '</PluginConfiguration>\n'
  } > "$CFG"
  log "created minimal ${CFG} (firstrun had not seeded it)"
fi

# Re-assert the connection block every run (authoritative).
set_elem Host "$(xml_escape "$SHOKO_URL")"
if [ -n "${SHOKO_PUBLIC_URL:-}" ]; then set_elem PublicHost "$(xml_escape "$SHOKO_PUBLIC_URL")"; fi
if [ -n "${SHOKO_APIKEY:-}" ]; then set_elem ApiKey "$(xml_escape "$SHOKO_APIKEY")"; fi

log "re-asserted connection in ${CFG} (Host=${SHOKO_URL})"
