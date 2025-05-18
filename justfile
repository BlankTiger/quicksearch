default:
    @just --list

test:
    zig build test --summary all

run:
    zig build run

bench:
    zig build -Doptimize=ReleaseFast
    sudo -v
    hyperfine --runs 10 --prepare 'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches' \
        "zig-out/bin/quicksearch-bench ../artifact.txt 'bibendum' simd" \
        "rg --threads 1 --vimgrep 'bibendum' ../artifact.txt" \

flamegraph:
    rm ./flamegraph.svg || true
    rm ./perf.data* || true
    zig build
    perf record -g zig-out/bin/quicksearch-bench ../artifact.txt 'bibendum' simd
    perf script | inferno-collapse-perf | inferno-flamegraph > flamegraph.svg

callgrind:
    zig build
    valgrind --tool=callgrind zig-out/bin/quicksearch-bench ../artifact.txt 'bibendum' simd
    kcachegrind callgrind.out.*

cachegrind:
    zig build
    valgrind --tool=cachegrind --cache-sim=yes --branch-sim=yes zig-out/bin/quicksearch-bench ../artifact.txt 'bibendum' simd
    kcachegrind cachegrind.out.*

perf-cache:
    rm ./perf.data* || true
    zig build
    perf record -e cache-misses,cache-references,branch-misses,cycles zig-out/bin/quicksearch-bench ../artifact.txt 'bibendum' simd
    perf report
