#!/bin/bash
# Claude Code status line: folder · branch · CGM (+ optional sparkline).
# Reads session JSON on stdin. The CGM data and its PRE-RENDERED sparklines come
# from ~/.claude/cgm.json, written by the poller. NO network, no rendering work
# happens here - this script runs on every message and must stay fast.

input=$(cat)

DIR=$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // ""')
[ -n "$DIR" ] || DIR=$PWD

BRANCH=$(git -C "$DIR" symbolic-ref --quiet --short HEAD 2>/dev/null) \
  || BRANCH=$(git -C "$DIR" rev-parse --short HEAD 2>/dev/null)

line="\033[36m${DIR##*/}\033[0m"
[ -n "$BRANCH" ] && line="$line \033[2m·\033[0m \033[35m⎇ $BRANCH\033[0m"

# ---- CGM segment -----------------------------------------------------------
CGM_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CGM_CACHE="$CGM_DIR/cgm.json"
CGM_STYLE_FILE="$CGM_DIR/style"
CGM_UNITS=${CGM_UNITS:-mgdl}          # mgdl | mmol
CGM_STALE_S=${CGM_STALE_S:-900}       # dim + label the reading after this long
CGM_DEAD_S=${CGM_DEAD_S:-3600}        # past this, refuse to show a number
CGM_ROTATE_S=${CGM_ROTATE_S:-60}      # seconds per style while rotating

line2=""

if [ -f "$CGM_CACHE" ]; then
  IFS=$'\t' read -r mgdl mmol arrow epoch s1h s2h s3h < <(
    jq -r '[(.value_mgdl // ""), (.value_mmol // ""), (.trend_arrow // "?"),
            (.epoch // 0), (.spark."1h" // ""), (.spark."2h" // ""),
            (.spark."3h" // "")] | @tsv' "$CGM_CACHE" 2>/dev/null
  )
  if [ -n "$mgdl" ] && [ "${epoch:-0}" -gt 0 ]; then
    age=$(( $(date +%s) - epoch ))
    mins=$(( age / 60 ))
    rtime=$(date -r "$epoch" +%H:%M)
    if [ "$mins" -lt 60 ]; then
      agestr="${mins}m"
    else
      agestr="$(( mins / 60 ))h$(printf '%02d' $(( mins % 60 )))m"
    fi

    # Which layout? A locked style wins; otherwise rotate on a clock so the
    # choice is deterministic rather than tied to how often Claude redraws.
    style=$(cat "$CGM_STYLE_FILE" 2>/dev/null || echo rotate)
    tag=""
    if [ "$style" = rotate ]; then
      STYLES=(none 1h 2h 3h 2line)
      style=${STYLES[$(( ($(date +%s) / CGM_ROTATE_S) % ${#STYLES[@]} ))]}
      tag=" \033[2m[$style]\033[0m"      # so you know what you are looking at
    fi

    case "$style" in
      1h)    spark="$s1h" ;;
      2h)    spark="$s2h" ;;
      3h)    spark="$s3h" ;;
      2line) spark=""; line2="$s3h \033[2m3h\033[0m" ;;
      *)     spark="" ;;
    esac

    if [ "$age" -gt "$CGM_DEAD_S" ]; then
      # Never show a number this old - a stale value is worse than no value.
      seg="\033[2m⚕ no data · last ${rtime} (${agestr})\033[0m"
      line2=""
    else
      if [ "$CGM_UNITS" = mgdl ]; then val="$mgdl"; else val="$mmol"; fi
      if   [ "$mgdl" -lt 55  ]; then c=$'\033[1;97;41m'
      elif [ "$mgdl" -lt 70  ]; then c=$'\033[1;31m'
      elif [ "$mgdl" -gt 250 ]; then c=$'\033[1;33m'
      elif [ "$mgdl" -gt 180 ]; then c=$'\033[33m'
      else                           c=$'\033[32m'
      fi
      if [ "$age" -gt "$CGM_STALE_S" ]; then
        seg="\033[2m⚕ ${val} ${arrow}${spark:+ $spark} ${rtime} (${agestr})\033[0m"
      else
        seg="${c}⚕ ${val} ${arrow}\033[0m${spark:+ $spark} \033[2m${rtime} (${agestr})\033[0m"
      fi
    fi
    line="$line \033[2m·\033[0m ${seg}${tag}"
  fi
fi

printf "$line\n"
# Note the explicit exit: a bare `[ -n "$line2" ] && printf ...` makes the
# script exit 1 whenever there is no second line.
if [ -n "$line2" ]; then printf "$line2\n"; fi
exit 0
