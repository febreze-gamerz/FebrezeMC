#!/usr/bin/env bash
# FebrezeMC 2.3.0 - Standalone Minecraft server installer
# Installs into the current working directory on Linux.
set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C

FEBREZE_VERSION="2.3.0"
USER_AGENT="FebrezeMC/${FEBREZE_VERSION} (https://github.com/febreze-gamerz/FebrezeMC)"
MANIFEST_URL="https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
DEFAULT_PORT=25565
RESERVED_RAM_MB=1024
DRY_RUN="${FEBREZEMC_DRY_RUN:-0}"

SERVER_DIR="$(pwd -P)"
SOFTWARE=""
MC_VERSION=""
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

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]] && [[ "${TERM:-}" != "dumb" ]]; then
    BLUE=$'\033[38;5;39m'
    CYAN=$'\033[38;5;81m'
    GREEN=$'\033[38;5;84m'
    YELLOW=$'\033[38;5;221m'
    RED=$'\033[38;5;204m'
    WHITE=$'\033[38;5;255m'
    DIM=$'\033[38;5;245m'
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
else
    BLUE='' CYAN='' GREEN='' YELLOW='' RED='' WHITE='' DIM='' BOLD='' RESET=''
fi

info(){ printf '%b[INFO]%b %b%s%b\n' "$BOLD$CYAN" "$RESET" "$WHITE" "$*" "$RESET"; }
success(){ printf '%b[ OK ]%b %b%s%b\n' "$BOLD$GREEN" "$RESET" "$WHITE" "$*" "$RESET"; }
warn(){ printf '%b[WARN]%b %b%s%b\n' "$BOLD$YELLOW" "$RESET" "$YELLOW" "$*" "$RESET"; }
error(){ printf '%b[FAIL]%b %b%s%b\n' "$BOLD$RED" "$RESET" "$RED" "$*" "$RESET" >&2; }
line(){ printf '%b%s%b\n' "$BLUE" "────────────────────────────────────────────────────────────" "$RESET"; }
fail(){ error "$*"; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1; }

# Count display columns accurately (1 per visible char, ignoring ANSI escape codes)
visible_len(){
    local s="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c '
import re, sys
ansi_re = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
text = ansi_re.sub("", sys.argv[1])
print(len(text))
' "$s"
        return
    fi

    local esc=$'\033' out="" i=0 ch n=${#s}
    while (( i < n )); do
        ch="${s:i:1}"
        if [[ "$ch" == "$esc" && "${s:i+1:1}" == "[" ]]; then
            (( i += 2 ))
            while (( i < n )); do
                ch="${s:i:1}"
                (( i++ ))
                [[ "$ch" =~ [A-Za-z] ]] && break
            done
        else
            out+="$ch"
            (( i++ ))
        fi
    done
    printf '%s' "${#out}"
}

# Inner width between left '║' and right '║' is 58 columns:
# [1 space] + [56 content columns] + [1 space] = 58 columns.
box_line(){
    local base_color="$1"
    local content="$2"
    local content_w=56
    local vlen pad

    vlen="$(visible_len "$content")"
    if (( vlen >= content_w )); then
        pad=0
    else
        pad=$(( content_w - vlen ))
    fi

    printf '%b║%b %b%s%b%*s %b║%b\n' \
        "$BLUE" "$RESET" \
        "$base_color" "$content" "$RESET" \
        "$pad" "" \
        "$BLUE" "$RESET"
}

box_center(){
    local base_color="$1"
    local content="$2"
    local content_w=56
    local vlen total_pad left_pad right_pad

    vlen="$(visible_len "$content")"
    if (( vlen >= content_w )); then
        left_pad=0
        right_pad=0
    else
        total_pad=$(( content_w - vlen ))
        left_pad=$(( total_pad / 2 ))
        right_pad=$(( total_pad - left_pad ))
    fi

    printf '%b║%b %*s%b%s%b%*s %b║%b\n' \
        "$BLUE" "$RESET" \
        "$left_pad" "" \
        "$base_color" "$content" "$RESET" \
        "$right_pad" "" \
        "$BLUE" "$RESET"
}

panel_top(){
    printf '%b╔══════════════════════════════════════════════════════════╗%b\n' "$BLUE" "$RESET"
    box_line "$BOLD$CYAN" "$1"
    printf '%b╠══════════════════════════════════════════════════════════╣%b\n' "$BLUE" "$RESET"
}
panel_row(){
    box_line "$WHITE" "$1"
}
panel_blank(){
    box_line "$WHITE" ""
}
panel_bottom(){
    printf '%b╚══════════════════════════════════════════════════════════╝%b\n' "$BLUE" "$RESET"
}
panel_end(){ panel_bottom; printf '\n'; }
panel_section(){
    printf '\n'
    panel_top "$1"
}

banner(){
    clear 2>/dev/null || true
    panel_top "FEBREZEMC"
    panel_blank
    box_center "$BOLD$CYAN" "███████╗███████╗██████╗ ██████╗ ███████╗"
    box_center "$BOLD$CYAN" "██╔════╝██╔════╝██╔══██╗██╔══██╗╚══███╔╝"
    box_center "$BOLD$CYAN" "█████╗  █████╗  ██████╔╝██████╔╝  ███╔╝ "
    box_center "$BOLD$CYAN" "██╔══╝  ██╔══╝  ██╔══██╗██╔══██╗ ███╔╝  "
    box_center "$BOLD$CYAN" "██║     ███████╗██║  ██║██║  ██║███████╗"
    box_center "$BOLD$CYAN" "╚═╝     ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝"
    panel_blank
    box_center "$BOLD$CYAN" "FEBREZEMC"
    box_center "$CYAN" "MINECRAFT SERVER INSTALLER"
    panel_blank
    box_center "$BOLD$GREEN" "Version ${FEBREZE_VERSION}"
    panel_blank
    panel_bottom
}

ask(){
    local prompt="$1" var="$2" value=""
    printf '%b%s%b' "$BOLD$CYAN" "$prompt" "$RESET"
    IFS= read -r value || fail "No input received. Run this installer in an interactive terminal."
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

for cmd in bash curl jq unzip awk sed grep find df nproc readlink; do
    need "$cmd" || fail "Required command '$cmd' is missing. Install it first, then rerun FebrezeMC."
done
for cmd in sha1sum sha256sum; do
    need "$cmd" || fail "Required command '$cmd' is missing."
done
need ss || warn "The 'ss' command is unavailable; port-use checking will be skipped."

RAM_TOTAL_MB="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)"
RAM_AVAILABLE_MB="$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo)"
CPU_CORES="$(nproc)"
DISK_FREE_MB="$(free_mb_at "$SERVER_DIR")"
MAX_RAM_GB=$(( (RAM_AVAILABLE_MB - RESERVED_RAM_MB) / 1024 ))
(( MAX_RAM_GB >= 1 )) || fail "Not enough memory available for a server allocation of at least 1 GB."
DEFAULT_RAM=2
(( DEFAULT_RAM <= MAX_RAM_GB )) || DEFAULT_RAM="$MAX_RAM_GB"

banner
printf '\n'
printf '        %b[1]%b %bCreate Minecraft Server%b\n' "$BOLD$GREEN" "$RESET" "$WHITE" "$RESET"
printf '        %b[0]%b %bExit%b\n\n' "$BOLD$YELLOW" "$RESET" "$WHITE" "$RESET"
ask "Select an option: " MAIN_CHOICE
case "$MAIN_CHOICE" in
    1) ;;
    0) info "Goodbye."; exit 0 ;;
    *) fail "Invalid menu option." ;;
esac

if (( DRY_RUN == 1 )); then
    warn "DRY RUN enabled — downloads and file creation will be skipped."
fi
JAVA_DISPLAY="Not detected"
if need java; then
    JAVA_DISPLAY="$(java -version 2>&1 | awk -F'"' '/version/ {print "Java " $2; exit}')"
    JAVA_DISPLAY="${JAVA_DISPLAY:-Installed}"
fi
panel_section "VPS INFORMATION"
panel_blank
panel_row "$(printf '%-15s %b%s%b' "OS"            "$BOLD$WHITE" "$OS_NAME" "$RESET")"
panel_row "$(printf '%-15s %b%s%b' "CPU"           "$BOLD$WHITE" "${CPU_CORES} vCPU" "$RESET")"
panel_row "$(printf '%-15s %b%s%b' "RAM"           "$BOLD$WHITE" "$((RAM_TOTAL_MB / 1024)) GB (${RAM_TOTAL_MB} MB)" "$RESET")"
panel_row "$(printf '%-15s %b%s%b' "RAM AVAILABLE" "$BOLD$GREEN" "$((RAM_AVAILABLE_MB / 1024)) GB (${RAM_AVAILABLE_MB} MB)" "$RESET")"
panel_row "$(printf '%-15s %b%s%b' "STORAGE"       "$BOLD$WHITE" "$((DISK_FREE_MB / 1024)) GB free" "$RESET")"
panel_row "$(printf '%-15s %b%s%b' "JAVA"          "$BOLD$CYAN"  "$JAVA_DISPLAY" "$RESET")"
panel_row "$(printf '%-15s %b%s%b' "ARCHITECTURE"  "$BOLD$WHITE" "$ARCH" "$RESET")"
panel_blank
panel_bottom
printf '\n'
info "Install location: $SERVER_DIR"
ask "Continue? [Y/n]: " CONTINUE
[[ ! "$CONTINUE" =~ ^[Nn]$ ]] || fail "Installation cancelled."

panel_section "SELECT SERVER SOFTWARE"
panel_blank
panel_row "${BOLD}${YELLOW}[1]${RESET} ${BOLD}${WHITE}Paper${RESET}    ${DIM}-${RESET} Performance + Plugins"
panel_row "${BOLD}${YELLOW}[2]${RESET} ${BOLD}${WHITE}Purpur${RESET}   ${DIM}-${RESET} Customization + Plugins"
panel_row "${BOLD}${YELLOW}[3]${RESET} ${BOLD}${WHITE}Vanilla${RESET}  ${DIM}-${RESET} Official Minecraft"
panel_row "${BOLD}${YELLOW}[4]${RESET} ${BOLD}${WHITE}Forge${RESET}    ${DIM}-${RESET} Modded Minecraft"
panel_row "${BOLD}${YELLOW}[5]${RESET} ${BOLD}${WHITE}Spigot${RESET}   ${DIM}-${RESET} Plugin Support"
panel_row "${BOLD}${YELLOW}[6]${RESET} ${BOLD}${WHITE}Fabric${RESET}   ${DIM}-${RESET} Lightweight Mods"
panel_blank
panel_row "${BOLD}${YELLOW}[0]${RESET} ${DIM}Exit${RESET}"
panel_bottom
printf '\n'
ask "Select software [1-6, 0]: " SOFTWARE_CHOICE
case "$SOFTWARE_CHOICE" in
    1) SOFTWARE="Paper" ;; 2) SOFTWARE="Purpur" ;; 3) SOFTWARE="Vanilla" ;;
    4) SOFTWARE="Forge" ;; 5) SOFTWARE="Spigot" ;; 6) SOFTWARE="Fabric" ;;
    0) info "Goodbye."; exit 0 ;;
    *) fail "Invalid software selection." ;;
esac

panel_section "SELECT MINECRAFT VERSION"
panel_blank
panel_row "Enter the Minecraft release you want to install."
panel_row "${DIM}Example: 1.21.11${RESET}"
panel_bottom
printf '\n'
ask "Minecraft version: " MC_VERSION
[[ "$MC_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || fail "Invalid Minecraft version format."
info "Checking Minecraft version availability..."
MANIFEST="$(fetch_json "$MANIFEST_URL")" || fail "Could not reach Mojang's version manifest."
VERSION_URL="$(jq -r --arg v "$MC_VERSION" 'first(.versions[] | select(.id == $v and .type == "release") | .url) // empty' <<< "$MANIFEST")"
[[ -n "$VERSION_URL" ]] || fail "Minecraft $MC_VERSION is not a release listed by Mojang."
VERSION_META="$(fetch_json "$VERSION_URL")" || fail "Could not get Minecraft version metadata."
REQUIRED_JAVA="$(jq -r '.javaVersion.majorVersion // 8' <<< "$VERSION_META")"
[[ "$REQUIRED_JAVA" =~ ^[0-9]+$ ]] || fail "Could not read the required Java version."
success "Minecraft $MC_VERSION is available."
info "Minecraft $MC_VERSION requires Java $REQUIRED_JAVA."

panel_section "RAM CONFIGURATION"
panel_blank
panel_row "Total VPS RAM:       ${BOLD}${WHITE}$((RAM_TOTAL_MB / 1024)) GB${RESET}"
panel_row "Available RAM:       ${BOLD}${GREEN}$((RAM_AVAILABLE_MB / 1024)) GB${RESET}"
panel_row "Maximum safe choice: ${BOLD}${YELLOW}${MAX_RAM_GB} GB${RESET}"
panel_blank
panel_row "${BOLD}${YELLOW}[1]${RESET} 1 GB"
panel_row "${BOLD}${YELLOW}[2]${RESET} 2 GB"
panel_row "${BOLD}${YELLOW}[3]${RESET} 3 GB"
panel_row "${BOLD}${YELLOW}[4]${RESET} 4 GB"
panel_row "${BOLD}${YELLOW}[5]${RESET} Custom amount"
panel_bottom
printf '\n'
ask "Server RAM in GB [${DEFAULT_RAM}]: " RAM_GB
RAM_GB="${RAM_GB:-$DEFAULT_RAM}"
[[ "$RAM_GB" =~ ^[0-9]{1,3}$ ]] || fail "RAM must be a whole number."
RAM_GB=$((10#$RAM_GB))
(( RAM_GB >= 1 && RAM_GB <= MAX_RAM_GB )) || fail "Choose between 1 and ${MAX_RAM_GB} GB."

panel_section "ACCOUNT AUTHENTICATION"
panel_blank
panel_row "Allow offline / cracked accounts?"
panel_blank
panel_row "${BOLD}${YELLOW}[1]${RESET} ${BOLD}${YELLOW}YES${RESET}  - online-mode=false"
panel_row "${BOLD}${YELLOW}[2]${RESET} ${BOLD}${GREEN}NO${RESET}   - online-mode=true (recommended)"
panel_blank
panel_row "${YELLOW}WARNING: Offline mode allows username${RESET}"
panel_row "${YELLOW}impersonation. It is unsafe for public servers.${RESET}"
panel_bottom
printf '\n'
ask "Choose [1/2]: " AUTH_CHOICE
case "$AUTH_CHOICE" in
    1) ONLINE_MODE=false; warn "Offline mode allows username impersonation. It is unsafe for public servers." ;;
    2) ONLINE_MODE=true ;;
    *) fail "Choose 1 or 2." ;;
esac

panel_section "NETWORK CONFIGURATION"
panel_blank
panel_row "Default Minecraft Java port: ${BOLD}${WHITE}25565${RESET}"
panel_row "${DIM}Use this port unless you need a custom one.${RESET}"
panel_bottom
printf '\n'
PORT_DEFAULT="$DEFAULT_PORT"
ask "Server port [${PORT_DEFAULT}]: " SERVER_PORT
SERVER_PORT="${SERVER_PORT:-$PORT_DEFAULT}"
[[ "$SERVER_PORT" =~ ^[0-9]{1,5}$ ]] || fail "Port must be a number."
SERVER_PORT=$((10#$SERVER_PORT))
(( SERVER_PORT >= 1 && SERVER_PORT <= 65535 )) || fail "Port must be between 1 and 65535."
if need ss && ss -H -ltn "sport = :${SERVER_PORT}" 2>/dev/null | grep -q .; then
    fail "TCP port $SERVER_PORT is already in use. Choose another port."
fi

panel_section "MINECRAFT EULA"
panel_blank
panel_row "You must read and agree to the Minecraft EULA."
panel_row "${CYAN}https://aka.ms/MinecraftEULA${RESET}"
panel_blank
panel_row "The installer will only continue if you agree."
panel_bottom
printf '\n'
ask "Do you agree? [y/N]: " EULA_CHOICE
[[ "$EULA_CHOICE" =~ ^[Yy]$ ]] || fail "EULA not accepted; cancelled."

for target in server.jar start.sh eula.txt server.properties forge-installer.jar BuildTools.jar run.sh user_jvm_args.txt libraries world; do
    [[ ! -e "$SERVER_DIR/$target" && ! -L "$SERVER_DIR/$target" ]] ||
        fail "$SERVER_DIR/$target already exists. Back it up or use an empty server directory."
done
NEED_DISK_MB=2048
case "$SOFTWARE" in Spigot) NEED_DISK_MB=8192 ;; Forge) NEED_DISK_MB=4096 ;; esac
(( DISK_FREE_MB >= NEED_DISK_MB )) || fail "Not enough free disk space. Need about ${NEED_DISK_MB} MB."

panel_section "JAVA VALIDATION"
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
    printf '\n'
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

panel_section "INSTALLATION PROGRESS"
panel_blank
panel_row "${BOLD}${GREEN}[OK]${RESET} System requirements checked"
panel_row "${BOLD}${GREEN}[OK]${RESET} Java $REQUIRED_JAVA selected"
panel_row "${BOLD}${GREEN}[OK]${RESET} RAM and network settings saved"
panel_row "${BOLD}${GREEN}[OK]${RESET} EULA accepted"
panel_row "${BOLD}${CYAN}[..]${RESET} Downloading and preparing ${SOFTWARE}..."
panel_bottom
printf '\n'
info "Installing ${SOFTWARE} ${MC_VERSION}. Please wait..."
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
motd=A Minecraft Server
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
panel_section "INSTALLATION COMPLETED"
panel_blank
panel_row "${BOLD}${GREEN}[OK]${RESET} Server software downloaded"
panel_row "${BOLD}${GREEN}[OK]${RESET} Server configuration created"
panel_row "${BOLD}${GREEN}[OK]${RESET} RAM settings configured"
panel_row "${BOLD}${GREEN}[OK]${RESET} EULA accepted"
panel_blank
panel_row "SOFTWARE   : ${BOLD}${WHITE}${SOFTWARE}${RESET}"
panel_row "VERSION    : ${BOLD}${WHITE}${MC_VERSION}${RESET}"
panel_row "JAVA       : ${BOLD}${CYAN}${REQUIRED_JAVA}${RESET}"
panel_row "RAM        : ${BOLD}${GREEN}${RAM_GB} GB${RESET}"
panel_row "PORT       : ${BOLD}${WHITE}${SERVER_PORT}${RESET}"
panel_row "AUTH       : $([[ "$ONLINE_MODE" == true ]] && printf '%bOnline%b' "$BOLD$GREEN" "$RESET" || printf '%bOffline%b' "$BOLD$YELLOW" "$RESET")"
panel_blank
panel_row "${BOLD}${CYAN}SERVER ADDRESS${RESET}"
panel_row "${BOLD}${WHITE}YOUR_VPS_IP:${SERVER_PORT}${RESET}"
panel_blank
panel_row "Start server : ${BOLD}${WHITE}./start.sh${RESET}"
panel_row "Stop server  : type ${BOLD}${WHITE}stop${RESET} in its console"
panel_row "Folder       : ${DIM}${SERVER_DIR}${RESET}"
panel_blank
panel_bottom
printf '\n'
success "Your Minecraft server files are ready!"
info "The server is not started automatically. Run ./start.sh to launch it."
if [[ "$ONLINE_MODE" == false ]]; then
    warn "Offline mode is not recommended for public servers."
fi
printf '\n'
success "Thank you for using FebrezeMC!"
