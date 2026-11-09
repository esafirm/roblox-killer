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

block_player() {
    is_enabled || return 0
    # Exact executable name deliberately excludes RobloxStudio and RobloxStudioBeta.
    if pkill -KILL -u "$user_id" -x RobloxPlayer 2>/dev/null; then
        date '+%Y-%m-%d %H:%M:%S %z' > "$state_dir/last-blocked"
        printf '%s RobloxPlayer killed\n' "$(cat "$state_dir/last-blocked")"
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
        daemon)
            trap 'exit 0' TERM INT
            while true; do
                block_player
                sleep 1
            done
            ;;
        *)
            echo 'Usage: roblox-killer [on|off|toggle|status]' >&2
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
