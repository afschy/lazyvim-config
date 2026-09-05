#!/usr/bin/env bash
# Tear down every remote-ssh.nvim connection and erase its traces, so the next
# nvim starts as if no remote host had ever been contacted.
set -uo pipefail

BACKUP_DIR="${TMPDIR:-/tmp}/remote-reset-$(date +%Y%m%d-%H%M%S)"
SOCKET_DIR="$HOME/.ssh/sockets"
SHARE="${XDG_DATA_HOME:-$HOME/.local/share}/nvim"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/nvim"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/nvim"

FORCE=0
DRY=0
for arg in "$@"; do
  case "$arg" in
    -f|--force) FORCE=1 ;;
    -n|--dry-run) DRY=1 ;;
    -h|--help)
      echo "usage: ${0##*/} [-n|--dry-run] [-f|--force]"
      echo "  -n  show what would be removed, change nothing"
      echo "  -f  proceed even if nvim is running"
      exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }

if pgrep -x nvim >/dev/null 2>&1 && [ "$FORCE" -eq 0 ]; then
  say "nvim is running; it would rewrite this state on exit."
  say "Quit it first, or pass --force."
  exit 1
fi

[ "$DRY" -eq 1 ] && say "DRY RUN - nothing will be changed"

# ---------------------------------------------------------------- connections

step "Closing SSH connections"

hosts=()
if [ -r "$HOME/.ssh/config" ]; then
  while read -r _ names; do
    for h in $names; do
      [ "$h" = "*" ] || hosts+=("$h")
    done
  done < <(grep -iE '^[[:space:]]*Host[[:space:]]' "$HOME/.ssh/config")
fi

for h in "${hosts[@]}"; do
  if [ "$DRY" -eq 1 ]; then
    ssh -O check "$h" >/dev/null 2>&1 && say "  would close master: $h"
  else
    ssh -O exit "$h" >/dev/null 2>&1 && say "  closed master: $h"
  fi
done

# Orphaned ssh from a dead nvim: multiplex clients holding our sockets, and
# plugin-spawned channels naming a configured host. pgrep -x avoids self-match.
pattern="$SOCKET_DIR"
for h in "${hosts[@]}"; do pattern="$pattern|[[:space:]]$h\$|[[:space:]]$h[[:space:]]"; done

leftover=$(pgrep -x ssh 2>/dev/null | while read -r pid; do
  cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
  printf '%s\t%s\n' "$pid" "$cmd" | grep -qE "$pattern" && printf '%s\t%s\n' "$pid" "${cmd:0:90}"
done)

if [ -n "$leftover" ]; then
  while IFS=$'\t' read -r pid cmd; do
    if [ "$DRY" -eq 1 ]; then
      say "  would kill $pid: $cmd"
    else
      kill "$pid" 2>/dev/null && say "  killed $pid: $cmd"
    fi
  done <<< "$leftover"
  [ "$DRY" -eq 0 ] && sleep 1
  # Anything still holding on after TERM
  [ "$DRY" -eq 0 ] && while IFS=$'\t' read -r pid _; do
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null && say "  force-killed $pid"
  done <<< "$leftover"
else
  say "  no stray ssh processes"
fi

n=$(find "$SOCKET_DIR" -mindepth 1 2>/dev/null | wc -l)
if [ "$n" -gt 0 ]; then
  [ "$DRY" -eq 1 ] && say "  would remove $n control socket(s)" \
                   || { find "$SOCKET_DIR" -mindepth 1 -delete 2>/dev/null; say "  removed $n control socket(s)"; }
else
  say "  no control sockets"
fi

# ---------------------------------------------------------------- stored data

step "Removing stored data"

[ "$DRY" -eq 0 ] && mkdir -p "$BACKUP_DIR"

drop() {
  [ -e "$1" ] || return 0
  local size; size=$(du -sh "$1" 2>/dev/null | cut -f1)
  if [ "$DRY" -eq 1 ]; then
    say "  would remove $1 ($size)"
  else
    cp -a "$1" "$BACKUP_DIR/" 2>/dev/null
    rm -rf "$1" && say "  removed $1 ($size)"
  fi
}

drop "$SHARE/remote-ssh-sessions.json"
drop "$SHARE/remote-ssh"
drop "$CACHE/remote-ssh"
drop "$CACHE/remote_lsp_logs"

# Swap files for rsync:// and scp:// buffers
while IFS= read -r f; do
  [ "$DRY" -eq 1 ] && say "  would remove swap $(basename "$f")" \
                   || { cp -a "$f" "$BACKUP_DIR/" 2>/dev/null; rm -f "$f"; say "  removed swap $(basename "$f")"; }
done < <(find "$STATE/swap" -maxdepth 1 \( -name 'rsync:*' -o -name 'scp:*' \) 2>/dev/null)

# Saved sessions whose name encodes a remote path
while IFS= read -r f; do
  [ "$DRY" -eq 1 ] && say "  would remove session $(basename "$f")" \
                   || { cp -a "$f" "$BACKUP_DIR/" 2>/dev/null; rm -f "$f"; say "  removed session $(basename "$f")"; }
done < <(find "$STATE/sessions" -maxdepth 1 -type f \( -name '*rsync*' -o -name '*scp*' -o -name '*sshfs*' \) 2>/dev/null)

if [ -s "$STATE/lsp.log" ]; then
  size=$(du -sh "$STATE/lsp.log" | cut -f1)
  [ "$DRY" -eq 1 ] && say "  would truncate lsp.log ($size)" \
                   || { : > "$STATE/lsp.log"; say "  truncated lsp.log ($size)"; }
fi

# ------------------------------------------------------------------- frecency

FRECENCY="$SHARE/snacks/picker-frecency.sqlite3"
if [ -f "$FRECENCY" ] && command -v sqlite3 >/dev/null 2>&1; then
  q="key LIKE '%rsync://%' OR key LIKE '%scp://%' OR key LIKE '%sshfs%'"
  rows=$(sqlite3 "$FRECENCY" "SELECT count(*) FROM data WHERE $q;" 2>/dev/null)
  if [ "${rows:-0}" -gt 0 ]; then
    if [ "$DRY" -eq 1 ]; then
      say "  would remove $rows frecency row(s)"
    else
      cp -a "$FRECENCY" "$BACKUP_DIR/" 2>/dev/null
      sqlite3 "$FRECENCY" "DELETE FROM data WHERE $q;" && say "  removed $rows frecency row(s)"
    fi
  fi
fi

# ---------------------------------------------------------------------- shada

step "Filtering ShaDa"

SHADA="$STATE/shada/main.shada"
if [ ! -f "$SHADA" ]; then
  say "  no shada file"
elif ! command -v nvim >/dev/null 2>&1; then
  say "  nvim not found, skipped"
else
  before=$(strings "$SHADA" 2>/dev/null | grep -cE 'rsync://|scp://')
  if [ "$before" -eq 0 ]; then
    say "  already clean"
  elif [ "$DRY" -eq 1 ]; then
    say "  would remove $before remote reference(s)"
  else
    cp -a "$SHADA" "$BACKUP_DIR/main.shada.orig"
    filter=$(mktemp "${TMPDIR:-/tmp}/shada_filter.XXXXXX.lua")
    cat > "$filter" <<'LUA'
-- Entries are framed as three msgpack uints (type, timestamp, length) then
-- `length` payload bytes; decode() rejects trailing data, so headers are manual.
local path = vim.g.shada_path
local fh = assert(io.open(path, "rb"))
local data = fh:read("*a")
fh:close()

local pos = 1
local function uint()
  local b = data:byte(pos)
  if not b then return nil end
  if b <= 0x7f then pos = pos + 1 return b end
  local n = ({ [0xcc] = 1, [0xcd] = 2, [0xce] = 4, [0xcf] = 8 })[b]
  if not n then error(("unexpected byte 0x%02x at %d"):format(b, pos)) end
  local v = 0
  for i = 1, n do v = v * 256 + data:byte(pos + i) end
  pos = pos + 1 + n
  return v
end

local function remote(s)
  return type(s) == "string" and (s:match("^rsync://") or s:match("^scp://")) ~= nil
end

local function anywhere(v, depth)
  if depth > 6 then return false end
  if remote(v) then return true end
  if type(v) == "table" then
    for k, x in pairs(v) do
      if remote(k) or anywhere(x, depth + 1) then return true end
    end
  end
  return false
end

local out, dropped = {}, 0
while pos <= #data do
  local start = pos
  local etype, ts, len = uint(), uint(), uint()
  if not (etype and ts and len) then break end
  local payload = data:sub(pos, pos + len - 1)
  pos = pos + len
  local raw = data:sub(start, pos - 1)

  local ok, val = pcall(vim.mpack.decode, payload)
  local drop = false

  if ok and etype == 9 and type(val) == "table" then
    -- buffer list: an array of maps; drop only the remote members
    local keep = {}
    for _, buf in ipairs(val) do
      if not anywhere(buf, 0) then keep[#keep + 1] = buf end
    end
    if #keep == 0 then
      drop = true
    elseif #keep < #val then
      local body = vim.mpack.encode(keep)
      raw = vim.mpack.encode(etype) .. vim.mpack.encode(ts) .. vim.mpack.encode(#body) .. body
    end
  elseif ok and anywhere(val, 0) then
    drop = true
  end

  if drop then dropped = dropped + 1 else out[#out + 1] = raw end
end

local wf = assert(io.open(path, "wb"))
wf:write(table.concat(out))
wf:close()
io.stderr:write(("  removed %d remote entr%s\n"):format(dropped, dropped == 1 and "y" or "ies"))
LUA
    nvim --headless -u NONE -i NONE \
      -c "lua vim.g.shada_path = '$SHADA'" \
      -c "luafile $filter" -c 'qa!' 2>&1 | grep -v '^$'
    rm -f "$filter"

    after=$(strings "$SHADA" 2>/dev/null | grep -cE 'rsync://|scp://')
    if [ "$after" -gt 0 ]; then
      say "  WARNING: $after reference(s) still present; original at $BACKUP_DIR/main.shada.orig"
    fi
  fi
fi

# ---------------------------------------------------------------------- check

step "Result"
shada_refs=0
[ -f "$SHADA" ] && shada_refs=$(strings "$SHADA" 2>/dev/null | grep -cE 'rsync://|scp://')

say "  control sockets:  $(find "$SOCKET_DIR" -mindepth 1 2>/dev/null | wc -l)"
say "  ssh processes:    $(pgrep -xc ssh 2>/dev/null)"
say "  remote swap:      $(find "$STATE/swap" -maxdepth 1 \( -name 'rsync:*' -o -name 'scp:*' \) 2>/dev/null | wc -l)"
say "  shada references: $shada_refs"

if [ "$DRY" -eq 0 ] && [ -d "$BACKUP_DIR" ] && [ -n "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
  say ""
  say "Backup: $BACKUP_DIR"
fi
