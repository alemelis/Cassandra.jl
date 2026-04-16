using BenchmarkTools
using Cassandra

const SUITE = BenchmarkGroup()

SUITE["eval"] = BenchmarkGroup()
SUITE["search"] = BenchmarkGroup()
