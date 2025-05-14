default:
    @just --list

test:
    zig build test --summary all

run:
    zig build run

bench:
    zig build bench --summary all
