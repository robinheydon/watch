zig build \
    --color off \
    -freference-trace=32 \
    --summary none \
    || exit 1

zig build run -- python3 slow.py
