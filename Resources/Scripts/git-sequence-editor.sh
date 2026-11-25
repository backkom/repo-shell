#!/bin/sh
if [ -f "$REPOSHELL_SEQUENCE_PATH" ]; then
  cp "$REPOSHELL_SEQUENCE_PATH" "$1"
fi
