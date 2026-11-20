#!/usr/bin/env bash
# FebrezeMC - cross-distro Minecraft server installer
# One-file installer. Tested package-manager families: APT, DNF/YUM, Zypper, Pacman.
set -Eeuo pipefail
IFS=$'\n\t'

VERSION="2.0.0"
BASE_DIR="/opt/febrezemc/servers"
MC_USER="febrezemc"
USER_AGENT="FebrezeMC/${VERSION} (https://github.com/febreze-gamerz/FebrezeMC)"

BLUE='\033[0;34m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; RED='\033[0;31m'; RESET='\033[0m'
info(){ printf "${CYAN}[INFO]${RESET} %s\n" "$*"; }
success(){ printf "${GREEN}[OK]${RESET} %s\n" "$*"; }
warn(){ printf "${YELLOW}[WARN]${RESET} %s\n" "$*"; }
error(){ printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2; }
line(){ printf "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"; }
fail(){ error "$*"; exit 1; }
ask(){ local prompt="$1"; local __var="$2"; local value; read -r -p "$prompt" value; printf -v "$__var" '%s' "$value"; }

INSTALL_COMPLETE=0
SERVER_DIR=""
SERVER_CREATED=0
cleanup(){
    local rc=$?
    if (( INSTALL_COMPLETE == 0 && SERVER_CREATED == 1 )) && [[ -n "$SERVER_DIR" && -d "$SERVER_DIR" ]]; then
        warn "Installation did not complete; removing the incomplete server folder."
        rm -rf -- "$SERVER_DIR"
    fi
    exit "$rc"
}
trap cleanup EXIT

[[ $EUID -eq 0 ]] || fail "Run as root: sudo bash install.sh"
[[ -r /etc/os-release ]] || fail "Cannot identify this Linux distribution."
# shellcheck disable=SC1091
. /etc/os-release

OS_ID="${ID:-unknown}"
OS_LIKE="${ID_LIKE:-}"
OS_NAME="${PRETTY_NAME:-$OS_ID}"
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|aarch64|arm64) ;;
    *) fail "Unsupported CPU architecture: $ARCH (supported: x86_64 and ARM64)." ;;
esac

# Detect the package manager actually present. Never run a guessed package manager.
if command -v apt-get >/dev/null 2>&1; then PM="apt"
elif command -v dnf >/dev/null 2>&1; then PM="dnf"
elif command -v yum >/dev/null 2>&1; then PM="yum"
elif command -v zypper >/dev/null 2>&1; then PM="zypper"
elif command -v pacman >/dev/null 2>&1; then PM="pacman"
else fail "Unsupported package manager. Supported: APT, DNF/YUM, Zypper and Pacman."
fi

case "$OS_ID $OS_LIKE" in
    *alpine*) fail "Alpine Linux is not supported yet (musl compatibility needs separate testing)." ;;
esac

install_packages(){
    case "$PM" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y curl wget jq git screen ca-certificates unzip procps iproute2
            ;;
        dnf)
            dnf install -y curl wget jq git screen ca-certificates unzip procps-ng iproute
            ;;
        yum)
            yum install -y curl wget jq git screen ca-certificates unzip procps-ng iproute
            ;;
        zypper)
            zypper --non-interactive refresh
            zypper --non-interactive install --no-recommends curl wget jq git screen ca-certificates unzip procps iproute2
            ;;
        pacman)
            pacman -Sy --noconfirm --needed curl wget jq git screen ca-certificates unzip procps iproute2
            ;;
    esac
}

install_java(){
    local major="$1"
    info "Installing Java ${major} runtime..."
    case "$PM:$major" in
        apt:8) apt-get install -y openjdk-8-jre-headless ;;
        apt:16|apt:17) apt-get install -y openjdk-${major}-jre-headless ;;
        apt:21|apt:25) apt-get install -y openjdk-${major}-jre-headless ;;
        dnf:8) dnf install -y java-1.8.0-openjdk-headless ;;
        dnf:16|dnf:17) dnf install -y java-${major}-openjdk-headless ;;
        dnf:21|dnf:25) dnf install -y java-${major}-openjdk-headless ;;
        yum:8) yum install -y java-1.8.0-openjdk-headless ;;
        yum:16|yum:17) yum install -y java-${major}-openjdk-headless ;;
        yum:21|yum:25) yum install -y java-${major}-openjdk-headless ;;
        zypper:8) zypper --non-interactive install java-1_8_0-openjdk-headless ;;
        zypper:16|zypper:17|zypper:21|zypper:25) zypper --non-interactive install java-${major}-openjdk-headless ;;
        pacman:8) pacman -S --noconfirm --needed jre8-openjdk-headless ;;
        pacman:16|pacman:17) pacman -S --noconfirm --needed jre${major}-openjdk-headless ;;
        pacman:21|pacman:25) pacman -S --noconfirm --needed jre${major}-openjdk-headless ;;
        *) fail "No Java ${major} package mapping is available for $PM." ;;
    esac
}

java_major(){
    local v="$1" major minor patch
    IFS='.' read -r major minor patch <<< "$v"
    if (( major >= 26 )); then echo 25
    elif (( major > 1 )); then echo 25
    elif (( minor > 20 )) || (( minor == 20 && ${patch:-0} >= 5 )); then echo 21
    elif (( minor >= 18 )); then echo 17
    elif (( minor == 17 )); then echo 16
    else echo 8
    fi
}

echo
line
printf "${CYAN}       FEBREZEMC SERVER INSTALLER${RESET}\n"
printf "${BLUE}       Version %s${RESET}\n" "$VERSION"
line
echo
RAM_TOTAL_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
RAM_AVAILABLE_MB="$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)"
CPU_CORES="$(nproc)"
DISK_INFO="$(df -h "$BASE_DIR" 2>/dev/null | awk 'NR==2 {print $4 " free / " $2 " total"}')"
[[ -n "$DISK_INFO" ]] || DISK_INFO="$(df -h / | awk 'NR==2 {print $4 " free / " $2 " total"}')"
RAM_USED_MB="$(free -m | awk '/^Mem:/ {print $3}')"

printf "${CYAN}VPS information${RESET}\n"
printf "  Operating system : %s\n  Package manager  : %s\n  Architecture     : %s\n  CPU cores        : %s\n  Total RAM        : %s MB\n  RAM used         : %s MB\n  RAM available    : %s MB\n  Disk space       : %s\n" \
    "$OS_NAME" "$PM" "$ARCH" "$CPU_CORES" "$RAM_TOTAL_MB" "$RAM_USED_MB" "$RAM_AVAILABLE_MB" "$DISK_INFO"
echo
warn "This installer creates files only under $BASE_DIR and a dedicated system account named $MC_USER."
warn "It will not modify files in your Discord bot's folder."
echo
read -r -p "Continue with dependency installation? [y/N]: " CONTINUE
[[ "$CONTINUE" =~ ^[Yy]$ ]] || fail "Cancelled."

install_packages
command -v curl >/dev/null 2>&1 || fail "curl installation failed."
command -v jq >/dev/null 2>&1 || fail "jq installation failed."
command -v screen >/dev/null 2>&1 || fail "screen installation failed."

echo
printf "${CYAN}Select Minecraft server software:${RESET}\n"
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
JAVA_NEEDED="$(java_major "$MC_VERSION")"
info "Minecraft $MC_VERSION will use Java $JAVA_NEEDED (version mapping)."

ask "Server name (letters, numbers, - or _): " SERVER_NAME
SERVER_NAME="$(printf '%s' "$SERVER_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
[[ -n "$SERVER_NAME" && "$SERVER_NAME" != "." && "$SERVER_NAME" != ".." ]] || fail "Invalid server name."
SERVER_DIR="$BASE_DIR/$SERVER_NAME"
[[ ! -e "$SERVER_DIR" ]] || fail "That server folder already exists: $SERVER_DIR"

# Keep at least 1.5 GiB available for the OS and other services.
MAX_RAM_GB=$(((RAM_AVAILABLE_MB - 1536) / 1024))
(( MAX_RAM_GB >= 1 )) || fail "Not enough currently available RAM to safely create a server. Free some memory first."
DEFAULT_RAM=2
(( DEFAULT_RAM > MAX_RAM_GB )) && DEFAULT_RAM="$MAX_RAM_GB"
echo
printf "${CYAN}RAM allocation${RESET}\n"
echo "Available RAM now: ${RAM_AVAILABLE_MB} MB"
echo "Maximum suggested allocation: ${MAX_RAM_GB} GB (reserves at least about 1.5 GB)."
ask "Server RAM in GB [${DEFAULT_RAM}]: " RAM_GB
RAM_GB="${RAM_GB:-$DEFAULT_RAM}"
[[ "$RAM_GB" =~ ^[0-9]+$ ]] || fail "RAM must be a whole number."
(( RAM_GB >= 1 && RAM_GB <= MAX_RAM_GB )) || fail "Choose between 1 and ${MAX_RAM_GB} GB."

echo
printf "${CYAN}Account authentication${RESET}\n"
echo "  1) Online mode (recommended; authenticated accounts)"
echo "  2) Offline mode (allows unauthenticated usernames)"
ask "Choose [1/2]: " AUTH_CHOICE
case "$AUTH_CHOICE" in
    1) ONLINE_MODE="true" ;;
    2)
        ONLINE_MODE="false"
        warn "Offline mode is risky on public servers: players may impersonate other usernames."
        ;;
    *) fail "Choose 1 or 2." ;;
esac

DEFAULT_PORT=25565
ask "Server port [${DEFAULT_PORT}]: " SERVER_PORT
SERVER_PORT="${SERVER_PORT:-$DEFAULT_PORT}"
[[ "$SERVER_PORT" =~ ^[0-9]+$ ]] && (( SERVER_PORT >= 1024 && SERVER_PORT <= 65535 )) ||
    fail "Port must be a number between 1024 and 65535."
if command -v ss >/dev/null 2>&1 && ss -H -ltn "sport = :$SERVER_PORT" | grep -q .; then
    fail "TCP port $SERVER_PORT is already in use. Choose another port."
fi

echo
warn "Minecraft's EULA must be accepted before the server can run."
echo "Read: https://aka.ms/MinecraftEULA"
read -r -p "Do you agree to the EULA? [y/N]: " EULA_CHOICE
[[ "$EULA_CHOICE" =~ ^[Yy]$ ]] || fail "EULA not accepted; cancelled."

# Install requested Java only after version is known.
if command -v java >/dev/null 2>&1; then
    CURRENT_JAVA="$(java -XshowSettings:properties -version 2>&1 | awk -F'= ' '/java.specification.version/ {print $2; exit}')"
    [[ "$CURRENT_JAVA" == "1.8" ]] && CURRENT_JAVA="8"
else
    CURRENT_JAVA=""
fi
if [[ "$CURRENT_JAVA" != "$JAVA_NEEDED" ]]; then
    install_java "$JAVA_NEEDED"
fi
command -v java >/dev/null 2>&1 || fail "Java is not available after installation."
JAVA_BIN="$(command -v java)"
CURRENT_JAVA="$(java -XshowSettings:properties -version 2>&1 | awk -F'= ' '/java.specification.version/ {print $2; exit}')"
[[ "$CURRENT_JAVA" == "1.8" ]] && CURRENT_JAVA="8"
[[ "$CURRENT_JAVA" == "$JAVA_NEEDED" ]] ||
    fail "Java $JAVA_NEEDED is required, but the active Java is ${CURRENT_JAVA:-unknown}. Select the correct Java with your distro's alternatives tool and rerun."

# Dedicated unprivileged account; never run the Minecraft JVM as root.
if ! id "$MC_USER" >/dev/null 2>&1; then
    if command -v useradd >/dev/null 2>&1; then
        useradd --system --create-home --home-dir "/var/lib/$MC_USER" --shell /usr/sbin/nologin "$MC_USER"
    elif command -v adduser >/dev/null 2>&1; then
        adduser --system --home "/var/lib/$MC_USER" --shell /usr/sbin/nologin "$MC_USER"
    else
        fail "Cannot create the dedicated $MC_USER account on this system."
    fi
fi

install -d -m 0750 -o "$MC_USER" -g "$MC_USER" "$BASE_DIR"
install -d -m 0750 -o "$MC_USER" -g "$MC_USER" "$SERVER_DIR"
SERVER_CREATED=1
chown "$MC_USER:$MC_USER" "$SERVER_DIR"

download_paper(){
    local response url
    response="$(curl -fsSL -H "User-Agent: $USER_AGENT" \
        "https://fill.papermc.io/v3/projects/paper/versions/${MC_VERSION}/builds")" ||
        fail "Could not contact the Paper API."
    url="$(jq -r 'first(.[] | select(.channel == "STABLE") | .downloads["server:default"].url) // empty' <<< "$response")"
    [[ -n "$url" && "$url" != "null" ]] || fail "No stable Paper build found for $MC_VERSION."
    curl -fL --retry 3 "$url" -o "$SERVER_DIR/server.jar" || fail "Paper download failed."
}
download_purpur(){
    curl -fL --retry 3 "https://api.purpurmc.org/v2/purpur/${MC_VERSION}/latest/download" \
        -o "$SERVER_DIR/server.jar" || fail "Purpur does not provide $MC_VERSION."
}
download_vanilla(){
    local manifest version_url version_json server_url
    manifest="$(curl -fsSL https://piston-meta.mojang.com/mc/game/version_manifest_v2.json)" ||
        fail "Could not retrieve Mojang's version manifest."
    version_url="$(jq -r --arg v "$MC_VERSION" '.versions[] | select(.id==$v and .type=="release") | .url' <<< "$manifest" | head -n1)"
    [[ -n "$version_url" ]] || fail "Minecraft release $MC_VERSION was not found."
    version_json="$(curl -fsSL "$version_url")" || fail "Could not retrieve version metadata."
    server_url="$(jq -r '.downloads.server.url // empty' <<< "$version_json")"
    [[ -n "$server_url" ]] || fail "No Vanilla server download is available."
    curl -fL --retry 3 "$server_url" -o "$SERVER_DIR/server.jar" || fail "Vanilla download failed."
}
download_fabric(){
    local loaders loader_version installers installer_version
    loaders="$(curl -fsSL "https://meta.fabricmc.net/v2/versions/loader/${MC_VERSION}")" || fail "Fabric API unavailable."
    loader_version="$(jq -r 'first(.[] | select(.loader.stable==true) | .loader.version) // empty' <<< "$loaders")"
    [[ -n "$loader_version" ]] || fail "No stable Fabric loader found for $MC_VERSION."
    installers="$(curl -fsSL https://meta.fabricmc.net/v2/versions/installer)" || fail "Fabric installer API unavailable."
    installer_version="$(jq -r 'first(.[] | select(.stable==true) | .version) // empty' <<< "$installers")"
    [[ -n "$installer_version" ]] || fail "No stable Fabric installer found."
    curl -fL --retry 3 \
        "https://meta.fabricmc.net/v2/versions/loader/${MC_VERSION}/${loader_version}/${installer_version}/server/jar" \
        -o "$SERVER_DIR/server.jar" || fail "Fabric server download failed."
}
download_forge(){
    local promotions forge_version installer forge_url
    promotions="$(curl -fsSL https://maven.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json)" ||
        fail "Could not retrieve Forge metadata."
    forge_version="$(jq -r --arg v "$MC_VERSION" '.promos[($v+"-recommended")] // .promos[($v+"-latest")] // empty' <<< "$promotions")"
    [[ -n "$forge_version" ]] || fail "No recommended/latest Forge build found for $MC_VERSION."
    installer="forge-${MC_VERSION}-${forge_version}-installer.jar"
    forge_url="https://maven.minecraftforge.net/net/minecraftforge/forge/${MC_VERSION}-${forge_version}/${installer}"
    curl -fL --retry 3 "$forge_url" -o "$SERVER_DIR/forge-installer.jar" || fail "Forge installer download failed."
    runuser -u "$MC_USER" -- bash -c 'cd "$1" && java -jar forge-installer.jar --installServer' _ "$SERVER_DIR" ||
        fail "Forge server installation failed."
    rm -f "$SERVER_DIR/forge-installer.jar"
    if [[ -f "$SERVER_DIR/run.sh" ]]; then
        printf '%s\n' "run.sh" > "$SERVER_DIR/launcher.txt"
    else
        local forge_jar
        forge_jar="$(find "$SERVER_DIR" -maxdepth 1 -type f -name 'forge-*-server.jar' -print -quit)"
        [[ -n "$forge_jar" ]] || fail "Forge installer did not create a recognized server launcher."
        basename "$forge_jar" > "$SERVER_DIR/launcher.txt"
    fi
}
download_spigot(){
    warn "Spigot BuildTools can take a while and use substantial CPU, RAM and disk."
    curl -fL --retry 3 \
        https://hub.spigotmc.org/jenkins/job/BuildTools/lastSuccessfulBuild/artifact/target/BuildTools.jar \
        -o "$SERVER_DIR/BuildTools.jar" || fail "Could not download Spigot BuildTools."
    runuser -u "$MC_USER" -- bash -c 'cd "$1" && java -jar BuildTools.jar --rev "$2"' _ "$SERVER_DIR" "$MC_VERSION" ||
        fail "Spigot BuildTools failed."
    [[ -f "$SERVER_DIR/spigot-${MC_VERSION}.jar" ]] || fail "Spigot JAR was not created."
    mv "$SERVER_DIR/spigot-${MC_VERSION}.jar" "$SERVER_DIR/server.jar"
    rm -f "$SERVER_DIR/BuildTools.jar"
}

echo
line
printf "${CYAN}Downloading/building %s %s...${RESET}\n" "$SOFTWARE" "$MC_VERSION"
line
case "$SOFTWARE" in
    Paper) download_paper ;;
    Purpur) download_purpur ;;
    Vanilla) download_vanilla ;;
    Forge) download_forge ;;
    Spigot) download_spigot ;;
    Fabric) download_fabric ;;
esac

[[ -s "$SERVER_DIR/server.jar" || ( "$SOFTWARE" == "Forge" && -f "$SERVER_DIR/run.sh" ) ]] ||
    fail "Server files were not created correctly."

cat > "$SERVER_DIR/eula.txt" <<'EOF'
eula=true
EOF
cat > "$SERVER_DIR/server.properties" <<EOF
online-mode=${ONLINE_MODE}
server-port=${SERVER_PORT}
motd=FebrezeMC Server
enable-command-block=false
spawn-protection=16
max-players=20
view-distance=8
simulation-distance=6
EOF

if [[ "$SOFTWARE" == "Forge" && -f "$SERVER_DIR/launcher.txt" ]]; then
    FORGE_LAUNCHER="$(cat "$SERVER_DIR/launcher.txt")"
    if [[ "$FORGE_LAUNCHER" == "run.sh" ]]; then
        printf '%s\n' "-Xms${RAM_GB}G" "-Xmx${RAM_GB}G" > "$SERVER_DIR/user_jvm_args.txt"
        cat > "$SERVER_DIR/start.sh" <<'EOF'
#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
exec ./run.sh nogui
EOF
    else
        cat > "$SERVER_DIR/start.sh" <<EOF
#!/usr/bin/env bash
set -e
cd "$SERVER_DIR"
exec "$JAVA_BIN" -Xms${RAM_GB}G -Xmx${RAM_GB}G -jar "$FORGE_LAUNCHER" nogui
EOF
    fi
else
    cat > "$SERVER_DIR/start.sh" <<EOF
#!/usr/bin/env bash
set -e
cd "$SERVER_DIR"
exec "$JAVA_BIN" -Xms${RAM_GB}G -Xmx${RAM_GB}G -jar server.jar nogui
EOF
fi

chmod 0750 "$SERVER_DIR/start.sh"
chown -R "$MC_USER:$MC_USER" "$SERVER_DIR"

SESSION_NAME="febrezemc-${SERVER_NAME}"
info "Starting server as the unprivileged '$MC_USER' account..."
if command -v runuser >/dev/null 2>&1; then
    runuser -u "$MC_USER" -- screen -DmS "$SESSION_NAME" "$SERVER_DIR/start.sh" ||
        fail "Could not start the server screen session."
elif command -v su >/dev/null 2>&1; then
    su -s /bin/sh "$MC_USER" -c "screen -DmS '$SESSION_NAME' '$SERVER_DIR/start.sh'" ||
        fail "Could not start the server screen session."
else
    fail "Neither runuser nor su is available."
fi

sleep 5
if ! runuser -u "$MC_USER" -- screen -list 2>/dev/null | grep -Fq "$SESSION_NAME"; then
    fail "Server session exited shortly after launch. Check $SERVER_DIR and try running start.sh manually."
fi

INSTALL_COMPLETE=1
echo
line
printf "${GREEN}       FEBREZEMC SETUP COMPLETE!${RESET}\n"
line
printf "  Server       : %s\n  Software     : %s\n  Version      : %s\n  Java         : %s\n  RAM          : %s GB\n  Online mode  : %s\n  Port         : %s\n  Directory    : %s\n  Run as user  : %s\n" \
    "$SERVER_NAME" "$SOFTWARE" "$MC_VERSION" "$JAVA_NEEDED" "$RAM_GB" "$ONLINE_MODE" "$SERVER_PORT" "$SERVER_DIR" "$MC_USER"
echo
echo "  Connect to: YOUR_VPS_IP:${SERVER_PORT}"
echo
echo "  Console:"
echo "    sudo -u ${MC_USER} screen -r ${SESSION_NAME}"
echo "  Detach:"
echo "    Ctrl+A, then D"
echo "  Stop:"
echo "    Type 'stop' in the server console"
echo "  Start again:"
echo "    sudo -u ${MC_USER} screen -DmS ${SESSION_NAME} ${SERVER_DIR}/start.sh"
echo
warn "Offline mode is not recommended for public servers. Use a trusted authentication setup."
line
success "Thank you for using FebrezeMC!"
