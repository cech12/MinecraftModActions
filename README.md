# MinecraftModActions
This repository collects reusable GitHub workflows for my Minecraft mods (Fabric, Forge, NeoForge and multi loader
projects).

## Tests

### `gametest.yml`
Runs the GameTests of the mod with `runGameTestServer`.

| Input | Default | Description |
|---|---|---|
| `java-version` | (required) | Java version |
| `arguments` | | Additional Gradle arguments |
| `loaders` | `[""]` | JSON list of loader subprojects, e.g. `["fabric","forge","neoforge"]`. One job per loader runs `:<loader>:runGameTestServer`. Default: one job runs `runGameTestServer` of all projects. |
| `timeout-minutes` | `30` | Maximum run time of a job |

The mod repository provides the `runGameTestServer` task (failing if a test fails or no test was found). If it writes a
JUnit report to `[<loader>/]build/gametest-report.xml`, the number of tests and failures is shown in the job summary.
Reports and logs (`[<loader>/]runs/gametest/logs/`, `crash-reports/`) are uploaded as artifact.

```yaml
gametest:
  uses: cech12/MinecraftModActions/.github/workflows/gametest.yml@main
  with:
    java-version: 25
    loaders: '["fabric", "forge", "neoforge"]'
```

### `server-starttest.yml`
Starts the built release jar of every loader on a real dedicated server (Docker image
[itzg/minecraft-server](https://github.com/itzg/docker-minecraft-server)) and checks that it starts cleanly: once with
the required mods only and once with the optional integrations.

| Input | Default | Description |
|---|---|---|
| `loaders` | (required) | JSON list of loader subprojects, e.g. `["fabric","forge","neoforge"]` |
| `artifact-name` | `gradle-build` | Artifact with the built jars (output of `build.yml`). It is downloaded from the same workflow run, so the calling job needs `needs: build`. |
| `timeout` | `600` | Seconds to wait for a healthy server |
| `timeout-minutes` | `30` | Maximum run time of a job |

The mod repository provides:
- `scripts/server-starttest.sh <loader> [--with-integrations] [--print-cache-key]`, which does the actual test and can
  also be run locally (see WoodenShears for a reference implementation). It writes its result to
  `$STARTTEST_DIR/<loader>-<mode>/summary.md` and the logs to `$STARTTEST_DIR/<loader>-<mode>/logs/`. With
  `--print-cache-key` it only prints the cache key of the server installation in `$STARTTEST_DIR/<loader>-<mode>/data`,
  or nothing if the run is skipped (e.g. `--with-integrations` for a loader without optional mods).
- `scripts/server-starttest.deps` (optional): additional mods from Modrinth, one per line:
  `<loader> <required|optional> <modrinth slug> <gradle.properties key of the version>`.
- `scripts/server-starttest.allowlist` (optional): regexes of harmless log lines.

```yaml
server-starttest:
  needs: build
  uses: cech12/MinecraftModActions/.github/workflows/server-starttest.yml@main
  with:
    loaders: '["fabric", "forge", "neoforge"]'
```

## Known Fixes
If the gradle building failed with a message like `Gradle script '/home/runner/work/.../gradlew' is not executable`, you should run the following command in your repository:

    git update-index --chmod=+x gradlew
