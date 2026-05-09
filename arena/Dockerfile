FROM julia:1.12

RUN apt-get update && apt-get install -y --no-install-recommends \
        git stockfish python3 python3-pip \
    && pip3 install --no-cache-dir --break-system-packages python-chess \
    && rm -rf /var/lib/apt/lists/*

COPY Bobby.jl/ /Bobby.jl/

WORKDIR /app

COPY Cassandra.jl/Project.toml Cassandra.jl/Manifest.toml ./
RUN julia -e 'using Pkg; Pkg.activate("/app"); Pkg.develop(PackageSpec(path="/Bobby.jl")); Pkg.instantiate()'

COPY Cassandra.jl/src/ src/
RUN julia --project=. -e 'using Cassandra'

COPY Cassandra.jl/bot/ bot/
COPY Cassandra.jl/arena/ arena/
