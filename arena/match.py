#!/usr/bin/env python3
"""
Run a fixed-game match: Cassandra (UCI) vs Stockfish (strength-limited).
Appends one JSON line to $LOGS_DIR/arena_log.jsonl on completion.

Usage (env vars):
  STOCKFISH_ELO   target Elo for Stockfish  (default: 1500)
  GAMES           number of games           (default: 100)
  MOVE_TIME       seconds per move          (default: 1.0)
  SETUPS_DIR      directory with setup JSON files (default: /data/setups)
  LOGS_DIR        output directory          (default: /data/logs)
"""

import chess
import chess.engine
import chess.pgn
import json
import math
import os
import random
import sys
from datetime import date, datetime, timezone
from pathlib import Path

# ── Config ────────────────────────────────────────────────────────────────────

STOCKFISH_ELO   = int(os.environ.get("STOCKFISH_ELO", 1500))
GAMES           = int(os.environ.get("GAMES", 100))
MOVE_TIME       = float(os.environ.get("MOVE_TIME", 1.0))
SETUPS_DIR      = Path(os.environ.get("SETUPS_DIR", "/data/setups"))
LOGS_DIR        = Path(os.environ.get("LOGS_DIR", "/data/logs"))
PGN_DIR         = LOGS_DIR / "arena_pgn"


def _setup_name() -> str:
    """Return the name of the currently deployed setup, or 'unknown'."""
    try:
        with open(SETUPS_DIR / "deployed.json") as f:
            d = json.load(f)
        return d.get("name", "unknown")
    except Exception:
        return "unknown"

# Short opening lines to avoid playing identical games.
# Each entry is a list of UCI moves from the start position.
OPENINGS = [
    [],                                    # no book move
    ["e2e4"],
    ["d2d4"],
    ["e2e4", "e7e5"],
    ["e2e4", "c7c5"],
    ["e2e4", "e7e6"],
    ["d2d4", "d7d5"],
    ["d2d4", "g8f6"],
    ["c2c4"],
    ["g1f3"],
]

# ── Elo math ──────────────────────────────────────────────────────────────────

def elo_diff(score: float, games: int) -> tuple[float | None, float | None]:
    """Return (diff, error) given a score in [0, 1], or (None, None) if undefined."""
    if score <= 0 or score >= 1:
        return None, None
    diff = -400 * math.log10(1 / score - 1)
    stderr_score = math.sqrt(score * (1 - score) / games)
    error = 400 / math.log(10) / (score * (1 - score)) * stderr_score
    return round(diff, 1), round(error, 1)

# ── Match ─────────────────────────────────────────────────────────────────────

def run_match():
    PGN_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
    pgn_path = PGN_DIR / f"{stamp}_sf{STOCKFISH_ELO}.pgn"

    setup_name = _setup_name()
    cassandra_cmd = ["julia", "--project=/app", "/app/bot/uci.jl"]

    print(f"Opening engines (setup: {setup_name}) …", flush=True)
    # Julia startup + Cassandra precompile can take 30-60s on first run.
    cassandra = chess.engine.SimpleEngine.popen_uci(cassandra_cmd, timeout=120)
    stockfish = chess.engine.SimpleEngine.popen_uci("/usr/games/stockfish")
    stockfish.configure({
        "UCI_LimitStrength": True,
        "UCI_Elo": STOCKFISH_ELO,
    })

    limit = chess.engine.Limit(time=MOVE_TIME)
    wins = draws = losses = 0

    with open(pgn_path, "w") as pgn_file:
        for game_num in range(1, GAMES + 1):
            # Alternate colours; Cassandra is White in odd games
            cassandra_is_white = (game_num % 2 == 1)
            opening = random.choice(OPENINGS)

            board = chess.Board()
            game = chess.pgn.Game()
            game.headers["Event"]  = f"Arena sf{STOCKFISH_ELO}"
            game.headers["White"]  = "Cassandra" if cassandra_is_white else f"SF{STOCKFISH_ELO}"
            game.headers["Black"]  = f"SF{STOCKFISH_ELO}" if cassandra_is_white else "Cassandra"
            game.headers["Date"]   = date.today().isoformat()
            node = game

            # Replay opening into board and game tree so they stay in sync.
            forfeit = None
            for uci in opening:
                move = chess.Move.from_uci(uci)
                board.push(move)
                node = node.add_variation(move)

            while not board.is_game_over(claim_draw=True):
                is_cassandra_turn = (board.turn == chess.WHITE) == cassandra_is_white
                engine = cassandra if is_cassandra_turn else stockfish
                result = engine.play(board, limit)
                if not board.is_legal(result.move):
                    forfeit = "cassandra" if is_cassandra_turn else "stockfish"
                    print(f"  illegal move {result.move} by {forfeit}, forfeit", flush=True)
                    break
                board.push(result.move)
                node = node.add_variation(result.move)

            if forfeit == "cassandra":
                outcome_winner = chess.BLACK if cassandra_is_white else chess.WHITE
                game.headers["Result"] = "0-1" if cassandra_is_white else "1-0"
            else:
                outcome = board.outcome(claim_draw=True)
                outcome_winner = outcome.winner if outcome else None
                game.headers["Result"] = board.result(claim_draw=True)

            try:
                print(game, file=pgn_file, end="\n\n")
            except Exception as e:
                print(f"  PGN write error (non-fatal): {e}", flush=True)

            if outcome_winner is None:
                draws += 1
            elif (outcome_winner == chess.WHITE) == cassandra_is_white:
                wins += 1
            else:
                losses += 1

            score = (wins + 0.5 * draws) / game_num
            print(f"  [{game_num:3d}/{GAMES}] W={wins} D={draws} L={losses}  "
                  f"score={score:.3f}", flush=True)

    cassandra.quit()
    stockfish.quit()

    total = wins + draws + losses
    score = (wins + 0.5 * draws) / total
    diff, err = elo_diff(score, total)

    today = date.today()
    record = {
        "date":         today.isoformat(),
        "year":         today.year,
        "month":        today.month,
        "day":          today.day,
        "model":        setup_name,
        "opponent":     f"stockfish-{STOCKFISH_ELO}",
        "opponent_elo": STOCKFISH_ELO,
        "sf_strength":  STOCKFISH_ELO,
        "tc":           MOVE_TIME,
        "games":        total,
        "wins":         wins,
        "draws":        draws,
        "losses":       losses,
        "score":        round(score, 4),
        "elo_diff":     diff,
        "elo_err":      err,
        "cassandra_elo": round(STOCKFISH_ELO + diff, 1) if diff is not None else None,
        "pgn":          pgn_path.name,
    }

    log_path = LOGS_DIR / "arena_log.jsonl"
    LOGS_DIR.mkdir(parents=True, exist_ok=True)
    with open(log_path, "a") as f:
        f.write(json.dumps(record) + "\n")

    if diff is not None:
        print(f"\nResult: {wins}W {draws}D {losses}L  score={score:.3f}  "
              f"Elo diff={diff:+.0f} ±{err:.0f}  "
              f"→ Cassandra ≈ {STOCKFISH_ELO + diff:.0f}", flush=True)
    else:
        print(f"\nResult: {wins}W {draws}D {losses}L  score={score:.3f}  "
              f"Elo diff=N/A (score is 0 or 1)", flush=True)
    print(f"PGN: {pgn_path}", flush=True)
    print(f"Log: {log_path}", flush=True)


if __name__ == "__main__":
    run_match()
