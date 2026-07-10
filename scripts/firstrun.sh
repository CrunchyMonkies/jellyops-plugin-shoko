#!/bin/sh
#
# Shokofin FIRST-RUN hook — runs ONCE per Jellyfin instance, the first time the
# plugin starts (jellyops gates it with a marker under /config/.jellyops/firstrun/).
# It is baked into the plugin image root (plugin/firstrun.sh) and auto-detected by
# the jellyops operator for imageVolumeCopy plugins; the CR only supplies env.
#
# Responsibilities (one-time setup):
#   1. Seed the full declarative Shokofin.xml (connection + SignalR + optional
#      SHOKO_* settings). Every-start connection re-assertion lives in bootstrap.sh.
#   2. Optionally complete Shoko's AniDB first-run registration.
#   3. Mint / resolve an API key and patch <ApiKey>/<Username> into Shokofin.xml.
#
# IMPORTANT: Jellyfin reads Shokofin's config from Shokofin.xml (name derived from
# the Shokofin.dll assembly), and PluginConfiguration maps Url -> <Host> and
# PublicUrl -> <PublicHost>. Using Shoko.xml / <Url> / <PublicUrl> is a silent no-op.
#
# Fail-open: the jellyops hook runner runs this under failurePolicy (Ignore by
# default), so a failure here leaves Jellyfin to boot with whatever was seeded and
# the manual web-UI fallback for the key.
#
# Environment (from the shoko-creds Secret + the CR install.env):
#   SHOKO_URL        Shoko Server base URL                                 [required]
#   SHOKO_PUBLIC_URL public URL for deep links                            [optional]
#   SHOKO_APIKEY     pre-existing Shoko API key                            [optional]
#   SHOKO_USERNAME   Shoko local user (for minting a key / first-run)      [optional]
#   SHOKO_PASSWORD   Shoko local user password                           [optional]
#   ANIDB_USERNAME   AniDB login for embedded first-run                   [optional]
#   ANIDB_PASSWORD   AniDB password for embedded first-run                [optional]
#   CONFIG_DIR       Jellyfin config dir (default: /config)               [optional]
#
# Optional expanded settings (omit to keep Shokofin's built-in default — omitted
# XML elements retain the value set by PluginConfiguration's constructor):
#   Library:   SHOKO_LIBRARY_STRUCTURE (anidb|groups|tmdb), SHOKO_SEPARATE_MOVIES,
#              SHOKO_FILTER_MOVIE_LIBRARIES, SHOKO_SEASON_ORDERING,
#              SHOKO_SPECIALS_PLACEMENT, SHOKO_ADD_MISSING_METADATA
#   VFS:       SHOKO_LIBRARY_OPERATION_MODE (VFS|Strict), SHOKO_VFS_THREADS,
#              SHOKO_VFS_LOCATION (Default|Custom), SHOKO_VFS_CUSTOM_LOCATION
#   Providers: SHOKO_ADD_ANIDB_ID, SHOKO_ADD_TMDB_ID, SHOKO_ADD_TVDB_ID,
#              SHOKO_ADD_EXTRA_INFO_TO_LINK_NAME, SHOKO_MAX_LINKS_PER_TYPE
#   Tags:      SHOKO_HIDE_UNVERIFIED_TAGS, SHOKO_TAG_MAX_DEPTH, SHOKO_GENRE_MAX_DEPTH,
#              SHOKO_TAG_MIN_WEIGHT, SHOKO_GENRE_MIN_WEIGHT,
#              SHOKO_AUTO_RECONSTRUCT_COLLECTIONS, SHOKO_COLLECTION_MIN_SIZE_OF_TWO,
#              SHOKO_COLLECTION_GROUPING
#
set -eu

CONFIG_DIR="${CONFIG_DIR:-/config}"
CFG="${CONFIG_DIR}/plugins/configurations/Shokofin.xml"
: "${SHOKO_URL:?SHOKO_URL is required}"

log() { echo "[shoko-firstrun] $*"; }

if ! command -v curl >/dev/null 2>&1; then
  if command -v apk >/dev/null 2>&1; then apk add --no-cache curl >/dev/null 2>&1 || true; fi
fi

xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# emit_raw/emit_str TAG VALUE — append <TAG>VALUE</TAG> only when VALUE is non-empty.
# if-form (not `&&`) keeps status 0 so an empty value does not trip `set -e`.
emit_raw() { if [ -n "$2" ]; then printf '  <%s>%s</%s>\n' "$1" "$2" "$1"; fi; }
emit_str() { if [ -n "$2" ]; then printf '  <%s>%s</%s>\n' "$1" "$(xml_escape "$2")" "$1"; fi; }

# set_elem TAG VALUE — replace <TAG>…</TAG> in $CFG in place, inserting before the
# closing tag if absent.
set_elem() {
  if grep -q "<$1>" "$CFG"; then
    sed -i "s#<$1>[^<]*</$1>#<$1>$2</$1>#" "$CFG"
  else
    sed -i "s#</PluginConfiguration>#  <$1>$2</$1>\n</PluginConfiguration>#" "$CFG"
  fi
}

# Map the library-structure alias to the two backing booleans (the computed
# DefaultLibraryStructure field is [XmlIgnore] — Shokofin derives it from these).
USE_GROUPS=; USE_TMDB=
case "${SHOKO_LIBRARY_STRUCTURE:-}" in
  anidb)  USE_GROUPS=false; USE_TMDB=false ;;
  groups) USE_GROUPS=true;  USE_TMDB=false ;;
  tmdb)   USE_GROUPS=false; USE_TMDB=true  ;;
  "")     : ;;
  *)      log "WARN: unknown SHOKO_LIBRARY_STRUCTURE='${SHOKO_LIBRARY_STRUCTURE}' (expected anidb|groups|tmdb); leaving default" ;;
esac

# 1. Seed the full declarative Shokofin.xml (only when absent). Elements are only
#    written when their env var is set; anything omitted keeps Shokofin's default.
seed_config() {
  mkdir -p "$(dirname "$CFG")"
  {
    printf '<?xml version="1.0" encoding="utf-8"?>\n'
    printf '<PluginConfiguration xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">\n'
    printf '  <Host>%s</Host>\n' "$(xml_escape "$SHOKO_URL")"
    emit_str PublicHost "${SHOKO_PUBLIC_URL:-}"
    emit_str Username "${SHOKO_USERNAME:-}"
    printf '  <ApiKey></ApiKey>\n'
    printf '  <SignalR_AutoConnectEnabled>true</SignalR_AutoConnectEnabled>\n'
    printf '  <SignalR_RefreshEnabled>true</SignalR_RefreshEnabled>\n'
    printf '  <SignalR_FileEvents>true</SignalR_FileEvents>\n'
    emit_raw UseGroupsForShows "$USE_GROUPS"
    emit_raw UseTmdbForShows "$USE_TMDB"
    emit_raw SeparateMovies "${SHOKO_SEPARATE_MOVIES:-}"
    emit_raw FilterMovieLibraries "${SHOKO_FILTER_MOVIE_LIBRARIES:-}"
    emit_raw SeasonOrdering "${SHOKO_SEASON_ORDERING:-}"
    emit_raw SpecialsPlacement "${SHOKO_SPECIALS_PLACEMENT:-}"
    emit_raw AddMissingMetadata "${SHOKO_ADD_MISSING_METADATA:-}"
    emit_raw LibraryFiltering "${SHOKO_LIBRARY_OPERATION_MODE:-}"
    emit_raw VirtualFileSystemThreads "${SHOKO_VFS_THREADS:-}"
    emit_raw VFS_Location "${SHOKO_VFS_LOCATION:-}"
    emit_str VFS_CustomLocation "${SHOKO_VFS_CUSTOM_LOCATION:-}"
    emit_raw AddAniDBId "${SHOKO_ADD_ANIDB_ID:-}"
    emit_raw AddTMDBId "${SHOKO_ADD_TMDB_ID:-}"
    emit_raw AddTvDBId "${SHOKO_ADD_TVDB_ID:-}"
    emit_raw AddExtraInfoToLinkName "${SHOKO_ADD_EXTRA_INFO_TO_LINK_NAME:-}"
    emit_raw MaxLinksPerTypeToShow "${SHOKO_MAX_LINKS_PER_TYPE:-}"
    emit_raw HideUnverifiedTags "${SHOKO_HIDE_UNVERIFIED_TAGS:-}"
    emit_raw TagMaximumDepth "${SHOKO_TAG_MAX_DEPTH:-}"
    emit_raw GenreMaximumDepth "${SHOKO_GENRE_MAX_DEPTH:-}"
    emit_raw TagMinimumWeight "${SHOKO_TAG_MIN_WEIGHT:-}"
    emit_raw GenreMinimumWeight "${SHOKO_GENRE_MIN_WEIGHT:-}"
    emit_raw AutoReconstructCollections "${SHOKO_AUTO_RECONSTRUCT_COLLECTIONS:-}"
    emit_raw CollectionMinSizeOfTwo "${SHOKO_COLLECTION_MIN_SIZE_OF_TWO:-}"
    emit_raw CollectionGrouping "${SHOKO_COLLECTION_GROUPING:-}"
    printf '</PluginConfiguration>\n'
  } > "$CFG"
  log "seeded ${CFG} (Host=${SHOKO_URL})"
}

# 2. Wait for Shoko Server to answer (best-effort, bounded).
wait_for_shoko() {
  i=0
  while [ "$i" -lt 60 ]; do
    if curl -fsS -o /dev/null "${SHOKO_URL%/}/api/v3/Init/Status" 2>/dev/null; then
      log "Shoko Server reachable at ${SHOKO_URL}"; return 0
    fi
    i=$((i + 1)); sleep 5
  done
  log "WARN: Shoko Server not reachable after timeout; continuing (fail-open)"
  return 1
}

# 3. Obtain an API key: prefer the pre-supplied one; otherwise attempt the embedded
#    first-run (AniDB login) and mint a key. All best-effort.
resolve_apikey() {
  if [ -n "${SHOKO_APIKEY:-}" ]; then
    printf '%s' "$SHOKO_APIKEY"; return 0
  fi

  if [ -n "${ANIDB_USERNAME:-}" ] && [ -n "${ANIDB_PASSWORD:-}" ]; then
    log "attempting Shoko first-run / AniDB registration"
    curl -fsS -X POST "${SHOKO_URL%/}/api/v3/Init/AniDB" \
      -H 'Content-Type: application/json' \
      -d "{\"Username\":\"${ANIDB_USERNAME}\",\"Password\":\"${ANIDB_PASSWORD}\"}" \
      >/dev/null 2>&1 || log "WARN: AniDB registration call failed (may already be configured)"
  fi

  if [ -n "${SHOKO_USERNAME:-}" ] && [ -n "${SHOKO_PASSWORD:-}" ]; then
    KEY="$(curl -fsS -X POST "${SHOKO_URL%/}/api/auth" \
      -H 'Content-Type: application/json' \
      -d "{\"user\":\"${SHOKO_USERNAME}\",\"pass\":\"${SHOKO_PASSWORD}\",\"device\":\"Shokofin (JellyOps)\"}" \
      2>/dev/null | sed -n 's/.*"apikey"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    if [ -n "${KEY:-}" ]; then printf '%s' "$KEY"; return 0; fi
    log "WARN: could not mint an API key from ${SHOKO_URL}/api/auth"
  fi
  return 1
}

main() {
  if [ -f "$CFG" ]; then
    log "existing ${CFG} found; leaving config, resolving API key only"
  else
    seed_config
  fi
  wait_for_shoko || true
  if KEY="$(resolve_apikey)"; then
    set_elem ApiKey "$(xml_escape "$KEY")"
    if [ -n "${SHOKO_USERNAME:-}" ]; then set_elem Username "$(xml_escape "$SHOKO_USERNAME")"; fi
    log "Shokofin configured with an API key."
  else
    log "No API key resolved — Shokofin seeded with Host only. Add the key in the"
    log "Jellyfin > Shoko plugin settings, or via the shoko-creds Secret."
  fi
}

main "$@"
