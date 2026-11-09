import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


INSTALLER = Path(__file__).resolve().parents[1] / "install.sh"
SOURCE = INSTALLER.read_text()
RUNTIME = SOURCE.split("<<'RUNTIME'\n", 1)[1].split("\nRUNTIME\n", 1)[0]


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="roblox-killer-test-")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.runtime = self.home / "runtime.sh"
        self.runtime.write_text(RUNTIME)

    def run_script(self, script):
        # Functions override external commands even though the runtime fixes PATH.
        prelude = '''
source "$RUNTIME_PATH"
pkill() { printf 'kill:%s\\n' "$*" >> "$HOME/calls"; return "${KILL_RESULT:-0}"; }
pgrep() { return 1; }
osascript() { echo notify >> "$HOME/calls"; return "${NOTIFY_RESULT:-0}"; }
launchctl() { return "${AGENT_RESULT:-0}"; }
curl() {
    printf '%s\\n' "$@" >> "$HOME/telegram-args"
    cat > "$HOME/telegram-request"
    printf '%s' "${TELEGRAM_RESPONSE:-}"
    if [[ -z "${TELEGRAM_RESPONSE:-}" ]]; then printf '{"ok":true}'; fi
    return "${CURL_RESULT:-0}"
}
'''
        return subprocess.run(
            ["/bin/bash", "-c", prelude + script + "\nwait"],
            env={**os.environ, "HOME": str(self.home), "RUNTIME_PATH": str(self.runtime)},
            text=True, capture_output=True, check=True,
        ).stdout

    def test_default_and_persistent_toggle(self):
        self.assertIn("Blocking: on", self.run_script("main status"))
        self.run_script("main off; main off")
        self.assertIn("Blocking: off", self.run_script("main status"))
        self.run_script("main toggle")
        self.assertIn("Blocking: on", self.run_script("main status"))
        self.run_script("main on; main on; main toggle")
        self.assertIn("Blocking: off", self.run_script("main status"))

    def test_successful_kill_notifies_and_records_timestamp(self):
        output = self.run_script("main on; block_player; main status")
        self.assertEqual((self.home / "calls").read_text(),
                         f"kill:-KILL -u {os.getuid()} -x RobloxPlayer\nnotify\n")
        self.assertIn("RobloxPlayer killed", output)
        self.assertNotIn("Last blocked: never", output)

    def test_disabled_does_not_kill_or_notify(self):
        self.run_script("main off; block_player")
        self.assertFalse((self.home / "calls").exists())

    def test_failed_kill_does_not_notify(self):
        output = self.run_script("main on; KILL_RESULT=1; block_player; main status")
        self.assertEqual((self.home / "calls").read_text(),
                         f"kill:-KILL -u {os.getuid()} -x RobloxPlayer\n")
        self.assertIn("Last blocked: never", output)

    def test_notification_failure_does_not_stop_blocking(self):
        self.run_script("main on; NOTIFY_RESULT=1; block_player; wait; block_player")
        self.assertEqual((self.home / "calls").read_text().count("notify"), 2)

    def test_pending_notification_does_not_stop_blocking_or_spawn_another(self):
        self.run_script("main on; kill() { return 0; }; block_player; block_player")
        calls = (self.home / "calls").read_text()
        self.assertEqual(calls.count("kill:"), 2)
        self.assertEqual(calls.count("notify"), 1)

    def test_status_when_player_is_running(self):
        output = self.run_script("pgrep() { return 0; }; main status")
        self.assertIn("Roblox Player: running", output)

    def test_agent_not_loaded(self):
        self.assertIn("Agent: not loaded", self.run_script("AGENT_RESULT=1; main status"))

    def setup_telegram(self):
        self.run_script('BOT_TOKEN="123456:fake_token"; main telegram-setup -100123456')

    def test_telegram_setup_keeps_token_private(self):
        self.setup_telegram()
        config = self.home / "Library/Application Support/roblox-killer/telegram.conf"
        self.assertEqual(config.read_text(), "123456:fake_token\n-100123456\n")
        self.assertEqual(config.stat().st_mode & 0o777, 0o600)
        self.assertIn("Telegram: configured", self.run_script("main status"))

    def test_telegram_setup_rejects_invalid_values(self):
        self.run_script('BOT_TOKEN="not-a-token"; if main telegram-setup -100123; then exit 1; fi')
        self.run_script('BOT_TOKEN="123456:fake_token"; if main telegram-setup \'bad"chat\'; then exit 1; fi')
        self.assertFalse((self.home / "Library/Application Support/roblox-killer/telegram.conf").exists())

    def test_telegram_test_requires_setup(self):
        self.run_script('if main telegram-test; then exit 1; fi')
        self.assertFalse((self.home / "telegram-args").exists())

    def test_telegram_report_uses_config_stdin_not_token_in_args(self):
        self.setup_telegram()
        output = self.run_script("main telegram-test")
        args = (self.home / "telegram-args").read_text()
        self.assertIn("TEST REPORT", args)
        self.assertIn("chat_id=-100123456", args)
        self.assertIn("--max-time\n10", args)
        self.assertNotIn("fake_token", args)
        self.assertIn("bot123456:fake_token/sendMessage", (self.home / "telegram-request").read_text())
        self.assertIn("Telegram test report sent", output)
        self.assertFalse((self.home / "calls").exists())

    def test_successful_kill_sends_telegram_event(self):
        self.setup_telegram()
        self.run_script("block_player")
        args = (self.home / "telegram-args").read_text()
        self.assertIn("Roblox Player detected and killed", args)
        self.assertIn("Mac:", args)
        self.assertIn("Time:", args)

    def test_disabled_and_failed_kills_do_not_report(self):
        self.setup_telegram()
        self.run_script("main off; block_player; main on; KILL_RESULT=1; block_player")
        self.assertFalse((self.home / "telegram-args").exists())

    def test_telegram_network_failure_does_not_stop_blocking(self):
        self.setup_telegram()
        output = self.run_script("CURL_RESULT=22; block_player; wait; block_player; wait; echo alive")
        self.assertIn("alive", output)
        self.assertEqual((self.home / "calls").read_text().count("kill:"), 2)

    def test_telegram_api_rejection_is_not_reported_as_success(self):
        self.setup_telegram()
        self.run_script('TELEGRAM_RESPONSE=\'{"ok":false}\'; if main telegram-test; then exit 1; fi')

    def test_telegram_network_failure_is_not_reported_as_success(self):
        self.setup_telegram()
        output = self.run_script('CURL_RESULT=22; if main telegram-test; then exit 1; fi')
        self.assertNotIn("Telegram test report sent", output)

    def test_corrupt_telegram_config_is_not_sent(self):
        self.setup_telegram()
        config = self.home / "Library/Application Support/roblox-killer/telegram.conf"
        config.write_text('bad"token\n-100123\n')
        self.run_script('if main telegram-test; then exit 1; fi')
        self.assertFalse((self.home / "telegram-args").exists())

    def test_invalid_command(self):
        output = self.run_script('if main invalid; then exit 1; else echo "exit:$?"; fi')
        self.assertIn("exit:2", output)

    @unittest.skipUnless(sys.platform == "darwin", "installer requires macOS plutil")
    def test_install_and_reinstall_with_special_characters_in_home(self):
        home = self.home / "Home & <test> 'quoted'"
        home.mkdir()
        env = {**os.environ, "HOME": str(home), "INSTALLER": str(INSTALLER),
               "BOT_TOKEN": "123456:fake_token", "TELEGRAM_CHAT_ID": "-100123456"}
        script = '''
set -e
launchctl() { printf '%s\\n' "$*" >> "$HOME/launchctl-calls"; }
export -f launchctl
/bin/bash "$INSTALLER"
"$HOME/.local/bin/roblox-killer" off
unset BOT_TOKEN TELEGRAM_CHAT_ID
/bin/bash "$INSTALLER"
"$HOME/.local/bin/roblox-killer" status
'''
        result = subprocess.run(["/bin/bash", "-c", script], env=env,
                                text=True, capture_output=True, check=True)
        self.assertIn("Blocking: off", result.stdout.split("Installed.")[-1])
        self.assertIn("Telegram: configured", result.stdout.split("Installed.")[-1])
        self.assertNotIn("fake_token", result.stdout + result.stderr)
        telegram_config = home / "Library/Application Support/roblox-killer/telegram.conf"
        self.assertEqual(telegram_config.stat().st_mode & 0o777, 0o600)
        self.assertEqual(telegram_config.read_text(), "123456:fake_token\n-100123456\n")
        agent = home / "Library/LaunchAgents/local.roblox-killer.plist"
        config = plistlib.loads(agent.read_bytes())
        executable = home / ".local/bin/roblox-killer"
        self.assertEqual(config["ProgramArguments"], [str(executable), "daemon"])
        self.assertTrue(config["KeepAlive"])
        self.assertTrue(config["RunAtLoad"])
        self.assertEqual(executable.stat().st_mode & 0o777, 0o700)
        calls = (home / "launchctl-calls").read_text()
        self.assertEqual(calls.count("bootstrap "), 2)


if __name__ == "__main__":
    unittest.main()
