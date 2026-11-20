#!/usr/bin/env bash
# FebrezeMC 2.1.0 - Minecraft server installer
# Installs into the current working directory (VPS or Pterodactyl).
# Pterodactyl startup command: bash ./start.sh
set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C

FEBREZE_VERSION="2.1.0"
USER_AGENT="FebrezeMC/${FEBREZE_VERSION} (https://github.com/febreze-gamerz/FebrezeMC)"
MANIFEST_URL="https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
DEFAULT_PORT=25565
RESERVED_RAM_MB=1024
DRY_RUN="${FEBREZEMC_DRY_RUN:-0}"

SERVER_DIR="$(pwd -P)"
IS_PTERODACTYL=0
SOFTWARE=""
MC_VERSION=""
SERVER_NAME=""
PANEL_PORT="${SERVER_PORT:-}"
SERVER_PORT=""
RAM_GB=""
ONLINE_MODE=true
REQUIRED_JAVA=""
JAVA_BIN=""
JAVA_HOME_SELECTED=""
LAUNCH_MODE="jar"
LAUNCH_TARGET="server.jar"
VERSION_META=""
SERVER_CREATED=0
INSTALL_COMPLETE=0

BLUE='\033[0;34m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; RED='\033[0;31m'; RESET='\033[0m'
info(){ printf '%b[INFO]%b %s\n' "$CYAN" "$RESET" "$*"; }
success(){ printf '%b[OK]%b %s\n' "$GREEN" "$RESET" "$*"; }
warn(){ printf '%b[WARN]%b %s\n' "$YELLOW" "$RESET" "$*"; }
error(){ printf '%b[ERROR]%b %s\n' "$RED" "$RESET" "$*" >&2; }
line(){ printf '%b%s%b\n' "$BLUE" "────────────────────────────────────────────────────────────────" "$RESET"; }
fail(){ error "$*"; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1; }

ask(){
    local prompt="$1" var="$2" value=""
    read -r -p "$prompt" value || fail "No input received. Run this installer in an interactive terminal."
    printf -v "$var" '%s' "$value"
}

fetch_json(){
    curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 \
        --connect-timeout 20 -H "User-Agent: ${USER_AGENT}" "$1"
}
download_file(){
    local url="$1" dest="$2"
    curl -fL --proto '=https' --tlsv1.2 --connect-timeout 20 --retry 3 --retry-delay 3 \
        -H "User-Agent: ${USER_AGENT}" -o "${dest}.part" "$url" \
        || { rm -f -- "${dest}.part"; return 1; }
    mv -f -- "${dest}.part" "$dest"
}
verify_zip(){
    unzip -tqq "$1" >/dev/null 2>&1 || fail "$(basename "$1") is not a valid JAR/ZIP archive."
}
verify_sha(){
    local algo="$1" file="$2" expected="${3,,}" actual=""
    case "$algo" in
        sha1) actual="$(sha1sum -- "$file" | awk '{print $1}')" ;;
        sha256) actual="$(sha256sum -- "$file" | awk '{print $1}')" ;;
        *) fail "Internal checksum type: $algo" ;;
    esac
    [[ "$actual" == "$expected" ]] || fail "$algo checksum verification failed for $(basename "$file")."
    success "$algo checksum verified."
}
free_mb_at(){
    local p="$1"
    while [[ ! -e "$p" ]]; do p="$(dirname -- "$p")"; done
    df -Pm "$p" | awk 'NR==2 {print $4}'
}

cleanup(){
    local rc=$?
    # Never delete the working directory or pre-existing files on failure.
    if (( SERVER_CREATED == 1 && INSTALL_COMPLETE == 0 )); then
        warn "Installation did not finish. Any files created by this run have been left in place for inspection."
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ "$DRY_RUN" == "0" || "$DRY_RUN" == "1" ]] || fail "FEBREZEMC_DRY_RUN must be 0 or 1."
[[ -r /etc/os-release ]] || fail "Cannot identify this Linux distribution."
OS_ID="$(. /etc/os-release; printf '%s' "${ID:-unknown}")"
OS_LIKE="$(. /etc/os-release; printf '%s' "${ID_LIKE:-}")"
OS_NAME="$(. /etc/os-release; printf '%s' "${PRETTY_NAME:-$OS_ID}")"
ARCH="$(uname -m)"
case "$ARCH" in x86_64|aarch64|arm64) ;; *) fail "Unsupported CPU architecture: $ARCH." ;; esac
case "$OS_ID $OS_LIKE" in *alpine*) fail "Alpine Linux is not supported yet." ;; esac

# Pterodactyl Wings commonly supplies these variables to the container.
if [[ "${PTERODACTYL:-}" == "1" || -n "${P_SERVER_UUID:-}" ||
      ( -n "${SERVER_UUID:-}" && -n "${SERVER_MEMORY:-}" ) ]]; then
    IS_PTERODACTYL=1
fi

# Require tools that the installer actually uses. Do not install packages in containers
# or for ordinary users. A root VPS operator can install missing packages separately.
for cmd in bash curl jq unzip awk sed grep find df free nproc readlink; do
    need "$cmd" || fail "Required command '$cmd' is missing. Install it first, then rerun FebrezeMC."
done
for cmd in sha1sum sha256sum; do need "$cmd" || fail "Required command '$cmd' is missing."; done
if (( IS_PTERODACTYL == 0 )); then need ss || warn "The 'ss' command is unavailable; port-use checking will be skipped."; fi

# Work out memory visible to this process. SERVER_MEMORY is Pterodactyl's MB limit.
if (( IS_PTERODACTYL == 1 )) && [[ "${SERVER_MEMORY:-}" =~ ^[0-9]+$ ]] && (( SERVER_MEMORY > 0 )); then
    RAM_TOTAL_MB="$SERVER_MEMORY"
    RAM_AVAILABLE_MB="$SERVER_MEMORY"
else
    RAM_TOTAL_MB="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)"
    RAM_AVAILABLE_MB="$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo)"
fi
CPU_CORES="$(nproc)"
DISK_FREE_MB="$(free_mb_at "$SERVER_DIR")"
MAX_RAM_GB=$(( (RAM_AVAILABLE_MB - RESERVED_RAM_MB) / 1024 ))
(( MAX_RAM_GB >= 1 )) || fail "Not enough memory available for a server allocation of at least 1 GB."
DEFAULT_RAM=2
(( DEFAULT_RAM <= MAX_RAM_GB )) || DEFAULT_RAM="$MAX_RAM_GB"

echo
line
printf '%b       FEBREZEMC SERVER INSTALLER%b\n' "$CYAN" "$RESET"
printf '%b       Version %s%b\n' "$BLUE" "$FEBREZE_VERSION" "$RESET"
line
echo
if (( DRY_RUN == 1 )); then warn "DRY RUN: no files will be downloaded or created."; fi
if (( IS_PTERODACTYL == 1 )); then
    < /dev/null
    info "Environment: Pterodactyl container"
else
    info "Environment: normal Linux"
fi
printf '  Operating system : %s\n  Architecture     : %s\n  CPU cores        : %s\n  Memory limit     : %s MB\n  Memory available : %s MB\n  Free disk        : %s MB\n  Install folder   : %s\n' \
    "$OS_NAME" "$ARCH" "$CPU_CORES" "$RAM_TOTAL_MB" "$RAM_AVAILABLE_MB" "$DISK_FREE_MB" "$SERVER_DIR"
echo
if (( IS_PTERODACTYL == 1 )); then
    info "Pterodactyl will manage the Minecraft process. FebrezeMC will not use screen or start a background process."
else
    info "The server will be created here. Start it later with: ./start.sh"
fi
ask "Continue? [y/N]: " CONTINUE
[[ "$CONTINUE" =~ ^[Yy]$ ]] || fail "Cancelled."

echo
printf '%bSelect Minecraft server software:%b\n' "$CYAN" "$RESET"
echo "  1) Paper   2) Purpur   3) Vanilla"
echo "  4) Forge   5) Spigot   6) Fabric"
ask "Choose [1-6]: " SOFTWARE_CHOICE
case "$SOFTWARE_CHOICE" in
    1) SOFTWARE="Paper" ;; 2) SOFTWARE="Purpur" ;; 3) SOFTWARE="Vanilla" ;;
    4) SOFTWARE="Forge" ;; 5) SOFTWARE="Spigot" ;; 6) SOFTWARE="Fabric" ;;
    *) fail "Invalid software selection." ;;
esac

ask "Minecraft version (example: 1.21.11): " MC_VERSION
[[ "$MC_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || fail "Invalid Minecraft version format."
info "Checking Mojang version metadata..."
MANIFEST="$(fetch_json "$MANIFEST_URL")" || fail "Could not reach Mojang's version manifest."
VERSION_URL="$(jq -r --arg v "$MC_VERSION" 'first(.versions[] | select(.id == $v and .type == "release") | .url) // empty' <<< "$MANIFEST")"
[[ -n "$VERSION_URL" ]] || fail "Minecraft $MC_VERSION is not a release listed by Mojang."
VERSION_META="$(fetch_json "$VERSION_URL")" || fail "Could not get Minecraft version metadata."
REQUIRED_JAVA="$(jq -r '.javaVersion.majorVersion // 8' <<< "$VERSION_META")"
[[ "$REQUIRED_JAVA" =~ ^[0-9]+$ ]] || fail "Could not read the required Java version."
info "Minecraft $MC_VERSION requires Java $REQUIRED_JAVA."

ask "Server name (letters, numbers, - or _): " SERVER_NAME
SERVER_NAME="$(printf '%s' "$SERVER_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
[[ "$SERVER_NAME" =~ ^[a-z0-9_-]{1,40}$ ]] || fail "Server name must be 1-40 letters, numbers, - or _."
ask "Server RAM in GB [${DEFAULT_RAM}]: " RAM_GB
RAM_GB="${RAM_GB:-$DEFAULT_RAM}"
[[ "$RAM_GB" =~ ^[0-9]{1,3}$ ]] || fail "RAM must be a whole number."
RAM_GB=$((10#$RAM_GB))
(( RAM_GB >= 1 && RAM_GB <= MAX_RAM_GB )) || fail "Choose between 1 and ${MAX_RAM_GB} GB."

echo
printf '%bAccount authentication%b\n' "$CYAN" "$RESET"
echo "  1) Online mode (recommended)"
echo "  2) Offline mode (allows unauthenticated usernames)"
ask "Choose [1/2]: " AUTH_CHOICE
case "$AUTH_CHOICE" in
    1) ONLINE_MODE=true ;;
    2) ONLINE_MODE=false; warn "Offline mode allows username impersonation. It is unsafe for public servers." ;;
    *) fail "Choose 1 or 2." ;;
esac

PORT_DEFAULT="$DEFAULT_PORT"
if (( IS_PTERODACTYL == 1 )) && [[ "$PANEL_PORT" =~ ^[0-9]+$ ]]; then
    PORT_DEFAULT="$PANEL_PORT"
fi
ask "Server port [${PORT_DEFAULT}]: " SERVER_PORT
SERVER_PORT="${SERVER_PORT:-$PORT_DEFAULT}"
[[ "$SERVER_PORT" =~ ^[0-9]{1,5}$ ]] || fail "Port must be a number."
SERVER_PORT=$((10#$SERVER_PORT))
(( SERVER_PORT >= 1 && SERVER_PORT <= 65535 )) || fail "Port must be between 1 and 65535."
if (( IS_PTERODACTYL == 1 )); then
    if [[ "$PANEL_PORT" =~ ^[0-9]+$ && "$SERVER_PORT" != "$PANEL_PORT" ]]; then
        fail "Pterodactyl assigned port $PANEL_PORT. Use that allocated port."
    fi
    info "Using the port allocated to this Pterodactyl server."
elif need ss && ss -H -ltn "sport = :${SERVER_PORT}" 2>/dev/null | grep -q .; then
    fail "TCP port $SERVER_PORT is already in use. Choose another port."
fi

echo
warn "You must agree to the Minecraft EULA before running the server."
echo "Read: https://aka.ms/MinecraftEULA"
ask "Do you agree to the EULA? [y/N]: " EULA_CHOICE
[[ "$EULA_CHOICE" =~ ^[Yy]$ ]] || fail "EULA not accepted; cancelled."

# Never overwrite existing files in the working directory.
for target in server.jar start.sh eula.txt server.properties forge-installer.jar BuildTools.jar run.sh user_jvm_args.txt libraries world; do
    [[ ! -e "$SERVER_DIR/$target" && ! -L "$SERVER_DIR/$target" ]] ||
        fail "$SERVER_DIR/$target already exists. Back it up or use an empty server directory."
done
NEED_DISK_MB=2048
case "$SOFTWARE" in Spigot) NEED_DISK_MB=8192 ;; Forge) NEED_DISK_MB=4096 ;; esac
(( DISK_FREE_MB >= NEED_DISK_MB )) || fail "Not enough free disk space. Need about ${NEED_DISK_MB} MB."

# Find an exact Java major version. Spigot's BuildTools requires a JDK.
NEED_JDK=0
[[ "$SOFTWARE" == "Spigot" ]] && NEED_JDK=1
JAVA_CANDIDATES=()
if [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/java" ]]; then JAVA_CANDIDATES+=("${JAVA_HOME}/bin/java"); fi
if need java; then JAVA_CANDIDATES+=("$(command -v java)"); fi
for p in /usr/lib/jvm/*/bin/java /opt/*/bin/java /usr/local/*/bin/java; do
    [[ -x "$p" ]] && JAVA_CANDIDATES+=("$p")
done
JAVA_FOUND=0
for candidate in "${JAVA_CANDIDATES[@]}"; do
    candidate="$(readlink -f "$candidate")"
    out="$("$candidate" -XshowSettings:properties -version 2>&1 || true)"
    spec="$(awk -F' = ' '/java\.specification\.version =/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' <<< "$out")"
    major="$spec"; [[ "$major" == 1.* ]] && major="${major#1.}"
    [[ "$major" == "$REQUIRED_JAVA" ]] || continue
    if (( NEED_JDK == 1 )); then
        jdk_dir="$(dirname "$(dirname "$candidate")")"
        [[ -x "$jdk_dir/bin/javac" ]] || continue
    fi
    JAVA_BIN="$candidate"
    JAVA_HOME_SELECTED="$(dirname "$(dirname "$candidate")")"
    JAVA_FOUND=1
    break
done
if (( JAVA_FOUND == 0 )); then
    fail "Java $REQUIRED_JAVA is required but was not found (Spigot needs a JDK). Install the matching Java version, then rerun FebrezeMC. This installer will not change system packages or Java defaults."
fi
success "Selected Java $REQUIRED_JAVA: $JAVA_BIN"

if (( DRY_RUN == 1 )); then
    echo
    line
    success "DRY RUN complete. No server files were created."
    printf '  Software    : %s\n  Version     : %s\n  Java        : %s\n  Directory   : %s\n  RAM         : %s GB\n  Online mode : %s\n  Port        : %s\n' \
        "$SOFTWARE" "$MC_VERSION" "$JAVA_BIN" "$SERVER_DIR" "$RAM_GB" "$ONLINE_MODE" "$SERVER_PORT"
    line
    exit 0
fi

SERVER_CREATED=1
cd "$SERVER_DIR"

download_paper(){
    local builds url sha
    builds="$(fetch_json "https://fill.papermc.io/v3/projects/paper/versions/${MC_VERSION}/builds")" || fail "Could not get Paper builds."
    url="$(jq -r 'first(.[] | select(.channel == "STABLE") | .downloads["server:default"].url) // empty' <<< "$builds")"
    sha="$(jq -r 'first(.[] | select(.channel == "STABLE") | .downloads["server:default"].checksums.sha256) // empty' <<< "$builds")"
    [[ -n "$url" ]] || fail "No stable Paper build for $MC_VERSION."
    download_file "$url" server.jar || fail "Paper download failed."
    verify_zip server.jar
    [[ -z "$sha" ]] || verify_sha sha256 server.jar "$sha"
}
download_purpur(){
    download_file "https://api.purpurmc.org/v2/purpur/${MC_VERSION}/latest/download" server.jar || fail "Purpur download failed."
    verify_zip server.jar
}
download_vanilla(){
    local url sha
    url="$(jq -r '.downloads.server.url // empty' <<< "$VERSION_META")"
    sha="$(jq -r '.downloads.server.sha1 // empty' <<< "$VERSION_META")"
    [[ -n "$url" && -n "$sha" ]] || fail "Mojang has no server download for $MC_VERSION."
    download_file "$url" server.jar || fail "Vanilla download failed."
    verify_sha sha1 server.jar "$sha"
    verify_zip server.jar
}
download_fabric(){
    local loaders installers loader installer
    loaders="$(fetch_json "https://meta.fabricmc.net/v2/versions/loader/${MC_VERSION}")" || fail "Fabric API unavailable."
    loader="$(jq -r 'first(.[] | select(.loader.stable == true) | .loader.version) // empty' <<< "$loaders")"
    installers="$(fetch_json "https://meta.fabricmc.net/v2/versions/installer")" || fail "Fabric installer list unavailable."
    installer="$(jq -r 'first(.[] | select(.stable == true) | .version) // empty' <<< "$installers")"
    [[ -n "$loader" && -n "$installer" ]] || fail "No stable Fabric loader/installer for this version."
    download_file "https://meta.fabricmc.net/v2/versions/loader/${MC_VERSION}/${loader}/${installer}/server/jar" server.jar || fail "Fabric download failed."
    verify_zip server.jar
}
download_forge(){
    local promos build full url sidecar legacy
    promos="$(fetch_json "https://maven.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json")" || fail "Forge promotions unavailable."
    build="$(jq -r --arg rec "${MC_VERSION}-recommended" --arg lat "${MC_VERSION}-latest" '.promos[$rec] // .promos[$lat] // empty' <<< "$promos")"
    [[ -n "$build" ]] || fail "Forge has no recommended/latest build for $MC_VERSION."
    full="${MC_VERSION}-${build}"
    url="https://maven.minecraftforge.net/net/minecraftforge/forge/${full}/forge-${full}-installer.jar"
    download_file "$url" forge-installer.jar || fail "Forge installer download failed."
    verify_zip forge-installer.jar
    if sidecar="$(curl -fsSL "${url}.sha1" 2>/dev/null | awk '{print $1}' || true)" && [[ -n "$sidecar" ]]; then
        verify_sha sha1 forge-installer.jar "$sidecar"
    else
        warn "Forge did not provide a SHA-1 checksum."
    fi
    info "Running Forge installer. This may take several minutes..."
    "$JAVA_BIN" -jar forge-installer.jar --installServer || fail "Forge server installation failed."
    rm -f forge-installer.jar
    if [[ -f run.sh ]]; then
        LAUNCH_MODE="forge-run"; LAUNCH_TARGET="run.sh"
        chmod 0755 run.sh
    else
        legacy="$(find . -maxdepth 1 -type f -name "forge-${full}*.jar" ! -name '*installer*' -print -quit)"
        [[ -n "$legacy" ]] || fail "Forge did not create run.sh or a legacy server JAR."
        LAUNCH_TARGET="${legacy#./}"
    fi
}
download_spigot(){
    local built="spigot-${MC_VERSION}.jar"
    warn "Spigot BuildTools can take 10-30+ minutes and needs several GB of disk."
    download_file "https://hub.spigotmc.org/jenkins/job/BuildTools/lastSuccessfulBuild/artifact/target/BuildTools.jar" BuildTools.jar || fail "Could not download BuildTools."
    verify_zip BuildTools.jar
    "$JAVA_BIN" -jar BuildTools.jar --rev "$MC_VERSION" || fail "Spigot BuildTools failed. See BuildTools.log.txt."
    [[ -s "$built" ]] || fail "Spigot JAR was not created."
    verify_zip "$built"
    mv "$built" server.jar
    rm -f BuildTools.jar
}

echo
line
printf '%bInstalling %s %s...%b\n' "$CYAN" "$SOFTWARE" "$MC_VERSION" "$RESET"
line
case "$SOFTWARE" in
    Paper) download_paper ;;
    Purpur) download_purpur ;;
    Vanilla) download_vanilla ;;
    Forge) download_forge ;;
    Spigot) download_spigot ;;
    Fabric) download_fabric ;;
esac
[[ -s "$LAUNCH_TARGET" ]] || fail "Server launcher was not created: $LAUNCH_TARGET"

cat > eula.txt <<'EOF'
# Accepted by the server operator through the FebrezeMC installer.
# Minecraft EULA: https://aka.ms/MinecraftEULA
eula=true
EOF
cat > server.properties <<EOF
online-mode=${ONLINE_MODE}
server-port=${SERVER_PORT}
motd=${SERVER_NAME}
enable-command-block=false
enable-rcon=false
spawn-protection=16
max-players=20
view-distance=8
simulation-distance=6
EOF
if [[ "$LAUNCH_MODE" == "forge-run" ]]; then
    printf '%s\n' "-Xms${RAM_GB}G" "-Xmx${RAM_GB}G" > user_jvm_args.txt
fi

{
    printf '#!/usr/bin/env bash\n'
    printf '# Generated by FebrezeMC %s\n' "$FEBREZE_VERSION"
    printf 'set -Eeuo pipefail\n'
    printf 'cd -- %q\n' "$SERVER_DIR"
    printf 'JAVA_HOME=%q\n' "$JAVA_HOME_SELECTED"
    printf 'JAVA_BIN=%q\n' "$JAVA_BIN"
    cat <<'EOF'
export JAVA_HOME
export PATH="$JAVA_HOME/bin:/usr/local/bin:/usr/bin:/bin"
[[ -x "$JAVA_BIN" ]] || { echo "Java not found: $JAVA_BIN" >&2; exit 1; }
EOF
    if [[ "$LAUNCH_MODE" == "forge-run" ]]; then
        printf 'exec bash ./run.sh nogui\n'
    else
        printf 'exec "$JAVA_BIN" -Xms%sG -Xmx%sG -jar %q nogui\n' "$RAM_GB" "$RAM_GB" "$LAUNCH_TARGET"
    fi
} > start.sh.tmp
chmod 0755 start.sh.tmp
mv start.sh.tmp start.sh
chmod 0644 eula.txt server.properties

INSTALL_COMPLETE=1
echo
line
printf '%b       FEBREZEMC SETUP COMPLETE!%b\n' "$GREEN" "$RESET"
line
printf '  Environment : %s\n  Software    : %s\n  Version     : %s\n  Java        : %s\n  RAM         : %s GB\n  Online mode : %s\n  Port        : %s\n  Directory   : %s\n' \
    "$([[ "$IS_PTERODACTYL" == 1 ]] && echo Pterodactyl || echo Linux)" "$SOFTWARE" "$MC_VERSION" "$JAVA_BIN" "$RAM_GB" "$ONLINE_MODE" "$SERVER_PORT" "$SERVER_DIR"
echo
if (( IS_PTERODACTYL == 1 )); then
    success "Files are ready. Set the Pterodactyl Startup Command to: bash ./start.sh"
    info "The panel will manage the server process. Do not run start.sh from the installer."
else
    success "Files are ready. Start the server with: ./start.sh"
    info "The server runs in the foreground. Stop it by typing stop in its console."
fi
warn "Offline mode is not recommended for public servers."
line
success "Thank you for using FebrezeMC!"
