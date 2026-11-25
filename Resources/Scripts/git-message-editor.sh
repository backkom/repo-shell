#!/bin/sh
if [ -f "$REPOSHELL_MESSAGE_PATH" ]; then
  cat "$REPOSHELL_MESSAGE_PATH" > "$1"
fi
