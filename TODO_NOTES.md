- Pack assets and data in output executables ?
    - Only data and `minecraft/lang` in servers
    - Everything included in client
    - Make it unpack itself
        - In tmp or cwd ?
    - Compressed or just tar ?
    - Maybe giving a separate folder OR the resource fetcher directly
        could be a good soluion
- Serial
    - SNBT interfaces
- Finding a better http library
    - `std.http` kinda trash
    - httpx-zig doesn't offer streaming
    - Make one myself ?
- Command parser and handler
- TUI
    - Separate console input/outputs. Kinda like:
        ╭─────────────────╮╭─────────────────╮╭──────────────────────────────────╮
        │ current scope   ││ show scope tree ││ ...                              │
        ╞═════════════════╧╧═════════════════╧╡ old command 9                    │
        │                                     │ old command 8                    │
        │                                     │ old command 7                    │
        │                                     │ old command 6                    │
        │                                     │ old command 5                    │
        │                                     │ old command 4                    │
        │                                     │ old command 3                    │
        │                                     │ old command 2                    │
        │                                     │ old command 1                    │
        │                                     │ old command 0                    │
        ├─────────────────────────────────────┴──────────────────────────────────┤
        │ input section                                                          │
        ╰────────────────────────────────────────────────────────────────────────╯
    - Can be substituted with `zig build run &> /dev/pts/X > /dev/ptr/X`. The exact path can be obtained by opening a new terminal and typing `clear && tty && tee`