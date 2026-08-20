#!/bin/bash
# Lock the status-line CGM layout, or go back to rotating through them.
F="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/style"
case "$1" in
  1h|2h|3h|2line|none|rotate) echo "$1" > "$F"; echo "style: $1" ;;
  status|"") echo "style: $(cat "$F" 2>/dev/null || echo rotate)" ;;
  *) echo "usage: cgm-style.sh [1h|2h|3h|2line|none|rotate|status]"; exit 1 ;;
esac
