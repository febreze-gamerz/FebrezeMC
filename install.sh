#!/usr/bin/env bash
# FebrezeMC 2.0.0 - Minecraft server installer for Linux.
# Package-manager families: APT (Debian/Ubuntu), DNF/YUM (Fedora/RHEL/Rocky/Alma),
# Zypper (openSUSE), Pacman (Arch/Manjaro).
# Java is chosen from Mojang's per-version javaVersion metadata. Existing OpenJDK and
# Oracle runtimes are detected and reused. System-wide Java defaults are never changed.
#
# FEBREZEMC_DRY_RUN=1 runs prompts and read-only checks only: it installs nothing,
# downloads no server files, creates no users and starts nothing.
set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C

FEBREZE_VERSION="2.0.0"
BASE_DIR="/opt/febrezemc/servers"
MC_USER="febrezemc"
MC_HOME="/var/lib/febrezemc"
USER_AGENT="FebrezeMC/${FEBREZE_VERSION} (https://github.com/febreze-gamerz/FebrezeMC)"
MANIFEST_URL="https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
DEFAULT_PORT=25565
RESERVED_RAM_MB=1536
DRY_RUN="${FEBREZEMC_DRY_RUN:-0}"

# Global state (initialised here so set -u is always safe)
INSTALL_COMPLETE=0
SERVER_DIR=""
SERVER_CREATED=0
SELECTED_JAVA_HOME=""
JAVA_BIN=""
SELECTED_INDEX=-1
LAUNCH_MODE="jar"
LAUNCH_TARGET="server.jar"
declare -a CAND_PATH=() CAND_MAJOR=() CAND_VENDOR=() CAND_VERSION=() CAND_JDK=()
PROBE_MAJOR=""; PROBE_VERSION=""; PROBE_VENDOR=""; PROBE_JDK=0

BLUE='\033[0;34m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; RED='\033[0;31m'; RESET='\033[0m'

info(){    printf '%b[INFO]%b %s\n'  "$CYAN"   "$RESET" "$*"; }
success(){ printf '%b[OK]%b %s\n'    "$GREEN"  "$RESET" "$*"; }
warn(){    printf '%b[WARN]%b %s\n'  "$YELLOW" "$RESET" "$*"; }
error(){   printf '%b[ERROR]%b %s\n' "$RED"    "$RESET" "$*" >&2; }
line(){    printf '%b%s%b\n' "$BLUE" "────────────────────────────────────────────────────────────────" "$RESET"; }
fail(){    error "$*"; exit 1; }

ask(){
    local prompt="$1" __var="$2" value
    if ! read -r -p "$prompt" value; then
        fail "No input received. Run the installer from an interactive terminal."
    fi
    value="${value//[[:space:]]/}"
    printf -v "$__var" '%s' "$value"
}

need(){ command -v "$1" >/dev/null 2>&1; }

fetch_json(){
    curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 \
        -H "User-Agent: ${USER_AGENT}" "$1"
}

fetch_text(){
    local body=""
    body="$(fetch_json "$1")" || return 1
    awk '{print $1; exit}' <<< "$body"
}

download_file(){
    local url="$1" dest="$2"
    if ! curl -fL --proto '=https' --tlsv1.2 --connect-timeout 20 --retry 3 --retry-delay 3 \
            -H "User-Agent: ${USER_AGENT}" -o "${dest}.part" "$url"; then
        rm -f -- "${dest}.part"
        return 1
    fi
    mv -f -- "${dest}.part" "$dest"
}

verify_zip(){
    if ! unzip -tqq "$1" >/dev/null 2>&1; then
        rm -f -- "$1"
        fail "$(basename -- "$1") is not a valid JAR/ZIP archive. The download was discarded."
    fi
}

verify_sha(){
    local algo="$1" file="$2" expected="${3,,}" actual=""
    case "$algo" in
        sha1)   actual="$(sha1sum -- "$file" | awk '{print $1}')" ;;
        sha256) actual="$(sha256sum -- "$file" | awk '{print $1}')" ;;
        *) fail "Internal error: unknown checksum algorithm: $algo" ;;
    esac
    if [[ "$actual" != "$expected" ]]; then
        rm -f -- "$file"
        fail "$algo checksum mismatch for $(basename -- "$file"). The download was discarded."
    fi
    success "$algo checksum verified for $(basename -- "$file")."
}

cleanup(){
    local rc=$?
    if (( INSTALL_COMPLETE == 0 && SERVER_CREATED == 1 )) \
        && [[ -n "$SERVER_DIR" && -d "$SERVER_DIR" && "$SERVER_DIR" == "$BASE_DIR"/* ]]; then
        warn "Setup did not finish. Removing the folder created by this run: $SERVER_DIR"
        rm -rf -- "$SERVER_DIR"
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ $EUID -eq 0 ]] || fail "Run as root: sudo bash install.sh"
[[ -r /etc/os-release ]] || fail "Cannot identify this Linux distribution (/etc/os-release missing)."
[[ "$DRY_RUN" == "0" || "$DRY_RUN" == "1" ]] || fail "FEBREZEMC_DRY_RUN must be 0 or 1."

# Read os-release in subshells so its VERSION variable cannot overwrite ours.
OS_ID="$(. /etc/os-release; printf '%s' "${ID:-unknown}")"
OS_LIKE="$(. /etc/os-release; printf '%s' "${ID_LIKE:-}")"
OS_NAME="$(. /etc/os-release; printf '%s' "${PRETTY_NAME:-$OS_ID}")"

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|aarch64|arm64) ;;
    *) fail "Unsupported CPU architecture: $ARCH (supported: x86_64, aarch64/arm64)." ;;
esac

case "$OS_ID $OS_LIKE" in
    *alpine*) fail "Alpine Linux is not supported yet (musl compatibility needs separate testing)." ;;
esac

# Detect the package manager actually present. Never guess one.
if need apt-get; then PM="apt"
elif need dnf; then PM="dnf"
elif need yum; then PM="yum"
elif need zypper; then PM="zypper"
elif need pacman; then PM="pacman"
else fail "Unsupported package manager. Supported: APT, DNF/YUM, Zypper and Pacman."
fi

free_mb_at(){
    local p="$1"
    while [[ ! -e "$p" ]]; do p="$(dirname -- "$p")"; done
    df -Pm "$p" | awk 'NR==2 {print $4}'
}

pm_install(){
    case "$PM" in
        apt)    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get install -y "$@" ;;
        dnf)    dnf install -y "$@" ;;
        yum)    yum install -y "$@" ;;
        zypper) zypper --non-interactive install --no-recommends "$@" ;;
        pacman) pacman -S --noconfirm --needed "$@" ;;
    esac
}

install_base_packages(){
    if (( DRY_RUN == 1 )); then
        info "DRY RUN: skipping package installation."
    else
        case "$PM" in
            apt)
                DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get update
                pm_install curl jq screen unzip procps iproute2 ca-certificates git
                ;;
            dnf|yum)
                pm_install curl jq screen unzip procps-ng iproute ca-certificates git
                ;;
            zypper)
                zypper --non-interactive refresh
                pm_install curl jq screen unzip procps iproute2 ca-certificates git
                ;;
            pacman)
                warn "Pacman: using a full system sync (-Syu). Partial upgrades are unsupported on Arch."
                pacman -Syu --noconfirm --needed curl jq screen unzip procps-ng iproute2 ca-certificates git
                ;;
        esac
    fi
    local cmd required=(curl jq)
    if (( DRY_RUN == 0 )); then
        required+=(screen unzip ss runuser sha1sum sha256sum)
    fi
    for cmd in "${required[@]}"; do
        need "$cmd" || fail "Required command is missing: $cmd"
    done
}

# ---------------------------------------------------------------------------
# Java discovery and selection
# ---------------------------------------------------------------------------

java_pkg_names(){
    local major="$1" kind="$2" v suffix
    case "$PM" in
        apt)
            printf 'openjdk-%s-%s-headless\n' "$major" "$kind"
            ;;
        dnf|yum|zypper)
            suffix="headless"
            if [[ "$kind" == "jdk" ]]; then suffix="devel"; fi
            v="$major"
            if (( major == 8 )); then
                if [[ "$PM" == "zypper" ]]; then v="1_8_0"; else v="1.8.0"; fi
            fi
            printf 'java-%s-openjdk-%s\n' "$v" "$suffix"
            ;;
        pacman)
            if [[ "$kind" == "jdk" ]]; then
                printf 'jdk%s-openjdk\n' "$major"
            else
                printf 'jre%s-openjdk-headless\n' "$major"
            fi
            ;;
    esac
}

alt_tool(){
    if need update-alternatives; then echo update-alternatives
    elif need alternatives; then echo alternatives
    fi
}

java_alternative_target(){
    local tool out=""
    tool="$(alt_tool)"
    if [[ -z "$tool" ]]; then return 0; fi
    out="$("$tool" --display java 2>/dev/null || true)"
    awk -F'link currently points to ' 'NF > 1 {print $2; exit}' <<< "$out"
}

install_java_runtime(){
    local major="$1" kind="$2" pkg="" before="" after="" tool="" ok=0
    tool="$(alt_tool)"
    before="$(java_alternative_target)"
    while IFS= read -r pkg; do
        [[ -n "$pkg" ]] || continue
        info "Trying package: $pkg"
        if pm_install "$pkg"; then
            ok=1
            break
        fi
    done < <(java_pkg_names "$major" "$kind")
    (( ok == 1 )) || return 1

    after="$(java_alternative_target)"
    if [[ -n "$tool" && -n "$before" && "$after" != "$before" ]]; then
        warn "The package installation changed the system Java default. Restoring it to: $before"
        if ! "$tool" --set java "$before" >/dev/null 2>&1; then
            fail "Could not restore the system Java default to $before. Restore it manually with: $tool --set java $before"
        fi
    fi
    if [[ -n "$tool" && -z "$before" && -n "$after" ]]; then
        warn "No system Java default existed before; the package created one: $after"
    fi
    return 0
}

# Sets PROBE_* on success; returns non-zero if the binary does not report a Java version.
probe_java(){
    local bin="$1" out="" spec="" full="" vendor="" major="" jdk=0
    out="$("$bin" -XshowSettings:properties -version 2>&1)" || return 1
    spec="$(awk -F' = ' '/java\.specification\.version =/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' <<< "$out")"
    full="$(awk -F' = ' '/java\.version =/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' <<< "$out")"
    vendor="$(awk -F' = ' '/java\.vendor =/ {sub(/^[[:space:]]+/, "", $2); sub(/[[:space:]]+$/, "", $2); print $2; exit}' <<< "$out")"
    major="$spec"
    if [[ "$major" == 1.* ]]; then major="${major#1.}"; fi
    if [[ ! "$major" =~ ^[0-9]+$ ]]; then return 1; fi
    if [[ -x "$(dirname -- "$(dirname -- "$bin")")/bin/javac" ]]; then jdk=1; fi
    PROBE_MAJOR="$major"
    PROBE_VERSION="${full:-unknown}"
    PROBE_VENDOR="${vendor:-unknown}"
    PROBE_JDK="$jdk"
}

discover_java(){
    local p="" real="" s="" already=0
    local -a probes=() found=()
    CAND_PATH=(); CAND_MAJOR=(); CAND_VENDOR=(); CAND_VERSION=(); CAND_JDK=()

    if [[ -n "${JAVA_HOME:-}" ]]; then probes+=("$JAVA_HOME/bin/java"); fi
    if p="$(command -v java 2>/dev/null)"; then probes+=("$p"); fi
    probes+=(/usr/lib/jvm/*/bin/java /usr/java/*/bin/java /opt/*/bin/java /opt/*/*/bin/java /usr/local/*/bin/java)

    for p in "${probes[@]}"; do
        [[ -f "$p" && -x "$p" ]] || continue
        real="$(readlink -f -- "$p")" || continue
        already=0
        if (( ${#found[@]} > 0 )); then
            for s in "${found[@]}"; do
                if [[ "$s" == "$real" ]]; then already=1; fi
            done
        fi
        if (( already == 1 )); then continue; fi
        found+=("$real")
        if probe_java "$real"; then
            CAND_PATH+=("$real")
            CAND_MAJOR+=("$PROBE_MAJOR")
            CAND_VENDOR+=("$PROBE_VENDOR")
            CAND_VERSION+=("$PROBE_VERSION")
            CAND_JDK+=("$PROBE_JDK")
        else
            warn "Ignoring $real: it did not report a Java version."
        fi
    done
}

print_java_candidates(){
    local i kind_text
    if (( ${#CAND_PATH[@]} == 0 )); then
        info "No Java runtime was detected on this system."
        return 0
    fi
    info "Detected Java runtimes:"
    for i in "${!CAND_PATH[@]}"; do
        kind_text="JRE"
        if [[ "${CAND_JDK[$i]}" == "1" ]]; then kind_text="JDK"; fi
        printf '        Java %-3s %-4s %-14s %s  (%s)\n' \
            "${CAND_MAJOR[$i]}" "$kind_text" "${CAND_VERSION[$i]}" "${CAND_PATH[$i]}" "${CAND_VENDOR[$i]}"
    done
}

# Exact major-version match only. A newer or older runtime is never substituted silently.
select_java(){
    local required="$1" need_jdk="$2" i
    SELECTED_INDEX=-1
    if (( ${#CAND_PATH[@]} == 0 )); then return 1; fi
    for i in "${!CAND_PATH[@]}"; do
        if [[ "${CAND_MAJOR[$i]}" != "$required" ]]; then continue; fi
        if (( need_jdk == 1 )) && [[ "${CAND_JDK[$i]}" != "1" ]]; then continue; fi
        SELECTED_INDEX="$i"
        return 0
    done
    return 1
}

# Runs a command as the unprivileged server account with a clean, explicit environment.
run_as_mc(){
    runuser -u "$MC_USER" -- env -i \
        HOME="$MC_HOME" \
        PATH="${SELECTED_JAVA_HOME:+${SELECTED_JAVA_HOME}/bin:}/usr/local/bin:/usr/bin:/bin" \
        JAVA_HOME="${SELECTED_JAVA_HOME:-}" \
        LANG=C.UTF-8 \
        TERM=dumb \
        SCREENDIR="$MC_HOME/.screen" \
        GIT_AUTHOR_NAME=FebrezeMC GIT_AUTHOR_EMAIL=febrezemc@localhost \
        GIT_COMMITTER_NAME=FebrezeMC GIT_COMMITTER_EMAIL=febrezemc@localhost \
        "$@"
}

ensure_java(){
    local need_jdk="$1" kind="jre"
    if (( need_jdk == 1 )); then kind="jdk"; fi

    discover_java
    print_java_candidates

    if ! select_java "$REQUIRED_JAVA" "$need_jdk"; then
        if (( DRY_RUN == 1 )); then
            warn "DRY RUN: Java $REQUIRED_JAVA ($kind) is not installed. A real run would install it with $PM."
            JAVA_BIN=""
            return 0
        fi
        info "Java $REQUIRED_JAVA ($kind) is required and not installed. Installing it with $PM..."
        if ! install_java_runtime "$REQUIRED_JAVA" "$kind"; then
            fail "Could not install Java $REQUIRED_JAVA ($kind) with $PM. Install a Java $REQUIRED_JAVA runtime manually (for example, your Oracle JDK under /usr/lib/jvm), then rerun the installer."
        fi
        discover_java
        print_java_candidates
        select_java "$REQUIRED_JAVA" "$need_jdk" \
            || fail "Java $REQUIRED_JAVA was installed but could not be detected. Check the output above."
    fi

    JAVA_BIN="${CAND_PATH[$SELECTED_INDEX]}"
    SELECTED_JAVA_HOME="$(dirname -- "$(dirname -- "$JAVA_BIN")")"
    JAVA_SELECTED_TEXT="Java ${CAND_VERSION[$SELECTED_INDEX]} (${CAND_VENDOR[$SELECTED_INDEX]})"

    if (( DRY_RUN == 1 )); then
        success "DRY RUN: would use $JAVA_BIN ($JAVA_SELECTED_TEXT)."
        return 0
    fi

    # Verify the selected runtime from the server account's point of view.
    if ! run_as_mc "$JAVA_BIN" -version >/dev/null 2>&1; then
        fail "The $MC_USER account cannot run $JAVA_BIN. Check permissions on its parent directories."
    fi
    probe_java "$JAVA_BIN" || fail "The selected Java runtime stopped reporting its version: $JAVA_BIN"
    if [[ "$PROBE_MAJOR" != "$REQUIRED_JAVA" ]]; then
        fail "Verification failed: $JAVA_BIN reports Java $PROBE_MAJOR, but Java $REQUIRED_JAVA is required."
    fi
    success "Using $JAVA_BIN ($JAVA_SELECTED_TEXT)."
}

# ---------------------------------------------------------------------------
# Minecraft metadata, disk, accounts
# ---------------------------------------------------------------------------

resolve_minecraft_version(){
    local manifest="" version_url=""
    manifest="$(fetch_json "$MANIFEST_URL")" \
        || fail "Could not download Mojang's version manifest. Check the VPS internet connection."
    version_url="$(jq -r --arg v "$MC_VERSION" \
        'first(.versions[] | select(.id == $v and .type == "release") | .url) // empty' <<< "$manifest" || true)"
    [[ -n "$version_url" ]] || fail "Minecraft $MC_VERSION is not a release listed by Mojang (snapshots and typos are rejected)."
    VERSION_META="$(fetch_json "$version_url")" || fail "Could not download metadata for Minecraft $MC_VERSION."
    # Older releases without javaVersion metadata all ran on Java 8.
    REQUIRED_JAVA="$(jq -r '.javaVersion.majorVersion // 8' <<< "$VERSION_META" || true)"
    [[ "$REQUIRED_JAVA" =~ ^[0-9]+$ ]] || fail "Unexpected Java requirement in Mojang metadata: '$REQUIRED_JAVA'"
}

required_disk_mb(){
    case "$SOFTWARE" in
        Spigot) echo 8192 ;;
        Forge)  echo 4096 ;;
        *)      echo 2048 ;;
    esac
}

create_service_account(){
    local nologin=""
    if ! id -u "$MC_USER" >/dev/null 2>&1; then
        nologin="$(command -v nologin 2>/dev/null || echo /usr/sbin/nologin)"
        need useradd || fail "useradd is required to create the $MC_USER account."
        useradd --system --create-home --home-dir "$MC_HOME" --shell "$nologin" "$MC_USER"
    fi
    install -d -m 0700 -o "$MC_USER" -g "$MC_USER" "$MC_HOME/.screen"
}

session_exists(){
    local out=""
    out="$(run_as_mc screen -ls 2>/dev/null || true)"
    grep -Fq -- "$1" <<< "$out"
}

# ---------------------------------------------------------------------------
# Server software downloads (each verifies what the publisher provides)
# ---------------------------------------------------------------------------

download_paper(){
    local builds="" url="" sha=""
    builds="$(fetch_json "https://fill.papermc.io/v3/projects/paper/versions/${MC_VERSION}/builds")" \
        || fail "Paper has no build list for $MC_VERSION (unsupported version or API unreachable)."
    url="$(jq -r 'first(.[] | select(.channel == "STABLE") | .downloads["server:default"].url) // empty' <<< "$builds" || true)"
    sha="$(jq -r 'first(.[] | select(.channel == "STABLE") | .downloads["server:default"].checksums.sha256) // empty' <<< "$builds" || true)"
    [[ -n "$url" ]] || fail "No STABLE Paper build is available for $MC_VERSION."
    download_file "$url" "$SERVER_DIR/server.jar" || fail "Paper download failed."
    verify_zip "$SERVER_DIR/server.jar"
    if [[ -n "$sha" ]]; then
        verify_sha sha256 "$SERVER_DIR/server.jar" "$sha"
    else
        warn "Paper did not publish a SHA-256 for this build; only the JAR structure was verified."
    fi
}

download_purpur(){
    download_file "https://api.purpurmc.org/v2/purpur/${MC_VERSION}/latest/download" "$SERVER_DIR/server.jar" \
        || fail "Purpur has no build for $MC_VERSION or its API is unreachable."
    verify_zip "$SERVER_DIR/server.jar"
    warn "Purpur's download endpoint publishes no checksum; only the JAR structure was verified."
}

download_vanilla(){
    local url="" sha=""
    url="$(jq -r '.downloads.server.url // empty' <<< "$VERSION_META" || true)"
    sha="$(jq -r '.downloads.server.sha1 // empty' <<< "$VERSION_META" || true)"
    [[ -n "$url" && -n "$sha" ]] || fail "Mojang lists no server download for $MC_VERSION."
    download_file "$url" "$SERVER_DIR/server.jar" || fail "Vanilla server download failed."
    verify_sha sha1 "$SERVER_DIR/server.jar" "$sha"
    verify_zip "$SERVER_DIR/server.jar"
}

download_fabric(){
    local loaders="" installers="" loader="" installer=""
    loaders="$(fetch_json "https://meta.fabricmc.net/v2/versions/loader/${MC_VERSION}")" \
        || fail "Fabric does not support Minecraft $MC_VERSION, or its API is unreachable."
    loader="$(jq -r 'first(.[] | select(.loader.stable == true) | .loader.version) // empty' <<< "$loaders" || true)"
    [[ -n "$loader" ]] || fail "No stable Fabric loader found for $MC_VERSION."
    installers="$(fetch_json "https://meta.fabricmc.net/v2/versions/installer")" \
        || fail "Fabric installer list is unavailable."
    installer="$(jq -r 'first(.[] | select(.stable == true) | .version) // empty' <<< "$installers" || true)"
    [[ -n "$installer" ]] || fail "No stable Fabric installer found."
    download_file "https://meta.fabricmc.net/v2/versions/loader/${MC_VERSION}/${loader}/${installer}/server/jar" \
        "$SERVER_DIR/server.jar" || fail "Fabric server download failed."
    verify_zip "$SERVER_DIR/server.jar"
    warn "Fabric publishes no checksum for this combined server JAR; only the JAR structure was verified."
}

download_forge(){
    local promos="" build="" full="" url="" sidecar="" installer_path="" legacy=""
    promos="$(fetch_json "https://maven.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json")" \
        || fail "Could not download Forge's promotions list."
    build="$(jq -r --arg rec "${MC_VERSION}-recommended" --arg lat "${MC_VERSION}-latest" \
        '.promos[$rec] // .promos[$lat] // empty' <<< "$promos" || true)"
    [[ -n "$build" ]] || fail "Forge has no recommended or latest build for Minecraft $MC_VERSION."

    full="${MC_VERSION}-${build}"
    url="https://maven.minecraftforge.net/net/minecraftforge/forge/${full}/forge-${full}-installer.jar"
    installer_path="$SERVER_DIR/forge-installer.jar"
    download_file "$url" "$installer_path" || fail "Forge installer download failed."
    verify_zip "$installer_path"
    if sidecar="$(fetch_text "${url}.sha1")" && [[ -n "$sidecar" ]]; then
        verify_sha sha1 "$installer_path" "$sidecar"
    else
        warn "Forge published no SHA-1 checksum for this installer; only the JAR structure was verified."
    fi

    chown -R "$MC_USER:$MC_USER" "$SERVER_DIR"
    info "Running Forge's server installer as $MC_USER (this downloads libraries and can take several minutes)..."
    if ! run_as_mc bash -c 'cd -- "$1" && exec "$2" -jar forge-installer.jar --installServer' _ "$SERVER_DIR" "$JAVA_BIN"; then
        fail "Forge's server installer failed. Review the output above."
    fi
    rm -f -- "$installer_path"

    if [[ -f "$SERVER_DIR/run.sh" ]]; then
        # Forge 1.17+ : launched through run.sh, which reads user_jvm_args.txt.
        chmod 0750 -- "$SERVER_DIR/run.sh"
        LAUNCH_MODE="forge-run"
        LAUNCH_TARGET="run.sh"
        return 0
    fi

    # Forge 1.16 and older: a self-contained jar is produced.
    legacy="$(find "$SERVER_DIR" -maxdepth 1 -type f -name "forge-${full}*.jar" ! -name '*installer*' -print -quit)"
    [[ -n "$legacy" ]] || fail "Forge did not create a recognized server launcher (no run.sh or forge-${full}*.jar)."
    LAUNCH_MODE="jar"
    LAUNCH_TARGET="$(basename -- "$legacy")"
}

download_spigot(){
    local bt="$SERVER_DIR/BuildTools.jar" built="$SERVER_DIR/spigot-${MC_VERSION}.jar"
    warn "Spigot is compiled locally with BuildTools. This can take 10-30+ minutes and needs a JDK, git and several GB of disk."
    download_file "https://hub.spigotmc.org/jenkins/job/BuildTools/lastSuccessfulBuild/artifact/target/BuildTools.jar" "$bt" \
        || fail "Could not download Spigot BuildTools."
    verify_zip "$bt"

    chown -R "$MC_USER:$MC_USER" "$SERVER_DIR"
    if ! run_as_mc bash -c 'cd -- "$1" && exec "$2" -jar BuildTools.jar --rev "$3"' _ "$SERVER_DIR" "$JAVA_BIN" "$MC_VERSION"; then
        fail "Spigot BuildTools failed. See $SERVER_DIR/BuildTools.log.txt for details."
    fi
    [[ -s "$built" ]] || fail "Spigot JAR was not created."
    verify_zip "$built"
    mv -f -- "$built" "$SERVER_DIR/server.jar"
    rm -f -- "$bt"
    LAUNCH_MODE="jar"
    LAUNCH_TARGET="server.jar"
}

# ---------------------------------------------------------------------------
# Server configuration and launcher
# ---------------------------------------------------------------------------

write_server_files(){
    cat > "$SERVER_DIR/eula.txt" <<'EOF'
# Accepted by the server operator through the FebrezeMC installer.
# Minecraft EULA: https://aka.ms/MinecraftEULA
eula=true
EOF

    cat > "$SERVER_DIR/server.properties" <<EOF
online-mode=${ONLINE_MODE}
server-port=${SERVER_PORT}
motd=FebrezeMC Server
enable-command-block=false
enable-rcon=false
spawn-protection=16
max-players=20
view-distance=8
simulation-distance=6
EOF

    if [[ "$LAUNCH_MODE" == "forge-run" ]]; then
        printf '%s\n' "-Xms${RAM_GB}G" "-Xmx${RAM_GB}G" > "$SERVER_DIR/user_jvm_args.txt"
    fi
}

write_start_script(){
    local tmp="$SERVER_DIR/start.sh.tmp"
    {
        printf '#!/usr/bin/env bash\n'
        printf '# Generated by FebrezeMC %s. The Java runtime was verified at install time.\n' "$FEBREZE_VERSION"
        printf 'set -Eeuo pipefail\n'
        printf 'cd -- %q\n' "$SERVER_DIR"
        printf 'JAVA_HOME=%q\n' "$SELECTED_JAVA_HOME"
        printf 'JAVA_BIN=%q\n' "$JAVA_BIN"
        cat <<'EOF'
[[ -x "$JAVA_BIN" ]] || { echo "Java runtime not found or not executable: $JAVA_BIN" >&2; exit 1; }
export JAVA_HOME
export PATH="$JAVA_HOME/bin:/usr/local/bin:/usr/bin:/bin"
EOF
        if [[ "$LAUNCH_MODE" == "forge-run" ]]; then
            printf 'exec bash ./run.sh nogui\n'
        else
            printf 'exec "$JAVA_BIN" -Xms%sG -Xmx%sG -jar %q nogui\n' "$RAM_GB" "$RAM_GB" "$LAUNCH_TARGET"
        fi
    } > "$tmp"
    chmod 0750 -- "$tmp"
    mv -f -- "$tmp" "$SERVER_DIR/start.sh"
}

# ---------------------------------------------------------------------------
# Interactive setup
# ---------------------------------------------------------------------------

echo
line
printf '%b       FEBREZEMC SERVER INSTALLER%b\n' "$CYAN" "$RESET"
printf '%b       Version %s%b\n' "$BLUE" "$FEBREZE_VERSION" "$RESET"
line
echo
if (( DRY_RUN == 1 )); then
    warn "DRY RUN enabled: nothing will be installed, downloaded, created or started."
fi

RAM_TOTAL_MB="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)"
RAM_AVAILABLE_MB="$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo)"
RAM_USED_MB=$(( RAM_TOTAL_MB - RAM_AVAILABLE_MB ))
CPU_CORES="$(nproc)"
DISK_FREE_MB="$(free_mb_at "$BASE_DIR")"

printf '%bVPS information%b\n' "$CYAN" "$RESET"
printf '  Operating system : %s\n  Package manager  : %s\n  Architecture     : %s\n  CPU cores        : %s\n  Total RAM        : %s MB\n  RAM used         : %s MB\n  RAM available    : %s MB\n  Free disk        : %s MB (under %s)\n' \
    "$OS_NAME" "$PM" "$ARCH" "$CPU_CORES" "$RAM_TOTAL_MB" "$RAM_USED_MB" "$RAM_AVAILABLE_MB" "$DISK_FREE_MB" "$BASE_DIR"
echo
warn "This installer creates files only under $BASE_DIR and a dedicated system account named $MC_USER."
warn "It does not change other services, your Discord bot's files, SSH, firewall or network settings."
echo
ask "Continue? [y/N]: " CONTINUE
[[ "$CONTINUE" =~ ^[Yy]$ ]] || fail "Cancelled."

install_base_packages

echo
printf '%bSelect Minecraft server software:%b\n' "$CYAN" "$RESET"
echo "  1) Paper   2) Purpur   3) Vanilla"
echo "  4) Forge   5) Spigot   6) Fabric"
ask "Choose [1-6]: " SOFTWARE_CHOICE
case "$SOFTWARE_CHOICE" in
    1) SOFTWARE="Paper" ;;
    2) SOFTWARE="Purpur" ;;
    3) SOFTWARE="Vanilla" ;;
    4) SOFTWARE="Forge" ;;
    5) SOFTWARE="Spigot" ;;
    6) SOFTWARE="Fabric" ;;
    *) fail "Invalid software selection." ;;
esac

ask "Minecraft version (example: 1.21.11): " MC_VERSION
[[ "$MC_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || fail "Invalid Minecraft version format."
resolve_minecraft_version
info "Minecraft $MC_VERSION requires Java $REQUIRED_JAVA (from Mojang's version metadata)."

ask "Server name (letters, numbers, - or _): " SERVER_NAME_RAW
SERVER_NAME="$(printf '%s' "$SERVER_NAME_RAW" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
SERVER_NAME="${SERVER_NAME#-}"
if (( ${#SERVER_NAME} < 1 || ${#SERVER_NAME} > 40 )); then
    fail "Server name must be 1-40 characters using letters, numbers, - or _."
fi
SERVER_DIR="$BASE_DIR/$SERVER_NAME"
if [[ -e "$SERVER_DIR" || -L "$SERVER_DIR" ]]; then
    fail "That server folder already exists: $SERVER_DIR. Existing servers are never overwritten; choose another name."
fi

MAX_RAM_GB=$(( (RAM_AVAILABLE_MB - RESERVED_RAM_MB) / 1024 ))
(( MAX_RAM_GB >= 1 )) || fail "Only ${RAM_AVAILABLE_MB} MB of RAM is available. Free some memory first."
DEFAULT_RAM=2
if (( DEFAULT_RAM > MAX_RAM_GB )); then DEFAULT_RAM="$MAX_RAM_GB"; fi
echo
printf '%bRAM allocation%b\n' "$CYAN" "$RESET"
echo "Available RAM now: ${RAM_AVAILABLE_MB} MB"
echo "Maximum suggested allocation: ${MAX_RAM_GB} GB (keeps about 1.5 GB free for the OS and other services)."
ask "Server RAM in GB [${DEFAULT_RAM}]: " RAM_GB
RAM_GB="${RAM_GB:-$DEFAULT_RAM}"
[[ "$RAM_GB" =~ ^[0-9]{1,4}$ ]] || fail "RAM must be a whole number."
RAM_GB=$((10#$RAM_GB))
(( RAM_GB >= 1 && RAM_GB <= MAX_RAM_GB )) || fail "Choose between 1 and ${MAX_RAM_GB} GB."

echo
printf '%bAccount authentication%b\n' "$CYAN" "$RESET"
echo "  1) Online mode (recommended; players must own a Minecraft account)"
echo "  2) Offline mode (allows unauthenticated usernames)"
ask "Choose [1/2]: " AUTH_CHOICE
case "$AUTH_CHOICE" in
    1) ONLINE_MODE="true" ;;
    2)
        ONLINE_MODE="false"
        warn "Offline mode is risky on public servers: players can impersonate other usernames."
        ;;
    *) fail "Choose 1 or 2." ;;
esac

ask "Server port [${DEFAULT_PORT}]: " SERVER_PORT
SERVER_PORT="${SERVER_PORT:-$DEFAULT_PORT}"
[[ "$SERVER_PORT" =~ ^[0-9]{1,5}$ ]] || fail "Port must be a number between 1024 and 65535."
SERVER_PORT=$((10#$SERVER_PORT))
(( SERVER_PORT >= 1024 && SERVER_PORT <= 65535 )) || fail "Port must be between 1024 and 65535."

listeners="$(ss -H -ltn "sport = :${SERVER_PORT}" 2>/dev/null || true)"
if [[ -n "$listeners" ]]; then
    fail "TCP port $SERVER_PORT is already in use. Choose another port."
fi
for props in "$BASE_DIR"/*/server.properties; do
    [[ -f "$props" ]] || continue
    if grep -Eq "^server-port=${SERVER_PORT}[[:space:]]*$" "$props"; then
        fail "Port $SERVER_PORT is already configured for another FebrezeMC server: $props"
    fi
done

echo
warn "Minecraft's EULA must be accepted before the server can run."
echo "Read: https://aka.ms/MinecraftEULA"
ask "Do you agree to the EULA? [y/N]: " EULA_CHOICE
[[ "$EULA_CHOICE" =~ ^[Yy]$ ]] || fail "EULA not accepted; cancelled."

case "$SOFTWARE" in
    Spigot) NEED_JDK=1 ;;
    *)      NEED_JDK=0 ;;
esac

NEED_DISK_MB="$(required_disk_mb)"
AVAIL_DISK_MB="$(free_mb_at "$BASE_DIR")"
if (( AVAIL_DISK_MB < NEED_DISK_MB )); then
    fail "Not enough free disk space: ${AVAIL_DISK_MB} MB available, about ${NEED_DISK_MB} MB needed for $SOFTWARE."
fi

if (( DRY_RUN == 0 )); then
    create_service_account
fi
ensure_java "$NEED_JDK"

if (( DRY_RUN == 1 )); then
    echo
    line
    success "DRY RUN complete. Nothing was installed, downloaded, created or started."
    printf '  Server       : %s\n  Software     : %s\n  Version      : %s\n  Java         : %s\n  Directory    : %s\n  RAM          : %s GB\n  Online mode  : %s\n  Port         : %s\n' \
        "$SERVER_NAME" "$SOFTWARE" "$MC_VERSION" "${JAVA_BIN:-to be installed (Java $REQUIRED_JAVA)}" \
        "$SERVER_DIR" "$RAM_GB" "$ONLINE_MODE" "$SERVER_PORT"
    line
    exit 0
fi

# ---------------------------------------------------------------------------
# Create the server
# ---------------------------------------------------------------------------

mkdir -p -m 0755 -- "$BASE_DIR"
install -d -m 0750 -o "$MC_USER" -g "$MC_USER" "$SERVER_DIR"
SERVER_CREATED=1

echo
line
printf '%bDownloading/building %s %s...%b\n' "$CYAN" "$SOFTWARE" "$MC_VERSION" "$RESET"
line
case "$SOFTWARE" in
    Paper)   download_paper ;;
    Purpur)  download_purpur ;;
    Vanilla) download_vanilla ;;
    Forge)   download_forge ;;
    Spigot)  download_spigot ;;
    Fabric)  download_fabric ;;
esac

[[ -s "$SERVER_DIR/$LAUNCH_TARGET" ]] || fail "Server launcher is missing after installation: $LAUNCH_TARGET"

write_server_files
write_start_script
chown -R "$MC_USER:$MC_USER" "$SERVER_DIR"
chmod 0750 -- "$SERVER_DIR/start.sh"

SESSION_NAME="febrezemc-${SERVER_NAME}"
if session_exists "$SESSION_NAME"; then
    fail "A screen session named $SESSION_NAME already exists. Stop it or choose another server name."
fi

info "Starting server as the unprivileged '$MC_USER' account..."
if ! run_as_mc screen -dmS "$SESSION_NAME" "$SERVER_DIR/start.sh"; then
    fail "Could not start the server screen session."
fi

sleep 5
if ! session_exists "$SESSION_NAME"; then
    fail "The server exited shortly after launch. Run $SERVER_DIR/start.sh manually as $MC_USER to see the error."
fi

INSTALL_COMPLETE=1

CONSOLE_CMD="sudo -u ${MC_USER} -H env SCREENDIR=${MC_HOME}/.screen screen -r ${SESSION_NAME}"
START_CMD="sudo -u ${MC_USER} -H env SCREENDIR=${MC_HOME}/.screen screen -dmS ${SESSION_NAME} ${SERVER_DIR}/start.sh"

echo
line
printf '%b       FEBREZEMC SETUP COMPLETE!%b\n' "$GREEN" "$RESET"
line
printf '  Server       : %s\n  Software     : %s\n  Version      : %s\n  Java         : %s (%s)\n  RAM          : %s GB\n  Online mode  : %s\n  Port         : %s\n  Directory    : %s\n  Run as user  : %s\n' \
    "$SERVER_NAME" "$SOFTWARE" "$MC_VERSION" "$REQUIRED_JAVA" "$JAVA_BIN" "$RAM_GB" "$ONLINE_MODE" "$SERVER_PORT" "$SERVER_DIR" "$MC_USER"
echo
echo "  Connect to: <your VPS public IP>:${SERVER_PORT}"
echo
echo "  Console (detach with Ctrl+A, then D):"
echo "    ${CONSOLE_CMD}"
echo "  Stop: type 'stop' in the console."
echo "  Start again:"
echo "    ${START_CMD}"
echo
warn "Offline mode is not recommended for public servers. Use a trusted authentication setup."
line
success "Thank you for using FebrezeMC!"
