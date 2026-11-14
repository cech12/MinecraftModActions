#!/usr/bin/env python3
"""Resolves the loader version and the dependencies of a mod for the server start test (server-starttest.sh).

The dependencies and their version ranges are read from the metadata of the built jar (fabric.mod.json,
neoforge.mods.toml, mods.toml). Every version that is chosen satisfies these ranges (lower and upper bounds).

Version sets (--versions):
  build    loader version of gradle.properties, dependencies in the version of gradle.properties (preferably the
           *_version key named like the mod id, e.g. cloth_config_version), otherwise the minimum version
  minimum  oldest loader and dependency versions that satisfy the ranges of the metadata
  newest   newest loader and dependency versions that satisfy the ranges (releases preferred)

Output (tab separated lines on stdout):
  LOADER_VERSION   <version>  <range of the metadata or "*">
  BUILD_LOADER_VERSION  <version of gradle.properties or "">
  OPTIONAL_COUNT   <number of installed optional dependencies (with --integrations), client only mods excluded>
  SAME_AS_BUILD    (only with --versions minimum, if the result equals the build versions)
  MOD              <required|optional> <mod id> <modrinth project> <version id> <version number> <range> <note>
  SKIPPED          <mod id> <reason>   (optional dependencies that are not available)
Errors are printed to stderr, the exit code is 1 (resolution failed) or 2 (usage, broken jar).
"""
import argparse
import io
import json
import re
import sys
import time
import tomllib
import urllib.error
import urllib.parse
import urllib.request
import zipfile

USER_AGENT = "server-starttest (github.com/cech12/MinecraftModActions)"
PLATFORM_IDS = {"minecraft", "java", "fabricloader", "fabric-loader", "forge", "neoforge"}
LOADER_IDS = {"fabric": "fabricloader", "forge": "forge", "neoforge": "neoforge"}


class Failure(Exception):
    pass


# ---------------------------------------------------------------- web requests

def fetch(url, params=None):
    """Returns the response body, None for 404. Retries network errors and server errors."""
    if params:
        url += "?" + urllib.parse.urlencode(params)
    error = None
    for attempt in range(4):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(request, timeout=30) as response:
                return response.read()
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            if e.code < 500 and e.code != 429:
                raise Failure(f"request failed: {url}: HTTP {e.code}")
            error = e
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            error = e
        time.sleep(2 * (attempt + 1))
    raise Failure(f"request failed: {url}: {error}")


def fetch_json(url, params=None):
    body = fetch(url, params)
    return None if body is None else json.loads(body)


# ---------------------------------------------------------------- versions and ranges

QUALIFIER_ORDER = {"alpha": 0, "a": 0, "beta": 1, "b": 1, "milestone": 2, "m": 2, "pre": 3, "rc": 3, "cr": 3,
                   "snapshot": 4}


def version_key(version):
    """Sort key for loader and mod versions (SemVer like, Maven like qualifiers). Build metadata (+...) is ignored."""
    core = version.split("+", 1)[0]
    match = re.match(r"^(\d+(?:\.\d+)*)(.*)$", core)
    if not match:
        return ((), 0, tuple((1, t) for t in re.findall(r"\d+|[A-Za-z]+", core)))
    numbers = tuple(int(n) for n in match.group(1).split("."))
    while len(numbers) > 1 and numbers[-1] == 0:
        numbers = numbers[:-1]
    rest = match.group(2).lstrip("-._")
    tokens = []
    for token in re.findall(r"\d+|[A-Za-z]+", rest):
        if token.isdigit():
            tokens.append((2, int(token), ""))
        else:
            tokens.append((0, QUALIFIER_ORDER.get(token.lower(), 5), token.lower()))
    # a version without qualifier is newer than its pre-releases (1.0 > 1.0-beta)
    return (numbers, 0 if tokens else 1, tuple(tokens))


def compare(a, b):
    ka, kb = version_key(a), version_key(b)
    return (ka > kb) - (ka < kb)


def is_prerelease(version):
    return version_key(version)[1] == 0


def bump(version, part):
    """Next version of a part: bump("1.2.3", 1) = "1.3"."""
    numbers = [int(n) for n in re.findall(r"\d+", version.split("+")[0].split("-")[0])][:part + 1]
    while len(numbers) <= part:
        numbers.append(0)
    numbers[part] += 1
    return ".".join(str(n) for n in numbers)


def fabric_predicate(text):
    """One Fabric version predicate as list of (operator, version)."""
    text = text.strip()
    if text in ("", "*"):
        return []
    match = re.match(r"^(>=|<=|>|<|=|~|\^)?\s*(.+)$", text)
    operator, version = match.group(1) or "", match.group(2)
    if operator == "" and re.search(r"\.[xX*](\.|$)", version):
        base = re.split(r"\.[xX*]", version)[0]
        return [(">=", base), ("<", bump(base, base.count(".")))]
    if operator == "~":
        return [(">=", version), ("<", bump(version, 1))]
    if operator == "^":
        major = int(re.match(r"\d+", version).group(0)) if re.match(r"\d+", version) else 0
        return [(">=", version), ("<", bump(version, 0 if major > 0 else 1))]
    return [(operator or "=", version)]


def fabric_range(spec):
    """Fabric dependency version spec (string or list of strings, OR) as list of alternatives (AND of predicates)."""
    specs = spec if isinstance(spec, list) else [spec]
    alternatives = []
    for item in specs:
        predicates = []
        for part in str(item).split():
            predicates += fabric_predicate(part)
        alternatives.append(predicates)
    return alternatives or [[]]


def maven_range(spec):
    """Maven version range ("[1,2)", "[1,)", "(,2]", "[1]", several separated by commas, "" or "*" = any)."""
    spec = (spec or "").strip()
    if spec in ("", "*"):
        return [[]]
    alternatives = []
    for match in re.finditer(r"([\[(])([^\])]*)([\])])", spec):
        lower_type, content, upper_type = match.groups()
        if "," not in content:
            alternatives.append([("=", content.strip())])
            continue
        lower, upper = (p.strip() for p in content.split(",", 1))
        predicates = []
        if lower:
            predicates.append((">=" if lower_type == "[" else ">", lower))
        if upper:
            predicates.append(("<=" if upper_type == "]" else "<", upper))
        alternatives.append(predicates)
    # a plain version is a soft requirement (any version)
    return alternatives or [[]]


def satisfies(version, alternatives):
    def check(operator, bound):
        c = compare(version, bound)
        return {">=": c >= 0, ">": c > 0, "<=": c <= 0, "<": c < 0, "=": c == 0}[operator]
    return any(all(check(o, b) for o, b in predicates) for predicates in alternatives)


def range_text(alternatives):
    texts = [" ".join(o + b for o, b in predicates) or "*" for predicates in alternatives]
    return " || ".join(texts)


# ---------------------------------------------------------------- metadata of the jar

def read_toml(data):
    return tomllib.loads(data.decode("utf-8"))


def provided_mod_ids(jar, loader):
    """Mod ids of libraries bundled in the jar (jar in jar), they are no external dependencies."""
    ids = set()
    if loader == "fabric":
        metadata = json.loads(jar.read("fabric.mod.json"))
        nested = [entry.get("file") for entry in metadata.get("jars", []) if entry.get("file")]
    else:
        nested = [name for name in jar.namelist() if name.startswith("META-INF/jarjar/") and name.endswith(".jar")]
    for name in nested:
        try:
            with zipfile.ZipFile(io.BytesIO(jar.read(name))) as inner:
                names = inner.namelist()
                if "fabric.mod.json" in names:
                    metadata = json.loads(inner.read("fabric.mod.json"))
                    ids.add(metadata.get("id"))
                    ids.update(metadata.get("provides", []))
                for toml_name in ("META-INF/neoforge.mods.toml", "META-INF/mods.toml"):
                    if toml_name in names:
                        ids.update(mod.get("modId") for mod in read_toml(inner.read(toml_name)).get("mods", []))
        except (KeyError, zipfile.BadZipFile, ValueError, tomllib.TOMLDecodeError):
            continue
    ids.discard(None)
    return ids


def metadata_dependencies(jar_path, loader, mod_id):
    """Returns (loader range, list of (kind, mod id, range alternatives), provided mod ids)."""
    with zipfile.ZipFile(jar_path) as jar:
        provided = provided_mod_ids(jar, loader)
        dependencies = []
        loader_range = [[]]
        if loader == "fabric":
            metadata = json.loads(jar.read("fabric.mod.json"))
            for kind, section in (("required", "depends"), ("optional", "recommends"), ("optional", "suggests")):
                for dep_id, spec in (metadata.get(section) or {}).items():
                    if dep_id == "fabricloader":
                        loader_range = fabric_range(spec)
                    dependencies.append((kind, dep_id, fabric_range(spec)))
        else:
            name = "META-INF/mods.toml"
            if loader == "neoforge" and "META-INF/neoforge.mods.toml" in jar.namelist():
                name = "META-INF/neoforge.mods.toml"
            metadata = read_toml(jar.read(name))
            for entries in (metadata.get("dependencies") or {}).values():
                for entry in entries:
                    dep_id = entry.get("modId")
                    kind = str(entry.get("type", entry.get("mandatory", "required"))).lower()
                    kind = {"true": "required", "false": "optional"}.get(kind, kind)
                    if not dep_id or kind not in ("required", "optional"):
                        continue
                    if str(entry.get("side", "BOTH")).upper() == "CLIENT":
                        continue
                    alternatives = maven_range(entry.get("versionRange"))
                    if dep_id == LOADER_IDS[loader]:
                        loader_range = alternatives
                    dependencies.append((kind, dep_id, alternatives))
    result = {}
    for kind, dep_id, alternatives in dependencies:
        if dep_id in PLATFORM_IDS or dep_id == mod_id or dep_id in provided or dep_id.startswith("${"):
            continue
        # required wins over optional
        if dep_id not in result or kind == "required":
            result[dep_id] = (kind, alternatives)
    return loader_range, [(kind, dep_id, alt) for dep_id, (kind, alt) in result.items()], provided


# ---------------------------------------------------------------- mapping to Modrinth projects

def read_mapping(path):
    mapping = {}
    with open(path, encoding="utf-8") as file:
        for line in file:
            line = line.split("#", 1)[0].split()
            if len(line) >= 2:
                mapping[line[0]] = line[1:]
    return mapping


def modrinth_projects(dep_id, mapping):
    if dep_id in mapping:
        return [] if mapping[dep_id] == ["-"] else mapping[dep_id]
    return [dep_id]


# ---------------------------------------------------------------- loader versions

def loader_versions(loader, mc_version):
    """All loader versions for the Minecraft version (oldest first) and the set of stable ones (Fabric)."""
    if loader == "fabric":
        entries = fetch_json(f"https://meta.fabricmc.net/v2/versions/loader/{mc_version}") or []
        versions = [e["loader"]["version"] for e in entries]
        stable = {e["loader"]["version"] for e in entries if e["loader"].get("stable")}
        return sorted(versions, key=version_key), stable
    if loader == "neoforge":
        # NeoForge versions start with the Minecraft version without "1." (1.21.1 -> 21.1.x, 26.3 -> 26.3.x)
        if mc_version.startswith("1."):
            rest = mc_version[2:]
            prefix = rest + "." if "." in rest else rest + ".0."
        else:
            prefix = mc_version + "."
        data = fetch_json("https://maven.neoforged.net/api/maven/versions/releases/net/neoforged/neoforge") or {}
        versions = [v for v in data.get("versions", []) if v.startswith(prefix)]
        return sorted(versions, key=version_key), None
    body = fetch("https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml") or b""
    prefix = mc_version + "-"
    versions = [v[len(prefix):] for v in re.findall(r"<version>([^<]+)</version>", body.decode("utf-8"))
                if v.startswith(prefix)]
    return sorted(versions, key=version_key), None


def choose(candidates, mode, prefer=None):
    """Oldest (minimum) or newest version of the candidates (oldest first). Newest prefers the preferred ones."""
    if not candidates:
        return None
    if mode == "minimum":
        return candidates[0]
    preferred = [c for c in candidates if prefer is None or prefer(c)]
    return (preferred or candidates)[-1]


# ---------------------------------------------------------------- dependencies

def modrinth_versions(project, loader, mc_version):
    """Versions of a Modrinth project for the loader and Minecraft version (unsorted), None if unknown."""
    return fetch_json(f"https://api.modrinth.com/v2/project/{project}/version",
                      {"loaders": json.dumps([loader]), "game_versions": json.dumps([mc_version])})


_projects = {}


def modrinth_project(project):
    """Project data of Modrinth (cached), None if unknown."""
    if project not in _projects:
        _projects[project] = fetch_json(f"https://api.modrinth.com/v2/project/{project}")
    return _projects[project]


# gradle.properties keys that are no versions of dependencies
NO_DEPENDENCY_VERSION_KEYS = {"minecraft_version", "java_version", "mod_version", "fabric_loader_version",
                              "forge_version", "neoforge_version", "neo_form_version", "parchment_version"}


def normalized(name):
    return re.sub(r"[^a-z0-9]", "", name.lower())


def build_version_values(properties, dep_id, project):
    """Versions of gradle.properties that may be the build version of the dependency: first the values of keys that
    belong to the mod id or project (cloth_config_version -> cloth-config, mod_menu_version -> modmenu, jade_fabric_version
    -> jade), then all other dependency versions as fallback."""
    names = {normalized(dep_id), normalized(project)}
    named, other = [], []
    for key, value in properties.items():
        if not key.endswith("_version") or not value or key in NO_DEPENDENCY_VERSION_KEYS or "range" in key:
            continue
        key_name = normalized(key[:-len("_version")])
        if any(key_name.startswith(n) or n.startswith(key_name) for n in names):
            named.append(value)
        else:
            other.append(value)
    return named, other


def find_build_version(candidates, values):
    """Candidate with exactly one of the values as version number, otherwise with the value plus a "+"/"-" suffix."""
    for exact in (True, False):
        for value in values:
            for version in reversed(candidates):
                number = version["version_number"]
                if number == value if exact else (number.startswith(value + "+") or number.startswith(value + "-")):
                    return version
    return None


def mc_prefix(mc_version):
    return rf"^{re.escape(mc_version)}[-_+](?:(?:fabric|forge|neoforge|neo)[-_])?"


def comparable_version(version_number, mc_version, strip_mc_prefix=True):
    """Modrinth version number without common prefixes that are no part of the mod version ("v1.2", "26.3-1.2",
    "26.3_neo-1.2"), so that it can be compared with the version range of the metadata. The Minecraft prefix is kept if
    the range itself uses it (the mod version contains it)."""
    number = re.sub(r"^[vV](?=\d)", "", version_number)
    return re.sub(mc_prefix(mc_version), "", number) if strip_mc_prefix else number


def resolve_dependency(dep_id, alternatives, projects, loader, mc_version, mode, properties, server_only=False):
    """Returns (project, version, note) or (None, reason, None). With server_only, client only projects are not used."""
    reasons = []
    for project in projects:
        if server_only:
            data = modrinth_project(project)
            if data is not None and data.get("server_side") == "unsupported":
                reasons.append(f"{project}: client only mod, not loaded on a server")
                continue
        versions = modrinth_versions(project, loader, mc_version)
        if versions is None:
            reasons.append(f"{project}: no Modrinth project")
            continue
        if not versions:
            reasons.append(f"{project}: no version for {loader} {mc_version}")
            continue
        strip = not any(re.match(mc_prefix(mc_version), bound) for predicates in alternatives for _, bound in predicates)
        comparable = {v["id"]: comparable_version(v["version_number"], mc_version, strip) for v in versions}
        # oldest first, sorted like the range check compares
        versions = sorted(versions, key=lambda v: (version_key(comparable[v["id"]]), v["date_published"]))
        candidates = [v for v in versions if satisfies(comparable[v["id"]], alternatives)]
        if not candidates:
            # the Modrinth version numbers are chosen freely by the author and can differ from the mod version
            reasons.append(f"{project}: no Modrinth version number fits the range {range_text(alternatives)} of the "
                           f"metadata (version numbers: {', '.join(v['version_number'] for v in versions[-3:])}); the "
                           "Modrinth version numbers may not match the mod versions")
            continue
        if mode == "build":
            named, other = build_version_values(properties, dep_id, project)
            version = find_build_version(candidates, named) or find_build_version(candidates, other)
            if version is not None:
                return project, version, ""
            return project, candidates[0], "no build version in gradle.properties, minimum version used"
        return project, choose(candidates, mode, prefer=lambda v: v["version_type"] == "release"), ""
    return None, "; ".join(reasons) or "ignored", None


def resolve(args, mode):
    loader_range, dependencies, _ = metadata_dependencies(args.jar, args.loader, args.mod_id)
    if mode == "build" and args.build_loader_version:
        loader_version = args.build_loader_version
    else:
        versions, stable = loader_versions(args.loader, args.mc_version)
        candidates = [v for v in versions if satisfies(v, loader_range)]
        if args.loader_version:
            loader_version = args.loader_version
        else:
            loader_version = choose(candidates, mode,
                                    prefer=(lambda v: v in stable) if stable is not None else (lambda v: not is_prerelease(v)))
            if loader_version is None:
                raise Failure(f"no {args.loader} version for Minecraft {args.mc_version} in {range_text(loader_range)}")
    if args.loader_version:
        loader_version = args.loader_version
    mapping = read_mapping(args.mapping)
    mods, skipped, seen_projects = [], [], set()
    for kind, dep_id, alternatives in sorted(dependencies, key=lambda d: (d[0] != "required", d[1])):
        if kind == "optional" and not args.integrations:
            continue
        # (mods with a similar id that are no part of Fabric API are listed in the mapping, e.g. fabric-permissions-api-v0)
        if args.loader == "fabric" and dep_id not in mapping and (
                dep_id in ("fabric", "fabric-api-base") or re.match(r"^fabric-.+-v\d+$", dep_id)):
            message = (f"the dependency {dep_id} is a module or an old id of Fabric API, which is not supported: "
                       "declare fabric-api instead")
            if kind == "required":
                raise Failure(message)
            skipped.append((dep_id, message))
            continue
        projects = modrinth_projects(dep_id, mapping)
        if not projects:
            continue
        # optional client only mods (e.g. Mod Menu) are not loaded on a server, so they are not installed
        project, version, note = resolve_dependency(dep_id, alternatives, projects, args.loader, args.mc_version,
                                                    mode, args.properties, server_only=kind == "optional")
        if project is None:
            if kind == "required":
                raise Failure(f"required dependency {dep_id} ({range_text(alternatives)}) is not available: {version}. "
                              "If the mod has another name on Modrinth, add it to server-starttest-mods.txt of "
                              "cech12/MinecraftModActions.")
            skipped.append((dep_id, version))
            continue
        if project in seen_projects:
            continue
        seen_projects.add(project)
        mods.append((kind, dep_id, project, version["id"], version["version_number"], range_text(alternatives), note))
    # optional dependencies that are installed (only counted with --integrations)
    optional_count = sum(1 for mod in mods if mod[0] == "optional")
    return loader_version, range_text(loader_range), optional_count, mods, skipped


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--jar", required=True)
    parser.add_argument("--loader", required=True, choices=["fabric", "forge", "neoforge"])
    parser.add_argument("--mod-id", required=True)
    parser.add_argument("--mc-version", required=True)
    parser.add_argument("--properties", required=True, help="gradle.properties of the mod")
    parser.add_argument("--build-loader-version", default="")
    parser.add_argument("--loader-version", default="", help="use this loader version")
    parser.add_argument("--mapping", required=True, help="server-starttest-mods.txt")
    parser.add_argument("--versions", default="build", choices=["build", "minimum", "newest"])
    parser.add_argument("--integrations", action="store_true", help="also resolve the optional dependencies")
    args = parser.parse_args()
    properties = {}
    with open(args.properties, encoding="utf-8") as file:
        for line in file:
            if "=" in line and not line.lstrip().startswith("#"):
                key, value = line.split("=", 1)
                properties[key.strip()] = value.strip()
    args.properties = properties
    try:
        loader_version, loader_range, optional_count, mods, skipped = resolve(args, args.versions)
        same_as_build = False
        if args.versions == "minimum":
            build = resolve(args, "build")
            same_as_build = build[0] == loader_version and [m[3] for m in build[3]] == [m[3] for m in mods]
    except Failure as e:
        print(e, file=sys.stderr)
        return 1
    except (KeyError, zipfile.BadZipFile, ValueError, tomllib.TOMLDecodeError) as e:
        print(f"the metadata of {args.jar} cannot be read: {e!r}", file=sys.stderr)
        return 2
    print(f"LOADER_VERSION\t{loader_version}\t{loader_range}")
    print(f"BUILD_LOADER_VERSION\t{args.build_loader_version}")
    print(f"OPTIONAL_COUNT\t{optional_count}")
    if same_as_build:
        print("SAME_AS_BUILD")
    for mod in mods:
        print("MOD\t" + "\t".join(mod))
    for dep_id, reason in skipped:
        print(f"SKIPPED\t{dep_id}\t{reason}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
