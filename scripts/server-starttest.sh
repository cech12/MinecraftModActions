#!/usr/bin/env bash
# Server start test: starts a real dedicated server (Docker image itzg/minecraft-server) with the built release jar of
# one loader and checks that it starts cleanly. Used by .github/workflows/server-starttest.yml and can be run locally
# in the root directory of a mod repository:
#
#   ./gradlew build
#   curl -fsSL https://raw.githubusercontent.com/cech12/MinecraftModActions/main/scripts/server-starttest.sh \
#       | bash -s -- <fabric|forge|neoforge> [--versions <build|minimum|newest>] [--with-integrations]
#
# The server runs with the Minecraft version of the mod. Loader and dependencies are chosen by --versions, always within
# the version ranges of the mod metadata (lower and upper bounds):
#   build    (default) the loader and dependency versions of gradle.properties, which the mod is built with
#   minimum  the oldest versions the mod allows (skipped if they equal the build versions)
#   newest   the newest versions, to notice when a new loader or dependency release breaks the mod
#
# Options:
#   --versions <build|minimum|newest>  versions of the loader and the dependencies, see above
#   --with-integrations  also install the optional dependencies of the mod. If the mod has none for this loader, this
#                        run would equal the run without the option: the script prints a note and exits 0.
#   --print-cache-key    only print the cache key of the server installation in $STARTTEST_DIR/<loader>-<versions>-<mode>/data
#                        (empty if the run is skipped) and exit. Used by the CI.
#
# For multiloader projects with one subproject per loader (fabric/forge/neoforge), like the MultiLoader template, from
# Minecraft 26.x on. Requirements: bash, docker, curl, python3 (3.11 or newer).
#
# Everything comes from the mod repository and its built jar:
#   gradle.properties                    minecraft_version, mod_id, java_version and the build versions (*_version)
#   dependencies                         read from the metadata in the jar: fabric.mod.json (depends = required,
#                                        recommends/suggests = optional) or neoforge.mods.toml/mods.toml (required or
#                                        optional, client only dependencies and bundled jar in jar libraries are
#                                        ignored). They are installed from Modrinth (server-starttest-resolve.py); mod ids
#                                        with another Modrinth project name are mapped in server-starttest-mods.txt next
#                                        to this script (one central list for all mods). Required dependencies of these
#                                        mods are installed automatically.
#   scripts/server-starttest.allowlist   (optional) regexes of harmless log lines, in addition to the built-in ones
#
# Environment variables (optional):
#   STARTTEST_TIMEOUT          seconds to wait for the server start (default 600)
#   STARTTEST_DIR              working directory for server data and logs (default <mod repository>/.server-starttest)
#   STARTTEST_IMAGE            docker image (default itzg/minecraft-server:java<java version>)
#   STARTTEST_MOD_DIR          root directory of the mod repository (default: current directory)
#   STARTTEST_LOADER_VERSION   loader version to use instead of the chosen one (e.g. to reproduce a failure)
#   STARTTEST_PYTHON           python executable (default: python3 or python, whichever is 3.11 or newer)
#   STARTTEST_ACTIONS_REF      branch or tag of cech12/MinecraftModActions to download the helper files from when they
#                              are not next to the script (default main)
set -euo pipefail

usage() { echo "Usage: $0 <fabric|forge|neoforge> [--versions <build|minimum|newest>] [--with-integrations] [--print-cache-key]" >&2; exit 2; }
LOADER="${1:-}"
[ $# -gt 0 ] && shift
MODE="required"
VERSIONS="build"
PRINT_CACHE_KEY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --with-integrations) MODE="integrations" ;;
        --print-cache-key) PRINT_CACHE_KEY=1 ;;
        --versions) VERSIONS="${2:-}"; [ $# -gt 0 ] && shift ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
    shift
done
case "$VERSIONS" in
    build|minimum|newest) ;;
    *) echo "Unknown versions: $VERSIONS" >&2; usage ;;
esac
case "$LOADER" in
    fabric)   LOADER_TYPE=FABRIC;   LOADER_VERSION_ENV=FABRIC_LOADER_VERSION; BUILD_VERSION_KEY=fabric_loader_version ;;
    forge)    LOADER_TYPE=FORGE;    LOADER_VERSION_ENV=FORGE_VERSION;         BUILD_VERSION_KEY=forge_version ;;
    neoforge) LOADER_TYPE=NEOFORGE; LOADER_VERSION_ENV=NEOFORGE_VERSION;      BUILD_VERSION_KEY=neoforge_version ;;
    *) usage ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" && pwd)"
MOD_DIR="$(cd "${STARTTEST_MOD_DIR:-$PWD}" && pwd)"
cd "$MOD_DIR"
if [ ! -f gradle.properties ]; then
    echo "gradle.properties not found in $MOD_DIR. Run the script in the root directory of the mod repository." >&2
    exit 2
fi
if [ ! -f "$LOADER/build.gradle" ] && [ ! -f "$LOADER/build.gradle.kts" ]; then
    echo "Subproject $LOADER not found. The server start test supports multiloader projects with one subproject per loader." >&2
    exit 2
fi
LIBS="$LOADER/build/libs"
ALLOWLIST_FILE="scripts/server-starttest.allowlist"

# value of a gradle.properties key (empty if it does not exist)
prop_or_empty() {
    grep -E "^$1[[:space:]]*=" gradle.properties | head -1 | cut -d= -f2- | tr -d '\r' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g'
}
prop() {
    local value
    value="$(prop_or_empty "$1")"
    if [ -z "$value" ]; then
        echo "Property $1 is missing in gradle.properties" >&2
        exit 2
    fi
    printf '%s' "$value"
}

# web request; a failed request is an error (exit code of curl)
api() { curl -fsS --max-time 30 --retry 3 --retry-all-errors -A "server-starttest (github.com/cech12/MinecraftModActions)" "$@"; }

MC_VERSION="$(prop minecraft_version)"
MOD_ID="$(prop mod_id)"
JAVA_VERSION="$(prop java_version)"
BUILD_LOADER_VERSION="$(prop_or_empty "$BUILD_VERSION_KEY")"
IMAGE="${STARTTEST_IMAGE:-itzg/minecraft-server:java${JAVA_VERSION}}"
TIMEOUT="${STARTTEST_TIMEOUT:-600}"
WORK="${STARTTEST_DIR:-$MOD_DIR/.server-starttest}/${LOADER}-${VERSIONS}-${MODE}"
NAME="${MOD_ID}-starttest-${LOADER}-${VERSIONS}-${MODE}"

# Release jar in <loader>/build/libs, without sources, javadoc and dev jars. If several jars are left, the one with the
# mod version wins.
JARS=()
shopt -s nullglob
for jar in "$LIBS"/*.jar; do
    case "$jar" in
        *-sources.jar|*-javadoc.jar|*-dev.jar|*-dev-shadow.jar|*-slim.jar|*-api.jar) continue ;;
    esac
    JARS+=("$jar")
done
shopt -u nullglob
if [ "${#JARS[@]}" -gt 1 ]; then
    MOD_VERSION="$(prop_or_empty mod_version)"
    MATCHING=()
    for jar in ${JARS[@]+"${JARS[@]}"}; do
        if [ -n "$MOD_VERSION" ] && [[ "$(basename "$jar")" == *"$MOD_VERSION"* ]]; then MATCHING+=("$jar"); fi
    done
    JARS=(${MATCHING[@]+"${MATCHING[@]}"})
fi
if [ "${#JARS[@]}" -ne 1 ]; then
    echo "Expected exactly one release jar in $LIBS, found ${#JARS[@]}: ${JARS[*]:-}. Run ./gradlew build first." >&2
    exit 2
fi
JAR="${JARS[0]}"

# Loader version and dependencies (server-starttest-resolve.py next to this script, otherwise downloaded)
HELPER_DIR="$SCRIPT_DIR"
if [ ! -f "$HELPER_DIR/server-starttest-resolve.py" ] || [ ! -f "$HELPER_DIR/server-starttest-mods.txt" ]; then
    HELPER_DIR="$(mktemp -d)"
    for file in server-starttest-resolve.py server-starttest-mods.txt; do
        if ! api -o "$HELPER_DIR/$file" "https://raw.githubusercontent.com/cech12/MinecraftModActions/${STARTTEST_ACTIONS_REF:-main}/scripts/$file"; then
            echo "$file could not be downloaded." >&2
            exit 1
        fi
    done
fi
RESOLVE_ARGS=(--jar "$JAR" --loader "$LOADER" --mod-id "$MOD_ID" --mc-version "$MC_VERSION" --properties gradle.properties
              --build-loader-version "$BUILD_LOADER_VERSION" --loader-version "${STARTTEST_LOADER_VERSION:-}"
              --mapping "$HELPER_DIR/server-starttest-mods.txt" --versions "$VERSIONS")
[ "$MODE" = "integrations" ] && RESOLVE_ARGS+=(--integrations)
# Python 3.11 or newer (tomllib)
PYTHON=""
for candidate in ${STARTTEST_PYTHON:-} python3 python; do
    if "$candidate" -c 'import tomllib' > /dev/null 2>&1; then PYTHON="$candidate"; break; fi
done
if [ -z "$PYTHON" ]; then
    echo "Python 3.11 or newer is required (python3, python or STARTTEST_PYTHON)." >&2
    exit 2
fi
RESOLVE_ERROR="$(mktemp)"
if ! RESOLVED="$("$PYTHON" "$HELPER_DIR/server-starttest-resolve.py" "${RESOLVE_ARGS[@]}" 2> "$RESOLVE_ERROR")"; then
    RESOLVE_FAILURE="$(cat "$RESOLVE_ERROR")"
else
    RESOLVE_FAILURE=""
fi
rm -f "$RESOLVE_ERROR"
field() { awk -F'\t' -v key="$1" -v n="$2" '$1 == key { print $n; exit }' <<< "$RESOLVED"; }

SKIP=""
if [ -z "$RESOLVE_FAILURE" ]; then
    LOADER_VERSION="$(field LOADER_VERSION 2)"
    LOADER_RANGE="$(field LOADER_VERSION 3)"
    # The integrations run only makes sense with optional dependencies, the minimum run only with other versions than
    # the build run: otherwise they would equal another run.
    if [ "$MODE" = "integrations" ] && [ "$(field OPTIONAL_COUNT 2)" = "0" ]; then
        SKIP="the mod has no optional dependencies for $LOADER, this run would equal the run without integrations."
    elif grep -q "^SAME_AS_BUILD" <<< "$RESOLVED"; then
        SKIP="the minimum versions are the build versions, this run would equal the build run."
    fi
fi

if [ "$PRINT_CACHE_KEY" -eq 1 ]; then
    if [ -n "$RESOLVE_FAILURE" ]; then
        # no cache key, the run itself reports the failure
        echo "$RESOLVE_FAILURE" >&2
    elif [ -z "$SKIP" ]; then
        echo "server-starttest-${LOADER}-${VERSIONS}-${MODE}-${MC_VERSION}-${LOADER_VERSION}-java${JAVA_VERSION}"
    fi
    exit 0
fi
if [ -n "$SKIP" ]; then
    mkdir -p "$WORK"
    printf '### Server start test: %s (%s versions, %s)\n\nSkipped: %s\n' "$LOADER" "$VERSIONS" "$MODE" "$SKIP" | tee "$WORK/summary.md"
    exit 0
fi

SUMMARY="$WORK/summary.md"
mkdir -p "$WORK/data" "$WORK/mods" "$WORK/logs"
# keep the cached server installation (libraries, server jar), but start every run with a clean mod list and world
rm -rf "$WORK/mods/"* "$WORK/logs/"* "$WORK/data/mods" "$WORK/data/config" "$WORK/data/world" \
       "$WORK/data/logs" "$WORK/data/crash-reports" "$WORK/data/.modrinth-manifest.json"
cp "$JAR" "$WORK/mods/"
: > "$SUMMARY"

log() { echo "$*"; echo "$*" >> "$SUMMARY"; }

log "### Server start test: $LOADER ($VERSIONS versions, $MODE)"
log ""
if [ -n "$RESOLVE_FAILURE" ]; then
    log "**The loader version or the dependencies could not be resolved:**"
    log ""
    log '```'
    log "$RESOLVE_FAILURE"
    log '```'
    exit 1
fi
BUILT_WITH=""
if [ -n "$BUILD_LOADER_VERSION" ] && [ "$BUILD_LOADER_VERSION" != "$LOADER_VERSION" ]; then
    BUILT_WITH=", built with $BUILD_LOADER_VERSION"
fi
log "- Minecraft $MC_VERSION, $LOADER_TYPE $LOADER_VERSION (range $LOADER_RANGE$BUILT_WITH), image \`$IMAGE\`"
log "- Mod: \`$(basename "$JAR")\`"
LOADER_ENV=(-e "TYPE=$LOADER_TYPE" -e "$LOADER_VERSION_ENV=$LOADER_VERSION")

MODRINTH_IDS=()
DEPENDENCY_IDS=()
SKIPPED=()
while IFS=$'\t' read -r line_type kind dep_id project version_id version_number dep_range; do
    case "$line_type" in
        MOD)
            MODRINTH_IDS+=("${project}:${version_id}")
            DEPENDENCY_IDS+=("$dep_id")
            log "- $kind: $project $version_number (range $dep_range)$([ "$project" != "$dep_id" ] && echo ", mod id $dep_id")" ;;
        SKIPPED)
            # (fields: SKIPPED <mod id> <reason>)
            SKIPPED+=("$kind")
            log "- skipped (not available): $kind - $dep_id" ;;
    esac
done <<< "$RESOLVED"
log ""

MODRINTH_PROJECTS="$(IFS=,; echo "${MODRINTH_IDS[*]:-}")"

cleanup() { docker rm -f "$NAME" > /dev/null 2>&1 || true; }
cleanup
trap cleanup EXIT

docker run -d --name "$NAME" \
    -e EULA=TRUE \
    -e VERSION="$MC_VERSION" \
    "${LOADER_ENV[@]}" \
    -e MODRINTH_PROJECTS="$MODRINTH_PROJECTS" \
    -e MODRINTH_DOWNLOAD_DEPENDENCIES=required \
    -e MEMORY=2G \
    -e UID="$(id -u)" -e GID="$(id -g)" \
    -e ONLINE_MODE=FALSE \
    -v "$WORK/data:/data" \
    -v "$WORK/mods:/mods:ro" \
    "$IMAGE" > /dev/null

# The server is started as soon as it logs "Done (...)!" (much earlier than the health check of the image reports it).
# After that the server keeps running a few seconds, so that errors right after the start end up in the log, too.
DONE_PATTERN='Done \([0-9.]+s\)!'
GRACE_SECONDS=5
echo "Waiting up to ${TIMEOUT}s for the server to start..."
STATUS="starting"
START=$(date +%s)
while true; do
    STATE="$(docker inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null || echo missing)"
    # (no grep -q: its early exit would fail the pipe with SIGPIPE under pipefail)
    if docker logs "$NAME" 2>&1 | grep -E "$DONE_PATTERN" > /dev/null; then
        STATUS="started"
        sleep "$GRACE_SECONDS"
        STATE="$(docker inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null || echo missing)"
        break
    fi
    if [ "$STATE" != "running" ]; then
        STATUS="stopped"
        break
    fi
    if [ $(( $(date +%s) - START )) -ge "$TIMEOUT" ]; then
        STATUS="timeout"
        break
    fi
    sleep 1
done
echo "Server state: $STATE, start: $STATUS after $(( $(date +%s) - START ))s"

# stop gracefully (SIGTERM is forwarded to the server, which saves and shuts down)
docker stop -t 120 "$NAME" > /dev/null 2>&1 || true
docker logs "$NAME" > "$WORK/logs/container.log" 2>&1 || true
cp -r "$WORK/data/logs/." "$WORK/logs/" 2>/dev/null || true
cp -r "$WORK/data/crash-reports" "$WORK/logs/" 2>/dev/null || true
ls "$WORK/data/mods" > "$WORK/logs/installed-mods.txt" 2>/dev/null || true

FAILED=0
if [ "$STATUS" != "started" ]; then
    log "**Server did not start (state: $STATE, start: $STATUS).**"
    FAILED=1
elif [ "$STATE" != "running" ]; then
    log "**Server stopped within ${GRACE_SECONDS}s after the start (state: $STATE).**"
    FAILED=1
fi

# Known harmless lines of the server log (built-in, one extended regex per line), extended by the allowlist of the mod.
BUILTIN_ALLOWLIST='
# Forge/NeoForge on Linux: Netty probes the macOS-only kqueue transport while the debug log file is written
An exception occurred processing Appender DebugFile
AppenderLoggingException: java\.lang\.NoClassDefFoundError: Could not initialize class io\.netty\.channel\.kqueue\.Native
ExceptionInInitializerError: Exception java\.lang\.IllegalStateException: Only supported on OSX/BSD
# Forge: LAN advertising of the dedicated server fails, because the container has no broadcast network
java\.net\.SocketException: Network is unreachable
'
ALLOWLIST="$WORK/allowlist.txt"
{ echo "$BUILTIN_ALLOWLIST"; [ -f "$ALLOWLIST_FILE" ] && cat "$ALLOWLIST_FILE"; } | tr -d '\r' | grep -vE '^[[:space:]]*(#|$)' > "$ALLOWLIST" || true

# Problems in the server log
SERVER_LOG="$WORK/logs/container.log"
PROBLEMS="$WORK/logs/problems.log"
# (crashes are detected via the crash-reports directory below, "crash" alone matches mod names like fabric-crash-report-info)
grep -inE "exception|mixin.*(error|fail)|error.*${MOD_ID}|${MOD_ID}.*error" "$SERVER_LOG" > "$PROBLEMS" || true
if [ -s "$PROBLEMS" ] && [ -s "$ALLOWLIST" ]; then
    # exit code 1 only means that every line was allowed, 2 is an invalid regex (which would hide all problems)
    rc=0
    grep -vEf "$ALLOWLIST" "$PROBLEMS" > "$PROBLEMS.tmp" || rc=$?
    if [ "$rc" -gt 1 ]; then
        log "**Invalid regex in the allowlist** ($ALLOWLIST_FILE or the built-in one), see the grep error above."
        exit 2
    fi
    mv "$PROBLEMS.tmp" "$PROBLEMS"
fi
if [ -s "$PROBLEMS" ]; then
    log "**Server log contains $(wc -l < "$PROBLEMS") problem line(s):**"
    log ""
    log '```'
    head -n 40 "$PROBLEMS" >> "$SUMMARY"
    head -n 40 "$PROBLEMS"
    log '```'
    FAILED=1
fi
if ! grep -qiE "Done \([0-9.]+s\)!" "$SERVER_LOG"; then
    log "**Server log does not contain the \"Done\" message.**"
    FAILED=1
fi
# The mod must be in the mod list of the loader (otherwise a wrong jar, metadata or environment would pass silently):
# Fabric "	- modid 1.0", NeoForge " - modid (jar(...))", Forge "Found valid mod file ... with {modid}"
# The installed dependencies are checked the same way (a Modrinth project with the same name but another mod fails).
loaded_pattern() { echo "^[[:space:]]*- $1( |\$)|^[[:space:]]*- $1 \(jar\(|Found valid mod file .*\{([^}]*[ ,])?$1([ ,][^}]*)?\}"; }
for loaded_id in "$MOD_ID" ${DEPENDENCY_IDS[@]+"${DEPENDENCY_IDS[@]}"}; do
    if ! grep -qsE "$(loaded_pattern "$loaded_id")" "$WORK"/logs/*.log; then
        log "**The mod $loaded_id was not loaded** (not found in the mod list of the server log)."
        FAILED=1
    fi
done
if [ -d "$WORK/logs/crash-reports" ]; then
    log "**Crash report(s) found:** $(ls "$WORK/logs/crash-reports" | tr '\n' ' ')"
    FAILED=1
fi

if [ "$FAILED" -ne 0 ]; then
    log ""
    log "Last lines of the server log:"
    log '```'
    tail -n 60 "$SERVER_LOG" | tee -a "$SUMMARY"
    log '```'
    echo "Server start test FAILED. Logs: $WORK/logs"
    exit 1
fi
log "Server started cleanly. ✅"
if [ -s "$WORK/logs/installed-mods.txt" ]; then
    log ""
    log "Installed mods: $(tr '\n' ' ' < "$WORK/logs/installed-mods.txt")"
fi
if [ "${#SKIPPED[@]}" -gt 0 ]; then
    log ""
    log "Skipped integrations: ${SKIPPED[*]}"
fi
