"""
    PolyglotBook

Reader for Polyglot opening books (`.bin` format, the de-facto standard since
Fruit). Loads a binary file into memory, hashes positions with the canonical
781-constant Polyglot Zobrist table, and probes by binary search.

Probe samples a move with the *chaos transform*:

    w_eff_i = (weight_i + 1) ^ (1 - chaos)

`chaos=0` → standard weight-proportional; `chaos=1` → uniform across entries.

The book is consulted only at the root of `select_move`, never inside the
search tree — so polyglot's Zobrist hash is recomputed on demand rather than
maintained incrementally alongside Bobby's engine-local hash.
"""
module PolyglotBook

using Bobby
using Random

# The polyglot table is loaded from a separate file (it's ~25 KB of hex).
include("polyglot_random.jl")
@assert length(POLYGLOT_RANDOM) == 781 "polyglot random table must be 781 UInt64"

# ── On-disk entry ────────────────────────────────────────────────────────────
# 16 bytes, big-endian on disk. We materialize as a native struct of host
# integers after byteswap, so hot-path lookups don't pay ntoh.
struct Entry
    key::UInt64
    move::UInt16
    weight::UInt16
    learn::UInt32
end

const ENTRIES = Entry[]
const LOADED_PATH = Ref{String}("")

enabled() = !isempty(ENTRIES)
loaded_path() = LOADED_PATH[]

# ── Load ─────────────────────────────────────────────────────────────────────

"""
    load!(path) -> Int

Read a polyglot `.bin` from `path` into the in-memory `ENTRIES` table.
Returns the number of entries loaded. Empties the table first.

Filters out weight=0 entries (book builders use 0 as a "marked for deletion"
sentinel; keeping them around skews chaos sampling toward dead lines).
"""
function load!(path::AbstractString)::Int
    empty!(ENTRIES)
    LOADED_PATH[] = ""
    isempty(path) && return 0
    isfile(path)  || (@warn "[polyglot] file not found" path; return 0)

    raw = read(path)
    n_bytes = length(raw)
    n_bytes % 16 == 0 ||
        (@warn "[polyglot] file size not a multiple of 16; truncating" path size=n_bytes;
         n_bytes -= n_bytes % 16)
    n_entries = n_bytes ÷ 16

    sizehint!(ENTRIES, n_entries)
    skipped = 0
    @inbounds for i in 0:(n_entries - 1)
        off = 16 * i + 1
        key    = ntoh(reinterpret(UInt64, raw[off       : off + 7])[1])
        move   = ntoh(reinterpret(UInt16, raw[off + 8   : off + 9])[1])
        weight = ntoh(reinterpret(UInt16, raw[off + 10  : off + 11])[1])
        learn  = ntoh(reinterpret(UInt32, raw[off + 12  : off + 15])[1])
        if weight == 0
            skipped += 1
            continue
        end
        push!(ENTRIES, Entry(key, move, weight, learn))
    end

    # Defensive: spec says entries are sorted by key, but books in the wild
    # occasionally aren't. Resort if needed (cheap when already sorted).
    if !issorted(ENTRIES; by = e -> e.key)
        sort!(ENTRIES; by = e -> e.key)
    end

    LOADED_PATH[] = String(path)
    mib = round(sizeof(Entry) * length(ENTRIES) / 1024^2, digits=1)
    @info "[polyglot] loaded" path entries=length(ENTRIES) skipped_zero_weight=skipped size_MiB=mib
    return length(ENTRIES)
end

# ── Polyglot Zobrist hash ────────────────────────────────────────────────────
#
# Bobby's square indexing: `trailing_zeros(sq)` where 0=h1, 7=a1, 56=h8, 63=a8.
# Polyglot's square indexing: file + 8*rank, with file 0=a, rank 0=rank-1, so
# 0=a1, 7=h1, 56=a8, 63=h8. The conversion is `file = 7 - (tz % 8)`,
# `rank = tz ÷ 8`, polyglot_sq = file + 8*rank.

@inline _poly_sq(tz::Int) = (7 - (tz & 7)) + 8 * (tz >> 3)

# Polyglot piece index ordering: BP=0, WP=1, BN=2, WN=3, ..., BK=10, WK=11.
# Bobby piece types: pawn=1 .. king=6. For color (white=true): kind = 2*(t-1)+1; for black: kind = 2*(t-1).
@inline _poly_piece_idx(piece_type::Integer, white::Bool) =
    2 * (Int(piece_type) - 1) + (white ? 1 : 0)

@inline function _xor_bitboard!(h::UInt64, bb::UInt64, piece_type::Integer, white::Bool)
    base = 64 * _poly_piece_idx(piece_type, white)
    b = bb
    while b != 0
        tz = trailing_zeros(b)
        @inbounds h ⊻= POLYGLOT_RANDOM[base + _poly_sq(tz) + 1]   # +1: Julia 1-based
        b &= b - 1
    end
    return h
end

"""
    polyglot_hash(board::Bobby.Board) -> UInt64

The canonical polyglot Zobrist hash of `board`. Recomputed from scratch on
every call — cheap (~40 XORs), and only ever called at the search root.
"""
function polyglot_hash(board::Bobby.Board)::UInt64
    h = UInt64(0)
    # Pieces — white
    w = board.white
    h = _xor_bitboard!(h, w.P, Bobby.PIECE_PAWN,   true)
    h = _xor_bitboard!(h, w.N, Bobby.PIECE_KNIGHT, true)
    h = _xor_bitboard!(h, w.B, Bobby.PIECE_BISHOP, true)
    h = _xor_bitboard!(h, w.R, Bobby.PIECE_ROOK,   true)
    h = _xor_bitboard!(h, w.Q, Bobby.PIECE_QUEEN,  true)
    h = _xor_bitboard!(h, w.K, Bobby.PIECE_KING,   true)
    # Pieces — black
    b = board.black
    h = _xor_bitboard!(h, b.P, Bobby.PIECE_PAWN,   false)
    h = _xor_bitboard!(h, b.N, Bobby.PIECE_KNIGHT, false)
    h = _xor_bitboard!(h, b.B, Bobby.PIECE_BISHOP, false)
    h = _xor_bitboard!(h, b.R, Bobby.PIECE_ROOK,   false)
    h = _xor_bitboard!(h, b.Q, Bobby.PIECE_QUEEN,  false)
    h = _xor_bitboard!(h, b.K, Bobby.PIECE_KING,   false)

    # Castling: CK=8 (WK), CQ=4 (WQ), Ck=2 (BK), Cq=1 (BQ)
    c = board.castling
    (c & Bobby.CK) != 0 && (h ⊻= @inbounds POLYGLOT_RANDOM[769])  # 768+1
    (c & Bobby.CQ) != 0 && (h ⊻= @inbounds POLYGLOT_RANDOM[770])
    (c & Bobby.Ck) != 0 && (h ⊻= @inbounds POLYGLOT_RANDOM[771])
    (c & Bobby.Cq) != 0 && (h ⊻= @inbounds POLYGLOT_RANDOM[772])

    # En passant — only hashed if a friendly pawn can actually capture
    # (regardless of whether the capture would itself be legal).
    if board.enpassant != Bobby.EMPTY
        ep_tz = trailing_zeros(board.enpassant)
        ep_file = 7 - (ep_tz & 7)                  # 0=a … 7=h
        # The captured pawn sits one rank toward the side-to-move from the ep target.
        # The capturing pawns sit *on the same rank as the captured pawn*, on adjacent files.
        # For white-to-move: ep target is on rank 6, captured black pawn on rank 5,
        # capturing white pawns on rank 5 at files ep_file±1.
        if board.active   # white to move
            # captured pawn at ep_target shifted down 8 bits (toward rank 1)
            cap_sq_tz = ep_tz - 8
        else
            cap_sq_tz = ep_tz + 8
        end
        # Adjacent squares to the captured pawn (same rank, file±1).
        # Bobby tz: increasing tz = decreasing file along a rank? Let's check:
        # tz=0=h1 (file 7), tz=1=g1 (file 6), ..., tz=7=a1 (file 0). So +1 in tz = file-1.
        # Adjacent files in tz space: cap_sq_tz - 1 (right neighbor file+1) and cap_sq_tz + 1 (file-1).
        # Guard against wrapping at file edges.
        cap_file = 7 - (cap_sq_tz & 7)
        left_tz  = cap_sq_tz + 1   # file - 1
        right_tz = cap_sq_tz - 1   # file + 1
        friends_pawns = board.active ? board.white.P : board.black.P
        has_capturer = false
        if cap_file > 0
            has_capturer |= (friends_pawns & (UInt64(1) << left_tz))  != 0
        end
        if cap_file < 7
            has_capturer |= (friends_pawns & (UInt64(1) << right_tz)) != 0
        end
        has_capturer && (h ⊻= @inbounds POLYGLOT_RANDOM[773 + ep_file])  # 772+file+1
    end

    # Side to move — XOR if WHITE to move
    board.active && (h ⊻= @inbounds POLYGLOT_RANDOM[781])  # 780+1
    return h
end

# ── Binary search ────────────────────────────────────────────────────────────

# Returns the index of the first entry with key ≥ `key`, or length+1 if none.
function _lower_bound(entries::Vector{Entry}, key::UInt64)::Int
    lo, hi = 1, length(entries) + 1
    @inbounds while lo < hi
        mid = (lo + hi) >> 1
        if entries[mid].key < key
            lo = mid + 1
        else
            hi = mid
        end
    end
    return lo
end

# ── Move decoding ────────────────────────────────────────────────────────────

# Polyglot move bits: bits 0-2 = to_file, 3-5 = to_rank, 6-8 = from_file,
# 9-11 = from_rank, 12-14 = promotion (0=none, 1=N, 2=B, 3=R, 4=Q).
const _PROMO_CHARS = ("", "n", "b", "r", "q")

# Convert a polyglot (file, rank) — both 0-indexed, file 0=a, rank 0=rank-1 —
# to standard UCI coords ("e4" etc.).
@inline _sq_to_uci(file::Int, rank::Int) = string(Char('a' + file), Char('1' + rank))

"""
    decode_move(entry, board) -> String

Decode a polyglot move integer to a UCI string, with castling fix-up.
Polyglot encodes castling as king→rook-square (Chess960 convention);
standard UCI is king→destination, so e1h1 → e1g1, e1a1 → e1c1, etc.
"""
function decode_move(entry::Entry, board::Bobby.Board)::String
    m = entry.move
    to_file   = Int(m       & 0x7)
    to_rank   = Int((m >> 3) & 0x7)
    from_file = Int((m >> 6) & 0x7)
    from_rank = Int((m >> 9) & 0x7)
    promo     = Int((m >> 12) & 0x7)

    # Detect castling: king on its home square, "to" square is the matching
    # rook home square. In standard chess, this means from=e1/e8 to a/h on the same rank.
    is_white_castle = (from_file == 4 && from_rank == 0 && (to_file == 0 || to_file == 7) && to_rank == 0)
    is_black_castle = (from_file == 4 && from_rank == 7 && (to_file == 0 || to_file == 7) && to_rank == 7)

    if (is_white_castle || is_black_castle)
        # Verify the moving piece is actually a king before rewriting (avoids
        # mangling a rook capture on a-/h-file from king's home square — rare,
        # but possible in obscure positions). King bitboard check via sq mask.
        king_bb = is_white_castle ? board.white.K : board.black.K
        king_tz = (8 * from_rank) + (7 - from_file)  # inverse of _poly_sq
        if (king_bb >> king_tz) & UInt64(1) != 0
            new_to_file = (to_file == 7) ? 6 : 2   # h-file → g-file (kingside), a-file → c-file (queenside)
            to_file = new_to_file
        end
    end

    return string(_sq_to_uci(from_file, from_rank),
                  _sq_to_uci(to_file,   to_rank),
                  _PROMO_CHARS[promo + 1])
end

# ── Probe ────────────────────────────────────────────────────────────────────

# Move-count count from board.fullmove + side: plies = (fullmove - 1) * 2 + (board.active ? 0 : 1)
@inline _ply(board::Bobby.Board) = (board.fullmove - 1) * 2 + (board.active ? 0 : 1)

"""
    probe(board, cfg::BookConfig; rng=Random.GLOBAL_RNG) -> Union{String,Nothing}

Probe the loaded book for `board`. Returns a UCI move string on hit,
`nothing` on miss (or when `cfg.enabled=false`, the book is empty, or the
position is past `cfg.max_ply`). Sampling honors `cfg.chaos`.
"""
function probe(board::Bobby.Board, cfg; rng = Random.GLOBAL_RNG)::Union{String,Nothing}
    cfg.enabled || return nothing
    isempty(ENTRIES) && return nothing
    _ply(board) >= cfg.max_ply && return nothing

    key = polyglot_hash(board)
    idx = _lower_bound(ENTRIES, key)
    idx > length(ENTRIES) && return nothing
    @inbounds ENTRIES[idx].key == key || return nothing

    # Collect the contiguous run of entries with this key (small, usually < 10).
    last_idx = idx
    @inbounds while last_idx <= length(ENTRIES) && ENTRIES[last_idx].key == key
        last_idx += 1
    end
    last_idx -= 1

    # Chaos-weighted sampling. `c=0` → standard weighted random;
    # `c=1` → uniform. Closed-form: w_eff_i = (weight+1) ^ (1 - c).
    c = clamp(Float64(cfg.chaos), 0.0, 1.0)
    exponent = 1.0 - c
    total = 0.0
    @inbounds for i in idx:last_idx
        total += (Float64(ENTRIES[i].weight) + 1.0) ^ exponent
    end
    total > 0 || return nothing

    r = rand(rng) * total
    cum = 0.0
    chosen = idx
    @inbounds for i in idx:last_idx
        cum += (Float64(ENTRIES[i].weight) + 1.0) ^ exponent
        if r <= cum
            chosen = i
            break
        end
    end

    @inbounds return decode_move(ENTRIES[chosen], board)
end

end # module PolyglotBook
