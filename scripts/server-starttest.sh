#!/usr/bin/env bash
# Server start test: starts a real dedicated server (Docker image itzg/minecraft-server) with the built release jar of
# one loader and checks that it starts cleanly. Used by .github/workflows/server-starttest.yml and can be run locally
# in the root directory of a mod repository:
#
#   ./gradlew build
#   curl -fsSL https://raw.githubusercontent.com/cech12/MinecraftModActions/main/scripts/server-starttest.sh \
#       | bash -s -- <fabric|forge|neoforge> [--with-integrations]
#
# The test runs with the Minecraft version of the mod, but with the NEWEST loader version and the NEWEST versions of
# all dependencies, so that it notices when a new loader or dependency release breaks the mod.
#
# Options:
#   --with-integrations  also install the optional dependencies of the mod. If the mod has none for this loader, this
#                        run would equal the run without the option: the script prints a note and exits 0.
#   --print-cache-key    only print the cache key of the server installation in $STARTTEST_DIR/<loader>-<mode>/data
#                        (empty if the run is skipped, see above) and exit. Used by the CI.
#
# For multiloader projects with one subproject per loader (fabric/forge/neoforge), like the MultiLoader template.
# Requirements: bash, docker, curl, jq, unzip.
#
# Everything comes from the mod repository and its built jar:
#   gradle.properties                    minecraft_version, mod_id, java_version
#   dependencies                         read from the metadata in the jar: fabric.mod.json (depends = required,
#                                        recommends/suggests = optional) or neoforge.mods.toml/mods.toml (required or
#                                        optional, client only dependencies are ignored). They are installed from
#                                        Modrinth; mod ids with another Modrinth project name are mapped in
#                                        server-starttest-mods.txt next to this script (one central list for all mods).
#                                        Required dependencies of these mods are installed automatically.
#   scripts/server-starttest.allowlist   (optional) regexes of harmless log lines, in addition to the built-in ones
#
# Environment variables (optional):
#   STARTTEST_TIMEOUT          seconds to wait for the server start (default 600)
#   STARTTEST_DIR              working directory for server data and logs (default <mod repository>/.server-starttest)
#   STARTTEST_IMAGE            docker image (default itzg/minecraft-server:java<java version>)
#   STARTTEST_MOD_DIR          root directory of the mod repository (default: current directory)
#   STARTTEST_LOADER_VERSION   loader version to use instead of the newest one (e.g. to reproduce a failure)
#   STARTTEST_ACTIONS_REF      branch or tag of cech12/MinecraftModActions to download the mod id mapping from when it
#                              is not next to the script (default main)
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
WORK="${STARTTEST_DIR:-$MOD_DIR/.server-starttest}/${LOADER}-${MODE}"
NAME="${MOD_ID}-starttest-${LOADER}-${MODE}"

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

# Newest loader version for the Minecraft version
newest_loader_version() {
    local prefix rest
    case "$LOADER" in
        fabric)
            api "https://meta.fabricmc.net/v2/versions/loader/$MC_VERSION" | jq -r '.[0].loader.version // empty' ;;
        forge)
            api "https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json" \
                | jq -r --arg key "$MC_VERSION-latest" '.promos[$key] // empty' ;;
        neoforge)
            # NeoForge versions start with the Minecraft version without "1." (1.21.1 -> 21.1.x, 1.21 -> 21.0.x, 26.3 -> 26.3.x)
            if [[ "$MC_VERSION" == 1.* ]]; then
                rest="${MC_VERSION#1.}"
                if [[ "$rest" == *.* ]]; then prefix="$rest."; else prefix="$rest.0."; fi
            else
                prefix="$MC_VERSION."
            fi
            api "https://maven.neoforged.net/api/maven/versions/releases/net/neoforged/neoforge" \
                | jq -r --arg prefix "$prefix" '.versions[] | select(startswith($prefix))' | sort -V | tail -n 1 ;;
    esac
}
if [ -n "${STARTTEST_LOADER_VERSION:-}" ]; then
    LOADER_VERSION="$STARTTEST_LOADER_VERSION"
else
    if ! LOADER_VERSION="$(newest_loader_version)"; then
        echo "The newest $LOADER version for Minecraft $MC_VERSION could not be determined (network or API error, see above)." >&2
        exit 1
    fi
    if [ -z "$LOADER_VERSION" ]; then
        echo "There is no $LOADER version for Minecraft $MC_VERSION yet." >&2
        exit 1
    fi
fi
LOADER_ENV=(-e "TYPE=$LOADER_TYPE" -e "$LOADER_VERSION_ENV=$LOADER_VERSION")

# Central mapping of mod ids to Modrinth projects (next to this script, otherwise downloaded)
if [ -f "$SCRIPT_DIR/server-starttest-mods.txt" ]; then
    MAPPING="$(cat "$SCRIPT_DIR/server-starttest-mods.txt")"
elif ! MAPPING="$(api "https://raw.githubusercontent.com/cech12/MinecraftModActions/${STARTTEST_ACTIONS_REF:-main}/scripts/server-starttest-mods.txt")"; then
    echo "The mod id mapping server-starttest-mods.txt could not be downloaded." >&2
    exit 1
fi
MAPPING="$(tr -d '\r' <<< "$MAPPING" | grep -vE '^[[:space:]]*(#|$)' || true)"

# Dependencies from the metadata of the jar: "<required|optional> <mod id>"
metadata_dependencies() {
    case "$LOADER" in
        fabric)
            unzip -p "$JAR" fabric.mod.json | jq -r '
                ((.depends // {}) | keys[] | "required " + .),
                (((.recommends // {}) + (.suggests // {})) | keys[] | "optional " + .)' ;;
        forge|neoforge)
            local file=META-INF/mods.toml
            if [ "$LOADER" = "neoforge" ] && unzip -l "$JAR" META-INF/neoforge.mods.toml > /dev/null 2>&1; then
                file=META-INF/neoforge.mods.toml
            fi
            # [[dependencies.<mod>]] blocks: modId, type (NeoForge, newer Forge) or mandatory (Forge), side
            unzip -p "$JAR" "$file" | tr -d '\r' | awk '
                function value(line) { sub(/#.*/, "", line); sub(/^[^=]*=/, "", line); gsub(/["\047 \t]/, "", line); return line }
                function flush() {
                    if (dep && id != "") {
                        k = tolower(kind)
                        if (k == "" || k == "true") k = "required"
                        if (k == "false") k = "optional"
                        if ((k == "required" || k == "optional") && toupper(side) != "CLIENT") print k, id
                    }
                    id = ""; kind = ""; side = ""
                }
                /^[ \t]*\[/ { flush(); dep = ($0 ~ /^[ \t]*\[\[dependencies\./); next }
                dep && /^[ \t]*modId[ \t]*=/ { id = value($0) }
                dep && /^[ \t]*(type|mandatory)[ \t]*=/ { kind = value($0) }
                dep && /^[ \t]*side[ \t]*=/ { side = value($0) }
                END { flush() }' ;;
    esac
}
# Mods to install: "<required|optional> <mod id> <modrinth projects...>" without the loader, Minecraft and the mod
# itself, and without mod ids that the mapping ignores ("-"). A mod that is required and optional counts as required.
dependencies() {
    local kind id slugs
    # (reverse order: "required" lines before "optional" lines, so that the required kind wins below)
    metadata_dependencies | sort -r -u | while read -r kind id; do
        case "$id" in
            minecraft|java|fabricloader|fabric-loader|forge|neoforge|"$MOD_ID"|'${'*) continue ;;
        esac
        slugs="$(awk -v id="$id" '$1 == id { $1 = ""; sub(/^ /, ""); print; exit }' <<< "$MAPPING")"
        [ "$slugs" = "-" ] && continue
        echo "$kind $id ${slugs:-$id}"
    done | awk '!seen[$2]++'
}
# (not in a pipe or process substitution, so that a broken jar stops the script)
if ! DEPS="$(dependencies)"; then
    echo "The dependencies could not be read from the metadata of $JAR." >&2
    exit 2
fi

# The integrations run only makes sense if the mod has optional dependencies, otherwise it equals the required run.
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
    printf '### Server start test: %s (%s)\n\nSkipped: the mod has no optional dependencies for %s, this run would equal the run without integrations.\n' \
        "$LOADER" "$MODE" "$LOADER" | tee "$WORK/summary.md"
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

log "### Server start test: $LOADER ($MODE)"
log ""
if [ -n "$BUILD_LOADER_VERSION" ] && [ "$BUILD_LOADER_VERSION" != "$LOADER_VERSION" ]; then
    log "- Minecraft $MC_VERSION, $LOADER_TYPE $LOADER_VERSION (newest, built with $BUILD_LOADER_VERSION), image \`$IMAGE\`"
else
    log "- Minecraft $MC_VERSION, $LOADER_TYPE $LOADER_VERSION, image \`$IMAGE\`"
fi
log "- Mod: \`$(basename "$JAR")\`"

# Newest version of each dependency on Modrinth: the newest release, otherwise the newest version. If the mapping lists
# several Modrinth projects for a mod id, the first one with a version for this loader and Minecraft version is used.
MODRINTH_IDS=()
SKIPPED=()
while read -r dep_kind dep_id dep_slugs; do
    [ -z "${dep_kind:-}" ] && continue
    [ "$dep_kind" = "optional" ] && [ "$MODE" != "integrations" ] && continue
    found=""
    for slug in $dep_slugs; do
        if ! versions="$(api -G "https://api.modrinth.com/v2/project/${slug}/version" \
            --data-urlencode "loaders=[\"${LOADER}\"]" \
            --data-urlencode "game_versions=[\"${MC_VERSION}\"]" 2> "$WORK/curl-error.txt")"; then
            # an unknown project is "not available", every other error stops the test
            if grep -q "404" "$WORK/curl-error.txt"; then continue; fi
            cat "$WORK/curl-error.txt" >&2
            log "- **Modrinth request for $slug failed** (network or API error, see above)"
            exit 1
        fi
        version="$(jq -r '((map(select(.version_type == "release")) + .)[0]) | (.id // empty) + " " + (.version_number // empty)' <<< "$versions")"
        if [ -n "${version// /}" ]; then
            found="$slug"
            MODRINTH_IDS+=("${slug}:${version%% *}")
            log "- $dep_kind: $slug ${version#* }$([ "$slug" != "$dep_id" ] && echo " (mod id $dep_id)")"
            break
        fi
    done
    if [ -z "$found" ]; then
        if [ "$dep_kind" = "required" ]; then
            log "- **required dependency $dep_id is not available on Modrinth for $LOADER $MC_VERSION** (Modrinth projects: $dep_slugs). If the mod has another name on Modrinth, add it to server-starttest-mods.txt of cech12/MinecraftModActions."
            exit 1
        fi
        SKIPPED+=("$dep_id")
        log "- skipped (not available for $LOADER $MC_VERSION): $dep_id (Modrinth projects: $dep_slugs)"
    fi
done <<< "$DEPS"
rm -f "$WORK/curl-error.txt"
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
LOADED_PATTERN="^[[:space:]]*- ${MOD_ID}( |\$)|^[[:space:]]*- ${MOD_ID} \(jar\(|Found valid mod file .*\{([^}]*[ ,])?${MOD_ID}([ ,][^}]*)?\}"
if ! grep -qsE "$LOADED_PATTERN" "$WORK"/logs/*.log; then
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
