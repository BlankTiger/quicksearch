default:
    @just --list

test:
    zig build test --summary all

run:
    zig build run

bench:
    zig build -Doptimize=ReleaseFast
    hyperfine --warmup 3 --runs 10 --prepare 'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches' \
        "rg 'bibendum' tests/artifact.txt" \
        "zig-out/bin/quicksearch-bench tests/artifact.txt 'bibendum' all_linear" \
        "zig-out/bin/quicksearch-bench tests/artifact.txt 'bibendum' all_simd" \
        "zig-out/bin/quicksearch-bench tests/artifact.txt 'bibendum' first_linear" \
        "zig-out/bin/quicksearch-bench tests/artifact.txt 'bibendum' first_simd"

bench-debug:
    zig build
    hyperfine --warmup 3 --runs 10 --prepare 'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches' \
        "zig-out/bin/quicksearch-bench tests/artifact.txt 'habitasse' all_linear" \
        "zig-out/bin/quicksearch-bench tests/artifact.txt 'habitasse' all_simd" \
        "zig-out/bin/quicksearch-bench tests/artifact.txt 'habitasse' first_linear" \
        "zig-out/bin/quicksearch-bench tests/artifact.txt 'habitasse' first_simd"
