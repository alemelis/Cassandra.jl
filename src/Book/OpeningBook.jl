const _BOOK = Dict{String,Float32}()

function load_opening_book(path::String)
    isfile(path) || return
    open(path) do io
        for line in eachline(io)
            isempty(line) && continue
            fen, score = split(line, ";")
            _BOOK[strip(fen)] = parse(Float32, strip(score))
        end
    end
end

function book_score(fen::String)::Float32
    get(_BOOK, fen, 0f0)
end