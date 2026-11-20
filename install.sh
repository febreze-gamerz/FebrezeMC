#!/usr/bin/env bash
# FebrezeMC - Minecraft Server Installer
# Ubuntu / Debian

set -Eeuo pipefail

FEBREZE_VERSION="1.1.0"
BASE_DIR="/opt/febrezemc/servers"
SERVICE_USER="febrezemc"
BASE_PORT=25565
USER_AGENT="FebrezeMC/${FEBREZE_VERSION} (https://github.com/Febreze-Gamerz/FebrezeMC)"

# ---------- COLORS / HELPERS ----------

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

# Reads from the terminal, so the script also works when piped (curl ... | bash)
ask() {
    local prompt="$1" __var="$2" reply
    [[ -r /dev/tty ]] || fail "No terminal available. Download the script and run it directly."
    read -rp "$prompt" reply </dev/tty
    printf -v "$__var" '%s' "$reply"
}

# Removes a half-built server if the install fails before startup
SERVER_DIR=""
CLEANUP=0
on_exit() {
    local code=$?
    if (( code != 0 && CLEANUP == 1 )) && [[ -n "$SERVER_DIR" && -d "$SERVER_DIR" ]]; then
        warn "Installation failed. Removing incomplete server: $SERVER_DIR"
        rm -rf "$SERVER_DIR"
    fi
}
trap on_exit EXIT

port_listening() {
    ss -ltnH | awk '{print $4}' | grep -Eq "[:.]${1}$"
}

port_in_use() {
    port_listening "$1" && return 0
    grep -Rqs "^server-port=$1$" "$BASE_DIR"/*/server.properties 2>/dev/null && return 0
    return 1
}

find_free_port() {
    local port=$BASE_PORT
    while port_in_use "$port"; do
        port=$((port + 1))
    done
    echo "$port"
}

# Minimum Java for a Minecraft version
required_java_for() {
    local major minor patch
    IFS=. read -r major minor patch <<< "$1"
    minor=${minor:-0}
    patch=${patch:-0}
    if (( minor > 20 || (minor == 20 && patch >= 5) )); then
        echo 21
    elif (( minor >= 17 )); then
        echo 17
    else
        echo 8
    fi
}

ensure_java() {
    local need="$1" bin
    bin=$(ls -d /usr/lib/jvm/java-"$need"-openjdk-*/bin/java 2>/dev/null | head -n 1 || true)

    if [[ -z "$bin" ]]; then
        info "Installing Java $need (JDK)..."
        apt-get install -y "openjdk-${need}-jdk-headless" ||
            fail "Could not install Java $need from apt on this system."
        bin=$(ls -d /usr/lib/jvm/java-"$need"-openjdk-*/bin/java 2>/dev/null | head -n 1 || true)
    fi

    [[ -n "$bin" ]] || fail "Java $need was installed but its binary was not found."
    JAVA_BIN="$bin"
    success "Using Java: $("$JAVA_BIN" -version 2>&1 | head -n 1)"
}

# download <url> <dest> [sha256|sha1 expected_hash]
download() {
    local url="$1" dest="$2" algo="${3:-}" expected="${4:-}"
    curl -fL --retry 3 -o "$dest" "$url" || fail "Download failed: $url"

    if [[ -n "$algo" && -n "$expected" ]]; then
        local actual
        actual=$("${algo}sum" "$dest" | awk '{print $1}')
        [[ "$actual" == "$expected" ]] || fail "Checksum mismatch for $(basename "$dest"). Try again."
        success "Checksum verified."
    else
        warn "No checksum published for this download; skipping verification."
    fi
}

# ---------- CHECKS ----------

[[ "$EUID" -eq 0 ]] || fail "Please run this installer as root (sudo bash install.sh)."
[[ -f /etc/os-release ]] || fail "Cannot detect your Linux distribution."
. /etc/os-release

case "${ID:-}" in
    ubuntu|debian) ;;
    *) fail "FebrezeMC currently supports Ubuntu and Debian only." ;;
esac

command -v apt-get >/dev/null 2>&1 || fail "APT package manager is required."

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
    amd64|arm64) ;;
    *) fail "Unsupported CPU architecture: $ARCH" ;;
esac

echo
line
echo -e "${CYAN}       FEBREZEMC SERVER INSTALLER${RESET}"
echo -e "${BLUE}       Version ${FEBREZE_VERSION}${RESET}"
line
echo

# ---------- SERVER INFORMATION ----------

RAM_TOTAL_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
RAM_TOTAL_GB=$((RAM_TOTAL_MB / 1024))
CPU_CORES=$(nproc)
DISK_INFO=$(df -h / | awk 'NR==2 {print $4 " free / " $2 " total"}')
OS_NAME="${PRETTY_NAME:-Linux}"
RAM_USED_MB=$(free -m | awk '/Mem:/ {print $3}')
RAM_FREE_MB=$(free -m | awk '/Mem:/ {print $7}')

echo -e "${CYAN}Your VPS information:${RESET}"
echo "  Operating system   : $OS_NAME"
echo "  CPU cores          : $CPU_CORES"
echo "  Total RAM          : ${RAM_TOTAL_GB} GB (${RAM_TOTAL_MB} MB)"
echo "  RAM currently used : ${RAM_USED_MB} MB"
echo "  RAM currently free : ${RAM_FREE_MB} MB"
echo "  Disk space         : $DISK_INFO"
echo
line

# ---------- DEPENDENCIES ----------

info "Installing required packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl jq git screen ca-certificates iproute2 coreutils

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

ask "Choose software [1-6]: " SOFTWARE_CHOICE

case "$SOFTWARE_CHOICE" in
    1) SOFTWARE="Paper" ;;
    2) SOFTWARE="Purpur" ;;
    3) SOFTWARE="Vanilla" ;;
    4) SOFTWARE="Forge" ;;
    5) SOFTWARE="Spigot" ;;
    6) SOFTWARE="Fabric" ;;
    *) fail "Invalid software selection." ;;
esac

success "Selected software: $SOFTWARE"

# ---------- VERSION SELECTION ----------

echo
ask "Enter Minecraft version (example: 1.21.11): " MC_VERSION

[[ "$MC_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] ||
    fail "Invalid Minecraft version format."

JAVA_NEEDED="$(required_java_for "$MC_VERSION")"
info "Minecraft $MC_VERSION requires Java $JAVA_NEEDED."

# ---------- SERVER NAME ----------

echo
ask "Enter a name for this server: " SERVER_NAME

SERVER_NAME=$(echo "$SERVER_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')
[[ -n "$SERVER_NAME" ]] || fail "Invalid server name."

SERVER_DIR="$BASE_DIR/$SERVER_NAME"
[[ ! -e "$SERVER_DIR" ]] ||
    fail "A server named '$SERVER_NAME' already exists: $SERVER_DIR"

# ---------- PORT ----------

PORT=$(find_free_port)
info "This server will use port $PORT."

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

ask "How many GB of RAM should this server use? [${DEFAULT_RAM}]: " RAM_GB
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
warn "Cracked mode lets anyone join with any username, including the names of your friends or admins."
echo

ask "Allow cracked accounts? [1/2]: " CRACKED_CHOICE

case "$CRACKED_CHOICE" in
    1) ONLINE_MODE="false" ;;
    2) ONLINE_MODE="true" ;;
    *) fail "Please choose 1 or 2." ;;
esac

# ---------- DOWNLOAD FUNCTIONS ----------

download_paper() {
    local response url sha
    response=$(curl -fsSL -H "User-Agent: $USER_AGENT" \
        "https://fill.papermc.io/v3/projects/paper/versions/${MC_VERSION}/builds") ||
        fail "Paper does not have a version $MC_VERSION (or the API is unreachable)."

    url=$(jq -r 'first(.[] | select(.channel == "STABLE") | .downloads["server:default"].url) // empty' <<< "$response")
    sha=$(jq -r 'first(.[] | select(.channel == "STABLE") | .downloads["server:default"].checksums.sha256) // empty' <<< "$response")

    [[ -n "$url" ]] || fail "No stable Paper build found for $MC_VERSION."

    download "$url" "$SERVER_DIR/server.jar" sha256 "$sha"
}

download_purpur() {
    curl -fsSL "https://api.purpurmc.org/v2/purpur/${MC_VERSION}" >/dev/null ||
        fail "Purpur does not support Minecraft $MC_VERSION."

    download "https://api.purpurmc.org/v2/purpur/${MC_VERSION}/latest/download" \
        "$SERVER_DIR/server.jar"
}

download_vanilla() {
    local manifest version_url version_json server_url sha1

    manifest=$(curl -fsSL "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json") ||
        fail "Could not retrieve Mojang's version manifest."

    version_url=$(jq -r --arg v "$MC_VERSION" \
        '.versions[] | select(.id == $v and .type == "release") | .url' <<< "$manifest" | head -n 1)

    [[ -n "$version_url" ]] || fail "Minecraft release $MC_VERSION was not found."

    version_json=$(curl -fsSL "$version_url") || fail "Could not retrieve Vanilla version information."
    server_url=$(jq -r '.downloads.server.url // empty' <<< "$version_json")
    sha1=$(jq -r '.downloads.server.sha1 // empty' <<< "$version_json")

    [[ -n "$server_url" ]] || fail "No Vanilla server download is available."

    download "$server_url" "$SERVER_DIR/server.jar" sha1 "$sha1"
}

download_fabric() {
    local loaders loader_version installers installer_version

    loaders=$(curl -fsSL "https://meta.fabricmc.net/v2/versions/loader/${MC_VERSION}") ||
        fail "Fabric does not support Minecraft $MC_VERSION."

    loader_version=$(jq -r 'first(.[] | select(.loader.stable == true) | .loader.version) // empty' <<< "$loaders")
    [[ -n "$loader_version" ]] || fail "No stable Fabric loader found."

    installers=$(curl -fsSL "https://meta.fabricmc.net/v2/versions/installer") ||
        fail "Could not retrieve Fabric installer versions."

    installer_version=$(jq -r 'first(.[] | select(.stable == true) | .version) // empty' <<< "$installers")
    [[ -n "$installer_version" ]] || fail "No stable Fabric installer found."

    info "Fabric loader: $loader_version"

    download "https://meta.fabricmc.net/v2/versions/loader/${MC_VERSION}/${loader_version}/${installer_version}/server/jar" \
        "$SERVER_DIR/server.jar"
}

download_forge() {
    local promotions forge_version installer_name launcher

    promotions=$(curl -fsSL \
        "https://maven.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json") ||
        fail "Could not retrieve Forge version information."

    forge_version=$(jq -r --arg v "$MC_VERSION" \
        '.promos[($v + "-recommended")] // .promos[($v + "-latest")] // empty' <<< "$promotions")

    [[ -n "$forge_version" ]] || fail "No recommended/latest Forge build found for $MC_VERSION."

    info "Forge build: $forge_version"

    installer_name="forge-${MC_VERSION}-${forge_version}-installer.jar"
    download "https://maven.minecraftforge.net/net/minecraftforge/forge/${MC_VERSION}-${forge_version}/${installer_name}" \
        "$SERVER_DIR/forge-installer.jar"

    (
        cd "$SERVER_DIR"
        "$JAVA_BIN" -jar forge-installer.jar --installServer
    ) || fail "Forge server installation failed."

    rm -f "$SERVER_DIR/forge-installer.jar"

    # Prefer run.sh (used by newer Forge). Fall back to a jar for older versions.
    if [[ -f "$SERVER_DIR/run.sh" ]]; then
        launcher="run.sh"
    else
        launcher=$(find "$SERVER_DIR" -maxdepth 1 -type f \
            \( -name 'forge-*-server.jar' -o -name 'forge-*-universal.jar' -o -name 'server.jar' \) \
            -printf '%f\n' | head -n 1 || true)
    fi

    [[ -n "$launcher" ]] || fail "Forge installed, but its server launcher was not found."

    printf '%s\n' "$launcher" > "$SERVER_DIR/launcher.txt"
    [[ "$launcher" == "run.sh" ]] && chmod +x "$SERVER_DIR/run.sh"
}

download_spigot() {
    info "Downloading official Spigot BuildTools..."

    download "https://hub.spigotmc.org/jenkins/job/BuildTools/lastSuccessfulBuild/artifact/target/BuildTools.jar" \
        "$SERVER_DIR/BuildTools.jar"

    # BuildTools needs a git identity and a JDK. This can take 5-15 minutes.
    git config --global user.name >/dev/null 2>&1 || git config --global user.name "FebrezeMC"
    git config --global user.email >/dev/null 2>&1 || git config --global user.email "febrezemc@localhost"

    (
        cd "$SERVER_DIR"
        "$JAVA_BIN" -jar BuildTools.jar --rev "$MC_VERSION"
    ) || fail "Spigot BuildTools could not build Minecraft $MC_VERSION."

    [[ -f "$SERVER_DIR/spigot-${MC_VERSION}.jar" ]] || fail "Spigot JAR was not created."

    mv "$SERVER_DIR/spigot-${MC_VERSION}.jar" "$SERVER_DIR/server.jar"
    rm -f "$SERVER_DIR/BuildTools.jar"
}

# ---------- JAVA ----------

echo
ensure_java "$JAVA_NEEDED"

# ---------- BUILD SERVER ----------

echo
line
echo -e "${CYAN}Building your Minecraft server...${RESET}"
line

CLEANUP=1
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

ask "Do you agree to the Minecraft EULA? [y/N]: " EULA_CHOICE
[[ "$EULA_CHOICE" =~ ^[Yy]$ ]] || fail "EULA was not accepted. Server setup stopped."

echo "eula=true" > "$SERVER_DIR/eula.txt"

# ---------- SERVER PROPERTIES ----------

cat > "$SERVER_DIR/server.properties" <<EOF
online-mode=${ONLINE_MODE}
server-port=${PORT}
motd=FebrezeMC Server
enable-command-block=false
spawn-protection=16
max-players=20
view-distance=8
simulation-distance=6
EOF

# ---------- START SCRIPT ----------

JVM_ARGS="-Xms1G -Xmx${RAM_GB}G"

if [[ "$SOFTWARE" == "Forge" && -f "$SERVER_DIR/launcher.txt" ]]; then
    FORGE_LAUNCHER=$(cat "$SERVER_DIR/launcher.txt")

    if [[ "$FORGE_LAUNCHER" == "run.sh" ]]; then
        # Forge's run.sh reads memory flags from user_jvm_args.txt, not from the command line
        printf '%s\n' "$JVM_ARGS" >> "$SERVER_DIR/user_jvm_args.txt"
        LAUNCH_CMD='exec ./run.sh nogui'
    else
        LAUNCH_CMD="exec \"$JAVA_BIN\" $JVM_ARGS -jar \"$FORGE_LAUNCHER\" nogui"
    fi
else
    LAUNCH_CMD="exec \"$JAVA_BIN\" $JVM_ARGS -jar server.jar nogui"
fi

cat > "$SERVER_DIR/start.sh" <<EOF
#!/usr/bin/env bash
cd "$SERVER_DIR"
$LAUNCH_CMD
EOF

# ---------- SERVICE USER & PERMISSIONS ----------

if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    info "Creating service user '$SERVICE_USER'..."
    useradd --system --home-dir /opt/febrezemc --shell /bin/bash "$SERVICE_USER"
fi

chown -R "$SERVICE_USER:$SERVICE_USER" "$SERVER_DIR"
chmod +x "$SERVER_DIR/start.sh"

# ---------- START SERVER ----------

SESSION_NAME="febrezemc-${SERVER_NAME}"

# From here on, keep the files even if the startup check fails, so they can be inspected
CLEANUP=0

echo
info "Starting your server as '$SERVICE_USER'..."
runuser -u "$SERVICE_USER" -- screen -dmS "$SESSION_NAME" "$SERVER_DIR/start.sh" ||
    fail "Could not start the server."

info "Waiting for port $PORT to open (the first start can take a few minutes)..."
READY=0
for _ in $(seq 1 90); do
    if port_listening "$PORT"; then
        READY=1
        break
    fi
    sleep 2
done

if (( READY == 1 )); then
    success "Server is listening on port $PORT."
else
    warn "The server has not opened port $PORT yet. Check: $SERVER_DIR/logs/latest.log"
fi

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    warn "UFW firewall is active. Open the port with: ufw allow ${PORT}/tcp"
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
echo "  Java        : $JAVA_BIN"
echo "  RAM         : ${RAM_GB} GB"
echo "  Cracked     : $([[ "$ONLINE_MODE" == "false" ]] && echo Yes || echo No)"
echo "  Directory   : $SERVER_DIR"
echo "  Run as user : $SERVICE_USER"
echo "  Port        : $PORT"
echo
echo "  Connect using:"
echo "  YOUR_VPS_IP:${PORT}"
echo
echo "  Useful commands:"
echo "  Attach console : runuser -u $SERVICE_USER -- screen -r $SESSION_NAME"
echo "  Detach console : Ctrl+A, then D"
echo "  Stop server    : type stop in the server console"
echo
line
success "Thank you for using FebrezeMC!"
