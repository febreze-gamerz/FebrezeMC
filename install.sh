
#!/usr/bin/env bash
# FebrezeMC - Minecraft Server Installer
# One-file installer for Ubuntu / Debian

set -Eeuo pipefail

VERSION="1.0.0"
BASE_DIR="/opt/febrezemc/servers"
USER_AGENT="FebrezeMC/${VERSION} (https://github.com/Febreze-Gamerz/FebrezeMC)"

# ---------- COLORS ----------

BLUE='\033[0;34m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
line()    { echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; }

fail() {
    error "$*"
    exit 1
}

# ---------- CHECKS ----------

[[ "$EUID" -eq 0 ]] || fail "Please run this installer as root."

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
else
    fail "Cannot detect your Linux distribution."
fi

case "${ID:-}" in
    ubuntu|debian) ;;
    *) fail "FebrezeMC currently supports Ubuntu and Debian only." ;;
esac

command -v apt-get >/dev/null 2>&1 || fail "APT package manager is required."

echo
line
echo -e "${CYAN}       FEBREZEMC SERVER INSTALLER${RESET}"
echo -e "${BLUE}       Version ${VERSION}${RESET}"
line
echo

# ---------- SERVER INFORMATION ----------

RAM_TOTAL_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
RAM_TOTAL_GB=$((RAM_TOTAL_MB / 1024))
CPU_CORES=$(nproc)
DISK_INFO=$(df -h / | awk 'NR==2 {print $4 " free / " $2 " total"}')
OS_NAME="${PRETTY_NAME:-Linux}"

echo -e "${CYAN}Your VPS information:${RESET}"
echo "  Operating system : $OS_NAME"
echo "  CPU cores        : $CPU_CORES"
echo "  Total RAM        : ${RAM_TOTAL_GB} GB (${RAM_TOTAL_MB} MB)"
echo "  Disk space       : $DISK_INFO"
echo

# Show current RAM usage
RAM_USED_MB=$(free -m | awk '/Mem:/ {print $3}')
RAM_FREE_MB=$(free -m | awk '/Mem:/ {print $7}')

echo "  RAM currently used : ${RAM_USED_MB} MB"
echo "  RAM currently free : ${RAM_FREE_MB} MB"
echo
line

# ---------- DEPENDENCIES ----------

info "Installing required packages..."

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl wget jq git screen ca-certificates unzip

command -v java >/dev/null 2>&1 || {
    info "Java was not found. Installing Java 21..."
    apt-get install -y openjdk-21-jre-headless
}

JAVA_BIN="$(command -v java)"
JAVA_VERSION=$("$JAVA_BIN" -version 2>&1 | head -n 1)

success "Java detected: $JAVA_VERSION"

# ---------- SOFTWARE SELECTION ----------

echo
echo -e "${CYAN}Select your Minecraft server software:${RESET}"
echo
echo "  1) Paper"
echo "  2) Purpur"
echo "  3) Vanilla"
echo "  4) Forge"
echo "  5) Spigot"
echo "  6) Fabric"
echo

read -rp "Choose software [1-6]: " SOFTWARE_CHOICE

case "$SOFTWARE_CHOICE" in
    1) SOFTWARE="Paper" ;;
    2) SOFTWARE="Purpur" ;;
    3) SOFTWARE="Vanilla" ;;
    4) SOFTWARE="Forge" ;;
    5) SOFTWARE="Spigot" ;;
    6) SOFTWARE="Fabric" ;;
    *) fail "Invalid software selection." ;;
esac

echo
success "Selected software: $SOFTWARE"

# ---------- VERSION SELECTION ----------

echo
read -rp "Enter Minecraft version (example: 1.21.11): " MC_VERSION

[[ "$MC_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] ||
    fail "Invalid Minecraft version format."

echo
info "Checking availability of Minecraft $MC_VERSION for $SOFTWARE..."

# ---------- SERVER NAME ----------

echo
read -rp "Enter a name for this server: " SERVER_NAME

SERVER_NAME=$(echo "$SERVER_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')

[[ -n "$SERVER_NAME" ]] || fail "Invalid server name."

SERVER_DIR="$BASE_DIR/$SERVER_NAME"

[[ ! -e "$SERVER_DIR" ]] ||
    fail "A server named '$SERVER_NAME' already exists: $SERVER_DIR"

# ---------- RAM SELECTION ----------

echo
echo -e "${CYAN}RAM allocation${RESET}"
echo "Your VPS has ${RAM_TOTAL_GB} GB total RAM."
echo "Leave some RAM for Ubuntu and other services."
echo

MAX_RAM_GB=$((RAM_TOTAL_GB - 2))
(( MAX_RAM_GB >= 1 )) || MAX_RAM_GB=1

DEFAULT_RAM=2
(( DEFAULT_RAM > MAX_RAM_GB )) && DEFAULT_RAM=$MAX_RAM_GB

read -rp "How many GB of RAM should this server use? [${DEFAULT_RAM}]: " RAM_GB
RAM_GB="${RAM_GB:-$DEFAULT_RAM}"

[[ "$RAM_GB" =~ ^[0-9]+$ ]] || fail "RAM must be a whole number."

(( RAM_GB >= 1 )) || fail "RAM must be at least 1 GB."
(( RAM_GB <= MAX_RAM_GB )) ||
    fail "Choose ${MAX_RAM_GB} GB or less to leave room for the OS and other services."

# ---------- CRACKED MODE ----------

echo
echo -e "${CYAN}Account authentication${RESET}"
echo
echo "  1) Yes - Allow cracked / offline accounts"
echo "  2) No  - Require authenticated Minecraft accounts"
echo

read -rp "Allow cracked accounts? [1/2]: " CRACKED_CHOICE

case "$CRACKED_CHOICE" in
    1) ONLINE_MODE="false" ;;
    2) ONLINE_MODE="true" ;;
    *) fail "Please choose 1 or 2." ;;
esac

# ---------- DOWNLOAD FUNCTIONS ----------

download_paper() {
    local response
    local url

    response=$(curl -fsSL \
        -H "User-Agent: $USER_AGENT" \
        "https://fill.papermc.io/v3/projects/paper/versions/${MC_VERSION}/builds") ||
        fail "Could not contact the Paper downloads API."

    url=$(jq -r '
        first(
            .[]
            | select(.channel == "STABLE")
            | .downloads["server:default"].url
        ) // empty
    ' <<< "$response")

    [[ -n "$url" ]] || fail "No stable Paper build found for $MC_VERSION."

    curl -fL --retry 3 "$url" -o "$SERVER_DIR/server.jar" ||
        fail "Paper download failed."
}

download_purpur() {
    curl -fL --retry 3 \
        "https://api.purpurmc.org/v2/purpur/${MC_VERSION}/latest/download" \
        -o "$SERVER_DIR/server.jar" ||
        fail "Purpur does not have a downloadable build for $MC_VERSION."
}

download_vanilla() {
    local manifest
    local version_url

    manifest=$(curl -fsSL \
        "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json") ||
        fail "Could not retrieve Mojang's version manifest."

    version_url=$(jq -r --arg version "$MC_VERSION" '
        .versions[]
        | select(.id == $version and .type == "release")
        | .url
    ' <<< "$manifest" | head -n 1)

    [[ -n "$version_url" ]] ||
        fail "Minecraft release $MC_VERSION was not found."

    local version_json
    local server_url

    version_json=$(curl -fsSL "$version_url") ||
        fail "Could not retrieve Vanilla version information."

    server_url=$(jq -r '.downloads.server.url // empty' <<< "$version_json")

    [[ -n "$server_url" ]] || fail "No Vanilla server download is available."

    curl -fL --retry 3 "$server_url" -o "$SERVER_DIR/server.jar" ||
        fail "Vanilla download failed."
}

download_fabric() {
    local loaders
    local loader_version
    local installers
    local installer_version

    loaders=$(curl -fsSL \
        "https://meta.fabricmc.net/v2/versions/loader/${MC_VERSION}") ||
        fail "Could not retrieve Fabric loader versions."

    loader_version=$(jq -r '
        first(.[] | select(.loader.stable == true) | .loader.version) // empty
    ' <<< "$loaders")

    [[ -n "$loader_version" ]] || fail "No stable Fabric loader found."

    installers=$(curl -fsSL \
        "https://meta.fabricmc.net/v2/versions/installer") ||
        fail "Could not retrieve Fabric installer versions."

    installer_version=$(jq -r '
        first(.[] | select(.stable == true) | .version) // empty
    ' <<< "$installers")

    [[ -n "$installer_version" ]] || fail "No stable Fabric installer found."

    info "Fabric loader: $loader_version"

    curl -fL --retry 3 \
        "https://meta.fabricmc.net/v2/versions/loader/${MC_VERSION}/${loader_version}/${installer_version}/server/jar" \
        -o "$SERVER_DIR/server.jar" ||
        fail "Fabric server download failed."
}

download_forge() {
    local promotions
    local forge_version

    promotions=$(curl -fsSL \
        "https://maven.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json") ||
        fail "Could not retrieve Forge version information."

    forge_version=$(jq -r --arg version "$MC_VERSION" '
        .promos[($version + "-recommended")]
        // .promos[($version + "-latest")]
        // empty
    ' <<< "$promotions")

    [[ -n "$forge_version" ]] ||
        fail "No recommended/latest Forge build found for $MC_VERSION."

    info "Forge build: $forge_version"

    local forge_installer="forge-${MC_VERSION}-${forge_version}-installer.jar"
    local forge_url="https://maven.minecraftforge.net/net/minecraftforge/forge/${MC_VERSION}-${forge_version}/${forge_installer}"

    curl -fL --retry 3 "$forge_url" -o "$SERVER_DIR/forge-installer.jar" ||
        fail "Forge installer download failed."

    (
        cd "$SERVER_DIR"
        "$JAVA_BIN" -jar forge-installer.jar --installServer
    ) || fail "Forge server installation failed."

    rm -f "$SERVER_DIR/forge-installer.jar"

    local forge_jar
    forge_jar=$(find "$SERVER_DIR" -maxdepth 1 -type f \
        \( -name 'run.sh' -o -name 'forge-*-server.jar' -o -name 'server.jar' \) \
        | head -n 1 || true)

    [[ -n "$forge_jar" ]] ||
        fail "Forge installer completed, but its server launcher was not found."

    if [[ "$(basename "$forge_jar")" == "run.sh" ]]; then
        chmod +x "$forge_jar"
        printf '%s\n' "run.sh" > "$SERVER_DIR/launcher.txt"
    else
        printf '%s\n' "$(basename "$forge_jar")" > "$SERVER_DIR/launcher.txt"
    fi
}

download_spigot() {
    info "Downloading official Spigot BuildTools..."

    curl -fL --retry 3 \
        "https://hub.spigotmc.org/jenkins/job/BuildTools/lastSuccessfulBuild/artifact/target/BuildTools.jar" \
        -o "$SERVER_DIR/BuildTools.jar" ||
        fail "Could not download Spigot BuildTools."

    (
        cd "$SERVER_DIR"
        "$JAVA_BIN" -jar BuildTools.jar --rev "$MC_VERSION"
    ) || fail "Spigot BuildTools could not build this version."

    [[ -f "$SERVER_DIR/spigot-${MC_VERSION}.jar" ]] ||
        fail "Spigot JAR was not created."

    mv "$SERVER_DIR/spigot-${MC_VERSION}.jar" "$SERVER_DIR/server.jar"
    rm -f "$SERVER_DIR/BuildTools.jar"
}

# ---------- BUILD SERVER ----------

echo
line
echo -e "${CYAN}Building your Minecraft server...${RESET}"
line

mkdir -p "$SERVER_DIR"
cd "$SERVER_DIR"

case "$SOFTWARE" in
    Paper)   download_paper ;;
    Purpur)  download_purpur ;;
    Vanilla) download_vanilla ;;
    Forge)   download_forge ;;
    Spigot)  download_spigot ;;
    Fabric)  download_fabric ;;
esac

# ---------- EULA ----------

echo
warn "Minecraft's EULA must be accepted before the server can run."
echo "Read it here: https://aka.ms/MinecraftEULA"
echo

read -rp "Do you agree to the Minecraft EULA? [y/N]: " EULA_CHOICE

[[ "$EULA_CHOICE" =~ ^[Yy]$ ]] ||
    fail "EULA was not accepted. Server setup stopped."

echo "eula=true" > "$SERVER_DIR/eula.txt"

# ---------- SERVER PROPERTIES ----------

cat > "$SERVER_DIR/server.properties" <<EOF
online-mode=${ONLINE_MODE}
server-port=25565
motd=FebrezeMC Server
enable-command-block=false
spawn-protection=16
max-players=20
view-distance=8
simulation-distance=6
EOF

# ---------- STARTUP SCRIPT ----------

if [[ "$SOFTWARE" == "Forge" && -f "$SERVER_DIR/launcher.txt" ]]; then
    FORGE_LAUNCHER=$(cat "$SERVER_DIR/launcher.txt")

    if [[ "$FORGE_LAUNCHER" == "run.sh" ]]; then
        cat > "$SERVER_DIR/start.sh" <<EOF
#!/usr/bin/env bash
cd "$SERVER_DIR"
exec ./run.sh nogui
EOF
    else
        cat > "$SERVER_DIR/start.sh" <<EOF
#!/usr/bin/env bash
cd "$SERVER_DIR"
exec "$JAVA_BIN" -Xms1G -Xmx${RAM_GB}G -jar "$FORGE_LAUNCHER" nogui
EOF
    fi
else
    cat > "$SERVER_DIR/start.sh" <<EOF
#!/usr/bin/env bash
cd "$SERVER_DIR"
exec "$JAVA_BIN" -Xms1G -Xmx${RAM_GB}G -jar server.jar nogui
EOF
fi

chmod +x "$SERVER_DIR/start.sh"

# ---------- START SERVER ----------

SESSION_NAME="febrezemc-${SERVER_NAME}"

echo
info "Starting your server..."

screen -DmS "$SESSION_NAME" "$SERVER_DIR/start.sh" ||
    fail "Could not start the server."

sleep 3

if ! screen -list | grep -Fq "$SESSION_NAME"; then
    warn "The server process may have stopped. Check its logs in $SERVER_DIR."
else
    success "Server started in a screen session."
fi

# ---------- FINISHED ----------

echo
line
echo -e "${GREEN}       FEBREZEMC SETUP COMPLETE!${RESET}"
line
echo
echo "  Server name : $SERVER_NAME"
echo "  Software    : $SOFTWARE"
echo "  Version     : $MC_VERSION"
echo "  RAM         : ${RAM_GB} GB"
echo "  Cracked     : $([[ "$ONLINE_MODE" == "false" ]] && echo Yes || echo No)"
echo "  Directory   : $SERVER_DIR"
echo "  Port        : 25565"
echo
echo "  Connect using:"
echo "  YOUR_VPS_IP:25565"
echo
echo "  Useful commands:"
echo "  Attach console : screen -r $SESSION_NAME"
echo "  Detach console : Ctrl+A, then D"
echo "  Stop server    : type stop in the server console"
echo
line
success "Thank you for using FebrezeMC!"
