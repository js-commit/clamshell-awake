#!/bin/zsh
# One-time: let this user flip `pmset disablesleep` without a password.
# Only the two exact commands below are allowed; asks for your password once.
set -euo pipefail
if [[ $EUID -eq 0 ]]; then
  echo "Run this without sudo; it prompts for your password itself." >&2
  echo "Under sudo the rule would be written for root, not for you." >&2
  exit 1
fi
user="${1:-$USER}"
tmp="$(mktemp)"
cat > "$tmp" <<SUDOERS
# ClamshellAwake: passwordless toggle of the lid-closed sleep override
$user ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
SUDOERS
sudo visudo -cf "$tmp"
sudo install -o root -g wheel -m 0440 "$tmp" /etc/sudoers.d/clamshell-awake
rm -f "$tmp"

# Verify. Drop the credential the commands above just cached, so `sudo -n` can
# only succeed through the new rule (the app never has that cached ticket).
# The rule is exact-argv, so pass nothing but 0 or 1.
sudo -k
cur="$(pmset -g | awk '/SleepDisabled/ {print $2}')"
[[ "$cur" == 0 || "$cur" == 1 ]] || cur=0
if sudo -n /usr/bin/pmset -a disablesleep "$cur"; then
  echo "OK: /etc/sudoers.d/clamshell-awake installed, passwordless pmset works"
else
  echo "FAIL: rule installed for '$user', but passwordless pmset does not work for $USER" >&2
  exit 1
fi
