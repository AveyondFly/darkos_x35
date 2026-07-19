#!/bin/bash

CARD=0

# Prefer extcon HEADPHONE state when available (more reliable than dmesg).
extcon_state=""
for s in /sys/class/extcon/extcon*/state; do
  [ -f "$s" ] || continue
  if grep -q '^HEADPHONE=' "$s" 2>/dev/null; then
    extcon_state="$(awk -F= '/^HEADPHONE=/{print $2; exit}' "$s")"
    break
  fi
done

if [ -n "${extcon_state}" ]; then
  if [ "${extcon_state}" = "1" ]; then
    amixer -c "$CARD" -q set 'Playback Path' 'HP'
  else
    amixer -c "$CARD" -q set 'Playback Path' 'SPK'
  fi
  exit 0
fi

# Fallback: last headset status line from dmesg
if [[ "$(dmesg | grep 'headset status is ' | tail -1)" == *"headset status is in"* ]]; then
    amixer -c "$CARD" -q set 'Playback Path' 'HP'
else
    amixer -c "$CARD" -q set 'Playback Path' 'SPK'
fi
