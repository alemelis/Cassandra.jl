#!/usr/bin/env bash
# Quick 4-game smoke test against Stockfish 1500.
# Run from repo root: docker compose --profile arena run --rm -e GAMES=4 -e MOVE_TIME=0.1 arena
set -e
exec python3 /app/arena/match.py
