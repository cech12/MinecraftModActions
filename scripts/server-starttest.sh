#!/usr/bin/env bash
# Server start test: starts a real dedicated server (Docker image itzg/minecraft-server) with the built release jar of
# one loader and checks that it starts cleanly. Used by .github/workflows/server-starttest.yml and can be run locally
# in the root directory of a mod repository:
#
#   ./gradlew build
#   curl -fsSL https://raw.githubusercontent.com/cech12/MinecraftModActions/main/scripts/server-starttest.sh \
#       | bash -s -- <fabric|forge|neoforge> [--with-integrations]
#
# Options:
#   --with-integrations  also install the optional mods of scripts/server-starttest.deps. If the loader has no optional
#                        mods, this run would equal the run without the option: the script prints a note and exits 0.
#   --print-cache-key    only print the cache key of the server installation in $STARTTEST_DIR/<loader>-<mode>/data
#                        (empty if the run is skipped, see above) and exit. Used by the CI.
#
# For multiloader projects with one subproject per loader (fabric/forge/neoforge), like the MultiLoader template.
# Requirements: bash, docker, curl, jq.
#
# Everything comes from the mod repository:
#   gradle.properties                    minecraft_version, mod_id, java_version and the loader version
#                                        (fabric_loader_version, forge_version or neoforge_version)
#   scripts/server-starttest.deps        (optional) additional mods from Modrinth, one per line:
#                                        <loader|*> <required|optional> <modrinth slug> <version>
#                                        <version>: a gradle.properties key, "=<version number>" or "latest"
#                                        Required dependencies of these mods are installed automatically.
#   scripts/server-starttest.allowlist   (optional) regexes of harmless log lines, in addition to the built-in ones
#
# Environment variables (optional):
#   STARTTEST_TIMEOUT   seconds to wait for a healthy server (default 600)
#   STARTTEST_DIR       working directory for server data and logs (default <mod repository>/.server-starttest)
#   STARTTEST_IMAGE     docker image (default itzg/minecraft-server:java<java version>)
#   STARTTEST_MOD_DIR   root directory of the mod repository (default: current directory)
set -euo pipefail

usage() { echo "Usage: $0 <fabric|forge|neoforge> [--with-integrations] [--print-cache-key]" >&2; exit 2; }
LOADER="${1:-}"
[ $# -gt 0 ] && shift
MODE="required"
PRINT_CACHE_KEY=0
for arg in "$@"; do
    case "$arg" in
        --with-integrations) MODE="integrations" ;;
        --print-cache-key) PRINT_CACHE_KEY=1 ;;
        *) echo "Unknown option: $arg" >&2; usage ;;
    esac
done
case "$LOADER" in
    fabric)   LOADER_TYPE=FABRIC;   LOADER_VERSION_KEY=fabric_loader_version; LOADER_VERSION_ENV=FABRIC_LOADER_VERSION ;;
    forge)    LOADER_TYPE=FORGE;    LOADER_VERSION_KEY=forge_version;         LOADER_VERSION_ENV=FORGE_VERSION ;;
    neoforge) LOADER_TYPE=NEOFORGE; LOADER_VERSION_KEY=neoforge_version;      LOADER_VERSION_ENV=NEOFORGE_VERSION ;;
    *) usage ;;
esac

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

DEPS_FILE="scripts/server-starttest.deps"
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

MC_VERSION="$(prop minecraft_version)"
MOD_ID="$(prop mod_id)"
LOADER_VERSION="$(prop "$LOADER_VERSION_KEY")"
JAVA_VERSION="$(prop java_version)"
IMAGE="${STARTTEST_IMAGE:-itzg/minecraft-server:java${JAVA_VERSION}}"
TIMEOUT="${STARTTEST_TIMEOUT:-600}"
WORK="${STARTTEST_DIR:-$MOD_DIR/.server-starttest}/${LOADER}-${MODE}"
NAME="${MOD_ID}-starttest-${LOADER}-${MODE}"
LOADER_ENV=(-e "TYPE=$LOADER_TYPE" -e "$LOADER_VERSION_ENV=$LOADER_VERSION")

# lines of the deps file for this loader: "<kind> <slug> <version>"
deps_for_loader() {
    [ -f "$DEPS_FILE" ] || return 0
    while read -r dep_loader dep_kind dep_slug dep_version _; do
        [ -z "${dep_loader:-}" ] && continue
        case "$dep_loader" in \#*) continue ;; esac
        if [ "$dep_loader" != "$LOADER" ] && [ "$dep_loader" != "*" ]; then continue; fi
        case "$dep_kind" in
            required|optional) ;;
            *) echo "Invalid kind '$dep_kind' in $DEPS_FILE (required or optional)" >&2; exit 2 ;;
        esac
        if [ -z "${dep_slug:-}" ] || [ -z "${dep_version:-}" ]; then
            echo "Invalid line in $DEPS_FILE: $dep_loader $dep_kind ${dep_slug:-} ${dep_version:-}" >&2
            exit 2
        fi
        echo "$dep_kind $dep_slug $dep_version"
    done < "$DEPS_FILE"
}

# (not in a pipe or process substitution, so that an invalid deps file stops the script)
DEPS="$(deps_for_loader)"

# The integrations run only makes sense if the loader has optional mods, otherwise it equals the required run.
SKIP=0
if [ "$MODE" = "integrations" ] && ! grep -q "^optional " <<< "$DEPS"; then
    SKIP=1
fi

if [ "$PRINT_CACHE_KEY" -eq 1 ]; then
    [ "$SKIP" -eq 0 ] && echo "server-starttest-${LOADER}-${MODE}-${MC_VERSION}-${LOADER_VERSION}-java${JAVA_VERSION}"
    exit 0
fi
if [ "$SKIP" -eq 1 ]; then
    mkdir -p "$WORK"
    printf '### Server start test: %s (%s)\n\nSkipped: no optional mods for %s in %s, this run would equal the run without integrations.\n' \
        "$LOADER" "$MODE" "$LOADER" "$DEPS_FILE" | tee "$WORK/summary.md"
    exit 0
fi

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

SUMMARY="$WORK/summary.md"
mkdir -p "$WORK/data" "$WORK/mods" "$WORK/logs"
# keep the cached server installation (libraries, server jar), but start every run with a clean mod list and world
rm -rf "$WORK/mods/"* "$WORK/logs/"* "$WORK/data/mods" "$WORK/data/config" "$WORK/data/world" \
       "$WORK/data/logs" "$WORK/data/crash-reports" "$WORK/data/.modrinth-manifest.json"
cp "$JAR" "$WORK/mods/"
: > "$SUMMARY"

log() { echo "$*"; echo "$*" >> "$SUMMARY"; }

log "### Server start test: $LOADER ($MODE)"
log ""
log "- Minecraft $MC_VERSION, $LOADER_TYPE $LOADER_VERSION, image \`$IMAGE\`"
log "- Mod: \`$(basename "$JAR")\`"

# Resolve the additional mods to Modrinth version ids.
MODRINTH_IDS=()
SKIPPED=()
while read -r dep_kind dep_slug dep_version; do
    [ -z "${dep_kind:-}" ] && continue
    [ "$dep_kind" = "optional" ] && [ "$MODE" != "integrations" ] && continue
    case "$dep_version" in
        latest) version="latest" ;;
        =*) version="${dep_version#=}" ;;
        *) version="$(prop "$dep_version")" ;;
    esac
    # a failed request is an error, only an empty result means "not available"
    if ! versions="$(curl -fsS --max-time 30 --retry 3 --retry-all-errors \
        -A "server-starttest (github.com/cech12/MinecraftModActions)" -G \
        "https://api.modrinth.com/v2/project/${dep_slug}/version" \
        --data-urlencode "loaders=[\"${LOADER}\"]" \
        --data-urlencode "game_versions=[\"${MC_VERSION}\"]")"; then
        log "- **Modrinth request for $dep_slug failed** (network or API error, see above)"
        exit 1
    fi
    if [ "$version" = "latest" ]; then
        # newest release, otherwise the newest version (the API returns the newest first)
        version_id="$(jq -r '((map(select(.version_type == "release")) + .)[0]) | .id // empty' <<< "$versions")"
        version="$(jq -r --arg id "$version_id" 'map(select(.id == $id))[0].version_number // "latest"' <<< "$versions")"
    else
        # exact version number first, then with build metadata (e.g. 26.3.158+fabric), then with a "-" suffix
        # (e.g. 20.0.149-fabric) only if it is a release, so that a pre-release like 1.2-beta is never picked for 1.2
        version_id="$(jq -r --arg v "$version" \
            '(map(select(.version_number == $v))
              + map(select(.version_number | startswith($v + "+")))
              + map(select((.version_number | startswith($v + "-")) and .version_type == "release")))[0].id // empty' <<< "$versions")"
    fi
    if [ -n "$version_id" ]; then
        MODRINTH_IDS+=("${dep_slug}:${version_id}")
        log "- $dep_kind: $dep_slug $version"
    elif [ "$dep_kind" = "required" ]; then
        log "- **required mod $dep_slug $version is not available on Modrinth for $LOADER $MC_VERSION**"
        exit 1
    else
        SKIPPED+=("$dep_slug $version")
        log "- skipped (not available for $LOADER $MC_VERSION): $dep_slug $version"
    fi
done <<< "$DEPS"
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
    if docker logs "$NAME" 2>&1 | grep -qE "$DONE_PATTERN"; then
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
# Fabric "	- modid 1.0", NeoForge "Mod Name 1.0 (modid)" / " - modid (jar(...))", Forge "Found valid mod file ... with {modid}"
LOADED_PATTERN="^[[:space:]]*- ${MOD_ID}( |\$)|\(${MOD_ID}\)|- ${MOD_ID} \(jar|mod file .*\{([^}]*[ ,])?${MOD_ID}([ ,][^}]*)?\}"
if ! cat "$WORK"/logs/*.log 2>/dev/null | grep -qE "$LOADED_PATTERN"; then
    log "**The mod $MOD_ID was not loaded** (not found in the mod list of the server log)."
    FAILED=1
fi
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
