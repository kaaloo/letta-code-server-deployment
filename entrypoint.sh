#!/bin/sh
set -eu

LETTA_USER="${LETTA_USER:-letta}"
LETTA_GROUP="${LETTA_GROUP:-letta}"
LETTA_UID="${LETTA_UID:-10001}"
LETTA_GID="${LETTA_GID:-10001}"
LETTA_HOME="${LETTA_HOME:-/home/letta}"

export HOME="$LETTA_HOME"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$LETTA_HOME/.config}"

if [ "${1:-}" = "letta-server" ]; then
  shift
  set -- letta server --env-name "${ENV_NAME:-cloud}" --debug "$@"
fi

# Inject memfs-autopush PostToolUse hook into settings.json if absent.
# Railway mounts /home as a persistent volume, so settings.json survives
# deploys — we only need to merge when the hook is missing.
_inject_memfs_hook() {
  _settings="$LETTA_HOME/.letta/settings.json"
  _hook_cmd="python3 $LETTA_HOME/.letta/hooks/memfs-autopush.py"
  if [ ! -f "$_settings" ]; then
    return
  fi
  # Check if the hook command already exists in any PostToolUse entry
  if python3 -c "
import json, sys
d = json.load(open('$_settings'))
for entry in d.get('hooks', {}).get('PostToolUse', []):
    for h in entry.get('hooks', []):
        if h.get('command') == '$_hook_cmd':
            sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
    return  # hook already present
  fi
  # Merge the hook config into settings.json
  python3 -c "
import json
s = json.load(open('$_settings'))
hooks = s.setdefault('hooks', {})
ptu = hooks.setdefault('PostToolUse', [])
ptu.append({
    'matcher': 'memory_str_replace|memory_insert|memory_delete|memory_rename|memory_replace_all|memory_rethink',
    'hooks': [{'type': 'command', 'command': '$_hook_cmd', 'timeout': 20000}]
})
json.dump(s, open('$_settings', 'w'), indent=2)
print('memfs-autopush hook injected into settings.json')
" 2>/dev/null || true
}

if [ "$(id -u)" = "0" ]; then
  mkdir -p "$LETTA_HOME/.letta" "$LETTA_HOME/.config" "$LETTA_HOME/Code"
  cp -an /etc/skel/. "$LETTA_HOME/" 2>/dev/null || true

  current_owner="$(stat -c '%u:%g' "$LETTA_HOME")"
  expected_owner="${LETTA_UID}:${LETTA_GID}"
  if [ "$current_owner" != "$expected_owner" ]; then
    chown -R "$LETTA_USER:$LETTA_GROUP" "$LETTA_HOME"
  else
    chown "$LETTA_USER:$LETTA_GROUP" "$LETTA_HOME/Code"
    chown -R "$LETTA_USER:$LETTA_GROUP" "$LETTA_HOME/.letta" "$LETTA_HOME/.config"
    find "$LETTA_HOME" -mindepth 1 -maxdepth 1 \
      ! -name Code ! -name .letta ! -name .config \
      -exec chown "$LETTA_USER:$LETTA_GROUP" {} +
  fi

  # Inject hook before dropping privileges so settings.json is writable.
  _inject_memfs_hook
  chown "$LETTA_USER:$LETTA_GROUP" "$LETTA_HOME/.letta/settings.json" 2>/dev/null || true

  exec setpriv --reuid "$LETTA_UID" --regid "$LETTA_GID" --init-groups "$@"
fi

exec "$@"
