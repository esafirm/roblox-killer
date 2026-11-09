#!/bin/bash
set -euo pipefail

if [[ $(uname -s) != Darwin ]]; then
    echo 'Roblox Killer requires macOS.' >&2
    exit 1
fi
if [[ $(id -u) == 0 ]]; then
    echo 'Run this as your normal login user, without sudo.' >&2
    exit 1
fi

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
label=local.roblox-killer
bin_dir="$HOME/.local/bin"
state_dir="$HOME/Library/Application Support/roblox-killer"
agent_dir="$HOME/Library/LaunchAgents"
plist="$agent_dir/$label.plist"
domain="gui/$(id -u)"

if ! launchctl print "$domain" >/dev/null 2>&1; then
    echo 'Log into the macOS desktop before installing.' >&2
    exit 1
fi
mkdir -p "$bin_dir" "$state_dir" "$agent_dir"
chmod 700 "$state_dir"

runtime=$(mktemp "$bin_dir/.roblox-killer.XXXXXX")
cat > "$runtime" <<'RUNTIME'
#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

label=local.roblox-killer
state_dir="$HOME/Library/Application Support/roblox-killer"
user_id=$(id -u)
domain="gui/$user_id"

is_enabled() {
    [[ ! -d "$state_dir/disabled" ]]
}

valid_telegram_config() {
    [[ $1 =~ ^[0-9]+:[A-Za-z0-9_-]+$ && $2 =~ ^-?[0-9]+$ ]]
}

telegram_setup() {
    local chat_id=${1:-${TELEGRAM_CHAT_ID:-}} token=${BOT_TOKEN:-} config_tmp
    if [[ -z "$chat_id" ]]; then
        echo 'Usage: roblox-killer telegram-setup CHAT_ID' >&2
        return 2
    fi
    if [[ -z "$token" ]]; then
        read -r -s -p 'Telegram bot token: ' token
        printf '\n'
    fi
    if ! valid_telegram_config "$token" "$chat_id"; then
        echo 'Invalid bot token or numeric chat ID.' >&2
        return 2
    fi
    chmod 700 "$state_dir"
    config_tmp=$(mktemp "$state_dir/.telegram.XXXXXX")
    printf '%s\n%s\n' "$token" "$chat_id" > "$config_tmp"
    chmod 600 "$config_tmp"
    mv -f "$config_tmp" "$state_dir/telegram.conf"
    echo "Telegram configured for chat $chat_id."
}

send_telegram() {
    local text=$1 token chat_id response
    [[ -f "$state_dir/telegram.conf" ]] || return 0
    if ! { IFS= read -r token; IFS= read -r chat_id; } < "$state_dir/telegram.conf" ||
        ! valid_telegram_config "$token" "$chat_id"; then
        echo 'Telegram configuration is invalid. Run telegram-setup again.' >&2
        return 1
    fi
    # Keep the token out of process arguments and ignore user curl configuration.
    if ! response=$(curl --disable --silent --fail --proto '=https' \
        --connect-timeout 5 --max-time 10 --config - \
        --data-urlencode "chat_id=$chat_id" --data-urlencode "text=$text" <<CURL_CONFIG
url = "https://api.telegram.org/bot$token/sendMessage"
CURL_CONFIG
    ); then
        echo 'Telegram report failed (network or API error).' >&2
        return 1
    fi
    if [[ $(printf '%s' "$response" | plutil -extract ok raw -o - - 2>/dev/null) != true ]]; then
        echo 'Telegram did not confirm the report.' >&2
        return 1
    fi
}

block_player() {
    is_enabled || return 0
    # Exact executable name deliberately excludes RobloxStudio and RobloxStudioBeta.
    if pkill -KILL -u "$user_id" -x RobloxPlayer 2>/dev/null; then
        date '+%Y-%m-%d %H:%M:%S %z' > "$state_dir/last-blocked"
        printf '%s RobloxPlayer killed\n' "$(cat "$state_dir/last-blocked")"
        if [[ -f "$state_dir/telegram.conf" ]]; then
            # shortcut: best-effort delivery without retries; add a queue if offline delivery is needed.
            send_telegram "Roblox Killer: Roblox Player detected and killed.
Mac: $(hostname)
Time: $(cat "$state_dir/last-blocked")
Roblox Studio is not targeted." &
        fi
        # A stalled notification must not delay blocking or spawn more notifiers.
        if [[ -z "${notification_pid:-}" ]] || ! kill -0 "$notification_pid" 2>/dev/null; then
            osascript -e 'display notification "Roblox was launched and has been closed." with title "Roblox Killer"' >/dev/null 2>&1 &
            notification_pid=$!
        fi
    fi
}

status() {
    if is_enabled; then
        echo 'Blocking: on'
    else
        echo 'Blocking: off'
    fi
    if launchctl print "$domain/$label" >/dev/null 2>&1; then
        echo 'Agent: loaded'
    else
        echo 'Agent: not loaded (run the installer again)'
    fi
    if pgrep -u "$user_id" -x RobloxPlayer >/dev/null 2>&1; then
        echo 'Roblox Player: running'
    else
        echo 'Roblox Player: not running'
    fi
    if [[ -f "$state_dir/last-blocked" ]]; then
        printf 'Last blocked: %s\n' "$(cat "$state_dir/last-blocked")"
    else
        echo 'Last blocked: never'
    fi
    if [[ -f "$state_dir/telegram.conf" ]]; then
        echo 'Telegram: configured'
    else
        echo 'Telegram: not configured'
    fi
}

main() {
    mkdir -p "$state_dir"
    case "${1:-status}" in
        on)
            if [[ -d "$state_dir/disabled" ]]; then
                rmdir "$state_dir/disabled"
            fi
            echo 'Blocking: on'
            ;;
        off)
            mkdir -p "$state_dir/disabled"
            echo 'Blocking: off'
            ;;
        toggle)
            if is_enabled; then main off; else main on; fi
            ;;
        status) status ;;
        telegram-setup) telegram_setup "${2:-}" ;;
        telegram-test)
            if [[ ! -f "$state_dir/telegram.conf" ]]; then
                echo 'Run telegram-setup CHAT_ID first.' >&2
                return 1
            fi
            send_telegram "TEST REPORT: Roblox Killer on $(hostname).
Telegram delivery test only. No application was launched or killed." || return 1
            echo 'Telegram test report sent.'
            ;;
        daemon)
            trap 'exit 0' TERM INT
            while true; do
                block_player
                sleep 1
            done
            ;;
        *)
            echo 'Usage: roblox-killer [on|off|toggle|status|telegram-setup CHAT_ID|telegram-test]' >&2
            return 2
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
RUNTIME
chmod 700 "$runtime"
mv -f "$runtime" "$bin_dir/roblox-killer"

if [[ -n "${BOT_TOKEN:-}" || -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    if [[ -z "${BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
        echo 'Set both BOT_TOKEN and TELEGRAM_CHAT_ID to configure Telegram during installation.' >&2
        exit 1
    fi
    "$bin_dir/roblox-killer" telegram-setup "$TELEGRAM_CHAT_ID"
fi

xml_escape() {
    local value=$1
    value=${value//&/\&amp;}
    value=${value//</\&lt;}
    value=${value//>/\&gt;}
    value=${value//\"/\&quot;}
    value=${value//\'/\&apos;}
    printf '%s' "$value"
}

agent_tmp=$(mktemp "$agent_dir/.roblox-killer.XXXXXX")
cat > "$agent_tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$label</string>
    <key>ProgramArguments</key>
    <array><string>$(xml_escape "$bin_dir/roblox-killer")</string><string>daemon</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>StandardOutPath</key><string>$(xml_escape "$state_dir/agent.log")</string>
    <key>StandardErrorPath</key><string>$(xml_escape "$state_dir/agent-error.log")</string>
</dict>
</plist>
PLIST
plutil -lint "$agent_tmp" >/dev/null
chmod 600 "$agent_tmp"
mv -f "$agent_tmp" "$plist"

launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
launchctl enable "$domain/$label"
launchctl bootstrap "$domain" "$plist"

echo 'Installed. Starts automatically at login. Existing on/off setting preserved.'
printf 'Control command: %q [on|off|toggle|status]\n' "$bin_dir/roblox-killer"
"$bin_dir/roblox-killer" status
