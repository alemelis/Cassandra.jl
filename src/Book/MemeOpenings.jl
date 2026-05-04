const MEME_LINES = Dict{UInt64,String}()
const MEME_PRIORITY = Dict{UInt64,Int}()
const MEME_NAMES = Dict{UInt64,String}()

function _apply_moves(moves::Vector{String})
    board = Bobby.loadFen(Cassandra.START_FEN)
    for uci in moves
        m = Bobby.uciMoveToMove(board, uci)
        m === nothing && return nothing
        board = Bobby.makeMove(board, m)
    end
    return board
end

function _register_meme(moves::Vector{String}, response::String, name::String, priority::Int=0)
    b = _apply_moves(moves)
    b === nothing && return
    hash = b.hash
    if !haskey(MEME_PRIORITY, hash) || priority > MEME_PRIORITY[hash]
        MEME_LINES[hash] = response
        MEME_PRIORITY[hash] = priority
        MEME_NAMES[hash] = name
    end
end

function init_meme_openings!()
    empty!(MEME_LINES)
    empty!(MEME_PRIORITY)
    empty!(MEME_NAMES)

    # Higher priority = more likely to be played (trollier)
    # Priority 10: Ultimate memes
    _register_meme(String["e2e4", "e7e5"], "e1e2", "BongCloud Attack", 10)
    _register_meme(String["e2e4", "e7e5"], "e8e7", "BongCloud Defense", 10)

    # Priority 9: Very troll
    _register_meme(String["e2e4", "e7e5", "f1c4", "b8c6"], "d1h5", "Scholar's Mate Setup", 9)
    _register_meme(String["e2e4", "e7e5", "f1c4", "b8c6", "d1h5", "g8f6"], "h5f7", "Scholar's Mate", 9)

    # Priority 8: Crazy gambits
    _register_meme(String["e2e4", "e7e5", "g1f3", "b8c6", "b1c3", "g8f6"], "f3e5", "Halloween Gambit", 8)
    _register_meme(String["e2e4", "e7e5", "g1f3", "b8c6", "b1c3", "g8f6", "f3e5"], "f6e4", "Halloween Gambit (Black)", 8)
    _register_meme(String["d2d4"], "e7e5", "Englund Gambit", 8)
    _register_meme(String["e2e4"], "g7g5", "Borg Defense", 8)
    _register_meme(String["e2e4", "e7e5", "f2f4"], "e5f4", "From's Gambit", 8)

    # Priority 7: Aggressive openings
    _register_meme(String["e2e4", "e7e5"], "f2f4", "King's Gambit", 7)
    _register_meme(String["e2e4", "e7e5", "g1f3", "b8c6", "d2d4", "e5d4", "f3d4", "g8f6", "d4c6", "b7c6", "d1d5", "f6e4"], "d5f7", "Fried Liver Attack", 7)
    _register_meme(String["d2d4", "g8f6", "c2c4"], "e7e5", "Budapest Gambit", 7)
    _register_meme(String["e2e4", "c7c5", "d2d4", "c5d4"], "c2c3", "Smith-Morra Gambit", 7)

    # Priority 6: Surprise defenses
    _register_meme(String["e2e4", "e7e5", "g1f3"], "d7d5", "Elephant Gambit", 6)
    _register_meme(String["e2e4", "e7e5", "g1f3"], "f7f5", "Latvian Gambit", 6)
    _register_meme(String["e2e4"], "b8c6", "Nimzowitsch Defense", 6)
    _register_meme(String["e2e4", "a7a6", "d2d4"], "b7b5", "St. George Defense", 6)

    # Priority 5: More gambits
    _register_meme(String["e2e4", "e7e5", "d2d4", "e5d4"], "c2c3", "Danish Gambit", 5)
    _register_meme(String["d2d4", "d7d5", "b1c3", "g8f6"], "e2e4", "Blackmar-Diemer Gambit", 5)
    _register_meme(String["e2e4", "e7e5", "g1f3", "f7f5"], "e4f5", "Latvian Countergambit", 5)

    # Priority 4: Traxler/Frankenstein-Dracula
    _register_meme(String["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "g8f6"], "f3g5", "Traxler Setup", 4)
    _register_meme(String["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "g8f6", "f3g5"], "f8c5", "Traxler Counterattack", 4)
    _register_meme(String["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "g8f6", "f3g5", "d7d5", "e4d5"], "c6a5", "Frankenstein-Dracula Variation", 4)

    # Priority 3: Italian trap + Hippo
    _register_meme(String["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "f8c5", "d2d3", "g8f6", "b1c3"], "c6a5", "Italian Game Trap", 3)
    _register_meme(String["e2e4"], "d7d6", "Hippo Defense Setup", 3)
    _register_meme(String["e2e4", "d7d6", "d2d4"], "g8f6", "Hippo Defense", 3)
    _register_meme(String["e2e4", "d7d6", "d2d4", "g8f6", "b1c3"], "c7c6", "Hippo Defense", 3)
    _register_meme(String["e2e4", "d7d6", "d2d4", "g8f6", "b1c3", "c7c6"], "b8d7", "Hippo Defense", 3)

    # Priority 2: Englund complex
    _register_meme(String["d2d4", "e7e5", "d4e5", "b8c6", "g1f3"], "d8e7", "Englund Gambit Complex", 2)

    # Priority 1: Grob's Attack
    _register_meme(String[], "g2g4", "Grob's Attack", 1)

    # Priority 0: Modern meme
    _register_meme(String["e2e4", "g7g6", "d2d4", "f8g7", "b1c3", "g8f6"], "e4e5", "Modern Defense Meme", 0)

    @info "Loaded $(length(MEME_LINES)) meme opening positions"
end

function meme_move(board::Bobby.Board)::Tuple{Union{String,Nothing},Union{String,Nothing}}
    if haskey(MEME_LINES, board.hash)
        move_uci = MEME_LINES[board.hash]
        m = Bobby.uciMoveToMove(board, move_uci)
        if m !== nothing
            name = MEME_NAMES[board.hash]
            return (move_uci, name)
        else
            @warn "Meme move $move_uci not legal in position with hash $(board.hash)"
        end
    end
    return (nothing, nothing)
end
