#!/usr/bin/env bash
# FEBREZEMC TUI & Prompt Helpers (ANSI-safe, literal-\n free, exact-width boxes)

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]] && [[ "${TERM:-}" != "dumb" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_BORDER=$'\033[38;5;39m'     # Crisp cyan-blue
  C_TITLE=$'\033[38;5;81m'      # Bright sky cyan
  C_ACCENT=$'\033[38;5;45m'     # Electric aqua
  C_TEXT=$'\033[38;5;252m'      # Soft off-white
  C_MUTED=$'\033[38;5;244m'     # Neutral slate gray
  C_KEY=$'\033[38;5;221m'       # Warm gold for [1], [2], etc.
  C_OK=$'\033[38;5;42m'         # Emerald green
  C_WARN=$'\033[38;5;214m'      # Amber orange
  C_ERR=$'\033[38;5;203m'       # Soft coral red
  C_INFO=$'\033[38;5;75m'       # Calm steel blue
else
  C_RESET='' C_BOLD='' C_DIM='' C_BORDER='' C_TITLE='' C_ACCENT=''
  C_TEXT='' C_MUTED='' C_KEY='' C_OK='' C_WARN='' C_ERR='' C_INFO=''
fi

# Strip ANSI sequences to measure true printable character count
_strip_ansi() {
  local s="$1"
  s="${s//$'\033'\[*([0-9;])m/}"
  printf '%s' "$s"
}

_pad_line() {
  local content="$1"
  local inner_w="$2"
  local plain
  plain="$(_strip_ansi "$content")"
  local len=${#plain}
  if (( len > inner_w )); then
    # Truncate plain text safely if a line ever exceeds inner width
    printf '%s' "${plain:0:$inner_w}"
    return
  fi
  local pad=$(( inner_w - len ))
  printf '%s%*s' "$content" "$pad" ''
}

# Usage: draw_box "BOX TITLE" "line 1" "line 2" ...
draw_box() {
  local title="$1"
  shift
  local inner_w=58

  printf '%b╔%*s╗%b\n' "$C_BORDER" "$inner_w" '' "$C_RESET" | tr ' ' '═'
  printf '%b║%b %b%-*s%b %b║%b\n' \
    "$C_BORDER" "$C_RESET" \
    "$C_BOLD$C_TITLE" "$((inner_w - 2))" "$title" "$C_RESET" \
    "$C_BORDER" "$C_RESET"
  printf '%b╠%*s╣%b\n' "$C_BORDER" "$inner_w" '' "$C_RESET" | tr ' ' '═'
  printf '%b║%*s║%b\n' "$C_BORDER" "$inner_w" '' "$C_RESET"

  local line padded
  for line in "$@"; do
    padded="$(_pad_line "$line" "$((inner_w - 2))")"
    printf '%b║%b %b%s%b %b║%b\n' \
      "$C_BORDER" "$C_RESET" \
      "$C_TEXT" "$padded" "$C_RESET" \
      "$C_BORDER" "$C_RESET"
  done

  printf '%b║%*s║%b\n' "$C_BORDER" "$inner_w" '' "$C_RESET"
  printf '%b╚%*s╝%b\n' "$C_BORDER" "$inner_w" '' "$C_RESET" | tr ' ' '═'
}

draw_banner() {
  local version="${1:-2.3.0}"
  draw_box "FEBREZEMC" \
    "${C_BOLD}${C_ACCENT} ███████╗███████╗██████╗ ██████╗ ███████╗${C_RESET}" \
    "${C_BOLD}${C_ACCENT} ██╔════╝██╔════╝██╔══██╗██╔══██╗╚══███╔╝${C_RESET}" \
    "${C_BOLD}${C_ACCENT} █████╗  █████╗  ██████╔╝██████╔╝  ███╔╝ ${C_RESET}" \
    "${C_BOLD}${C_ACCENT} ██╔══╝  ██╔══╝  ██╔══██╗██╔══██╗ ███╔╝  ${C_RESET}" \
    "${C_BOLD}${C_ACCENT} ██║     ███████╗██║  ██║██║  ██║███████╗${C_RESET}" \
    "${C_BOLD}${C_ACCENT} ╚═╝     ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝${C_RESET}" \
    "" \
    "                 ${C_BOLD}${C_TITLE}FEBREZEMC${C_RESET}" \
    "          ${C_MUTED}MINECRAFT SERVER INSTALLER${C_RESET}" \
    "                  ${C_KEY}Version ${version}${C_RESET}"
}

log_info() { printf '%b[INFO]%b %s\n' "$C_BOLD$C_INFO" "$C_RESET" "$1"; }
log_ok()   { printf '%b[ OK ]%b %s\n' "$C_BOLD$C_OK"   "$C_RESET" "$1"; }
log_warn() { printf '%b[WARN]%b %s\n' "$C_BOLD$C_WARN" "$C_RESET" "$1"; }
log_err()  { printf '%b[ERR ]%b %s\n' "$C_BOLD$C_ERR"  "$C_RESET" "$1"; }

# Real newline prompt helper (never outputs literal \n)
prompt_read() {
  local var_name="$1"
  local prompt_text="$2"
  local default_val="${3:-}"
  local reply

  printf '%b%s%b' "$C_BOLD$C_ACCENT" "$prompt_text" "$C_RESET"
  IFS= read -r reply

  if [[ -z "$reply" && -n "$default_val" ]]; then
    reply="$default_val"
  fi
  printf -v "$var_name" '%s' "$reply"
}

# --- Demo flow matching your screens ---
demo_flow() {
  draw_banner "2.3.0"
  printf '\n'
  printf '  %b[1]%b Create Minecraft Server\n' "$C_BOLD$C_KEY" "$C_RESET"
  printf '  %b[0]%b Exit\n\n' "$C_BOLD$C_KEY" "$C_RESET"
  prompt_read menu_choice "Select an option: " "1"

  draw_box "VPS INFORMATION" \
    "$(printf '%-15s %b%s%b' "OS"             "$C_BOLD" "Ubuntu 24.04.5 LTS" "$C_RESET")" \
    "$(printf '%-15s %b%s%b' "CPU"            "$C_BOLD" "4 vCPU"             "$C_RESET")" \
    "$(printf '%-15s %b%s%b' "RAM"            "$C_BOLD" "7 GB (7941 MB)"     "$C_RESET")" \
    "$(printf '%-15s %b%s%b' "RAM AVAILABLE"  "$C_BOLD$C_OK" "7 GB (7294 MB)" "$C_RESET")" \
    "$(printf '%-15s %b%s%b' "STORAGE"        "$C_BOLD" "90 GB free"         "$C_RESET")" \
    "$(printf '%-15s %b%s%b' "JAVA"           "$C_BOLD$C_ACCENT" "Java 25.0.5.1" "$C_RESET")" \
    "$(printf '%-15s %b%s%b' "ARCHITECTURE"   "$C_BOLD" "x86_64"             "$C_RESET")"

  log_info "Install location: /root/server"
  prompt_read confirm_dir "Continue? [Y/n]: " "Y"

  draw_box "SELECT SERVER SOFTWARE" \
    "${C_KEY}[1]${C_RESET} ${C_BOLD}Paper${C_RESET}    ${C_MUTED}-${C_RESET} Performance + Plugins" \
    "${C_KEY}[2]${C_RESET} ${C_BOLD}Purpur${C_RESET}   ${C_MUTED}-${C_RESET} Customization + Plugins" \
    "${C_KEY}[3]${C_RESET} ${C_BOLD}Vanilla${C_RESET}  ${C_MUTED}-${C_RESET} Official Minecraft" \
    "${C_KEY}[4]${C_RESET} ${C_BOLD}Forge${C_RESET}    ${C_MUTED}-${C_RESET} Modded Minecraft" \
    "${C_KEY}[5]${C_RESET} ${C_BOLD}Spigot${C_RESET}   ${C_MUTED}-${C_RESET} Plugin Support" \
    "${C_KEY}[6]${C_RESET} ${C_BOLD}Fabric${C_RESET}   ${C_MUTED}-${C_RESET} Lightweight Mods" \
    "" \
    "${C_KEY}[0]${C_RESET} Exit"
  prompt_read sw_choice "Select software [1-6, 0]: " "1"

  draw_box "SELECT MINECRAFT VERSION" \
    "Enter the Minecraft release you want to install." \
    "${C_MUTED}Example: 1.21.11${C_RESET}"
  prompt_read mc_ver "Minecraft version: " "26.3"
  log_info "Checking Minecraft version availability..."
  log_ok "Minecraft ${mc_ver} is available."
  log_info "Minecraft ${mc_ver} requires Java 25."

  draw_box "RAM CONFIGURATION" \
    "Total VPS RAM:       ${C_BOLD}7 GB${C_RESET}" \
    "Available RAM:       ${C_BOLD}${C_OK}7 GB${C_RESET}" \
    "Maximum safe choice: ${C_BOLD}${C_WARN}6 GB${C_RESET}" \
    "" \
    "${C_KEY}[1]${C_RESET} 1 GB" \
    "${C_KEY}[2]${C_RESET} 2 GB" \
    "${C_KEY}[3]${C_RESET} 3 GB" \
    "${C_KEY}[4]${C_RESET} 4 GB" \
    "${C_KEY}[5]${C_RESET} Custom amount"
  prompt_read ram_gb "Server RAM in GB [2]: " "2"

  draw_box "ACCOUNT AUTHENTICATION" \
    "Allow offline / cracked accounts?" \
    "" \
    "${C_KEY}[1]${C_RESET} ${C_WARN}YES${C_RESET}  - online-mode=false" \
    "${C_KEY}[2]${C_RESET} ${C_OK}NO${C_RESET}   - online-mode=true (recommended)" \
    "" \
    "${C_WARN}WARNING: Offline mode allows username${C_RESET}" \
    "${C_WARN}impersonation. It is unsafe for public servers.${C_RESET}"
  prompt_read auth_choice "Choose [1/2]: " "2"
  if [[ "$auth_choice" == "1" ]]; then
    log_warn "Offline mode allows username impersonation. It is unsafe for public servers."
  fi

  draw_box "NETWORK CONFIGURATION" \
    "Default Minecraft Java port: ${C_BOLD}25565${C_RESET}" \
    "${C_MUTED}Use this port unless you need a custom one.${C_RESET}"
  prompt_read mc_port "Server port [25565]: " "25565"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  demo_flow
fi
