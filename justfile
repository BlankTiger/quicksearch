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
        "zig-out/bin/quicksearch-bench tests/artifact.txt 'bibendum' first_simd" \
        "zig-out/bin/quicksearch-bench tests/artifact.txt 'bibendum' all_simd" \
        "rg --threads 1 --vimgrep 'bibendum' tests/artifact.txt" \

flamegraph:
    rm ./flamegraph.svg
    rm ./perf.data*
    perf record -g zig-out/bin/quicksearch-bench tests/artifact.txt 'bibendum' all_simd
    perf script | inferno-collapse-perf | inferno-flamegraph > flamegraph.svg
