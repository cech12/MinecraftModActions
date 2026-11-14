# MinecraftModActions
This repository collects reusable GitHub workflows for my Minecraft mods (Fabric, Forge, NeoForge and multi loader
projects).

## Build

### `build.yml`
Builds the mod (`./gradlew build`) and uploads the jars as artifact `gradle-build`.

| Input | Default | Description |
|---|---|---|
| `java-version` | (required) | Java version |
| `gametest` | `false` | Also run the game tests (`runGameTestServer` of all projects) after the build, in the same job. This is much faster than `gametest.yml`, because the Minecraft setup and the compiled classes of the build are reused. Summary and artifact `gametest` like `gametest.yml`. |

```yaml
build:
  uses: cech12/MinecraftModActions/.github/workflows/build.yml@main
  with:
    java-version: 25
    gametest: true
```

The game test servers of all loaders run at the same time (`--parallel`), each with the default heap of a quarter of
the runner memory. If a large mod runs out of memory, set `-Xmx` in the game test run configuration of the mod.
With `gametest: true` the job is named "Build & Game Test", otherwise it stays "Build".

## Tests

### `gametest.yml`
Runs the GameTests of the mod with `runGameTestServer` in separate jobs. Every job prepares Minecraft again, so for
multiloader projects the `gametest` input of `build.yml` is usually the faster choice.

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
| `actions-ref` | `main` | Branch or tag of this repository to take the script from. **Set it to the same ref as in `uses: …/server-starttest.yml@<ref>` whenever that ref is not `main`** (a tag or a feature branch), otherwise the workflow of one ref runs the script of `main`. GitHub does not tell a reusable workflow its own ref, so this cannot be detected automatically. |

The test itself is `scripts/server-starttest.sh` of this repository. It supports multiloader projects with one
subproject per loader (`fabric`/`forge`/`neoforge`, like the MultiLoader template). Run it locally in the
root directory of a mod (needs bash, Docker, curl and jq):

```bash
./gradlew build
curl -fsSL https://raw.githubusercontent.com/cech12/MinecraftModActions/main/scripts/server-starttest.sh | bash -s -- fabric --with-integrations
```

It takes everything from the mod repository:
- `gradle.properties`: `minecraft_version`, `mod_id`, `java_version` and the loader version (`fabric_loader_version`,
  `forge_version`, `neoforge_version`).
- `scripts/server-starttest.deps` (optional): additional mods from Modrinth, one per line:
  `<loader|*> <required|optional> <modrinth slug> <version>`. `<version>` is a `gradle.properties` key, `=<version
  number>` or `latest`. Required mods must exist, optional mods are only installed with `--with-integrations` and are
  skipped if they are not available for the Minecraft version yet. Their required dependencies are installed
  automatically. A loader without optional mods skips the `--with-integrations` run.
- `scripts/server-starttest.allowlist` (optional): extended regexes of harmless log lines, in addition to the built-in
  ones (Netty kqueue probing and LAN advertising in containers).

The test fails if the server does not log "Done" within the timeout, stops again within 5 seconds, writes a crash
report, logs exceptions, mixin errors or errors mentioning the mod id, or if the mod is not in the mod list of the
loader (wrong jar, metadata or environment).

Example `scripts/server-starttest.deps`:

```
fabric  required  fabric-api    fabric_version
fabric  required  cloth-config  cloth_config_version
*       required  bucketlib     bucketlib_version
fabric  optional  modmenu       mod_menu_version
*       optional  jei           jei_version
neoforge optional jade          latest
```

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
