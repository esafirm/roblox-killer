# Roblox Killer for macOS

A per-user launch agent that kills **Roblox Player**, leaves **Roblox Studio** alone, and sends a macOS notification after a successful kill. No dependencies, admin privileges, or developer tools required.

## Install

Run in Terminal while logged into the macOS desktop:

```sh
curl -fsSL https://raw.githubusercontent.com/esafirm/roblox-killer/main/install.sh | /bin/bash
```

Only run installers from a source you trust. To inspect it first, download `install.sh`, read it, then run `/bin/bash install.sh`.

Installation starts blocking immediately and registers automatic startup at login. Reinstalling updates the files and preserves your on/off setting. Do not use `sudo`.

## Control

```sh
~/.local/bin/roblox-killer status
~/.local/bin/roblox-killer off
~/.local/bin/roblox-killer on
~/.local/bin/roblox-killer toggle
```

If `~/.local/bin` is on your `PATH`, you can use just `roblox-killer`. On/off persists across restarts. Status reports the saved setting, whether the agent is loaded, whether the player is running, and the last successful block.

## Behavior and limits

- Checks once per second. Roblox may appear briefly before being force-quit. There is no graceful shutdown or save prompt.
- Matches the exact process name `RobloxPlayer`, not a window title or a substring. Studio processes are not targeted. If Roblox changes its executable name, the matcher needs updating.
- Runs only for the installing user, while they are logged in. This is a voluntary blocker, not tamper-proof parental control. Other accounts and renamed executables are not blocked.
- Notifications use macOS `osascript`. Allow notifications for the sending application (typically Script Editor) if prompted. Focus modes and system permissions may hide them. Blocking still works if notifications fail.
- An `off` command cannot undo a kill already in progress.
- Logs and the last-blocked timestamp live in `~/Library/Application Support/roblox-killer/`. Logs are not automatically rotated.

## Uninstall

First disable blocking and unload the agent:

```sh
~/.local/bin/roblox-killer off
launchctl bootout "gui/$(id -u)/local.roblox-killer"
```

Then move these items to Trash using Finder (Go → Go to Folder):

- `~/Library/LaunchAgents/local.roblox-killer.plist`
- `~/.local/bin/roblox-killer`
- `~/Library/Application Support/roblox-killer`

## Checks

```sh
/bin/bash -n install.sh
python3 -B -m unittest discover -s tests -v
```

Tests use isolated temporary directories and stub process control and notifications. They do not install a real agent or kill any applications.
