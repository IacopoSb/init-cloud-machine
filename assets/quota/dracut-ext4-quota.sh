#!/bin/sh
# Hook dracut pre-mount: abilita la project quota sul root ext4 (smontato).
# Bulletproof: non deve MAI bloccare il boot (exit 0 sempre).
rootspec=""
if type getarg >/dev/null 2>&1; then
  rootspec="$(getarg root=)"
fi

dev=""
case "$rootspec" in
  /dev/*)  dev="$rootspec" ;;
  UUID=*)  dev="/dev/disk/by-uuid/${rootspec#UUID=}" ;;
  LABEL=*) dev="/dev/disk/by-label/${rootspec#LABEL=}" ;;
esac

# Fallback via blkid se il symlink non è ancora pronto.
if [ ! -b "$dev" ] && command -v blkid >/dev/null 2>&1; then
  case "$rootspec" in
    UUID=*)  dev="$(blkid -U "${rootspec#UUID=}" 2>/dev/null)" ;;
    LABEL=*) dev="$(blkid -L "${rootspec#LABEL=}" 2>/dev/null)" ;;
  esac
fi

if [ -b "$dev" ] && command -v tune2fs >/dev/null 2>&1; then
  tune2fs -O quota,project -Q prjquota "$dev" >/dev/null 2>&1 || true
fi
exit 0
