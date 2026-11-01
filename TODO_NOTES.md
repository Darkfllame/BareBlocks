- Pack assets and data in output executables ?
    - Make it download it instead, less legal bullshit
- Serial
    - SNBT interfaces
- Finding a better http library
    - `std.http` kinda trash
    - httpx-zig doesn't offer streaming
    - Make one myself ?
- Command parser and handler
- TUI
    - Separate console input/outputs. Kinda like:
    ```
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
    ```
    - Can be substituted with `zig build run &> /dev/pts/X > /dev/ptr/X`. The exact path can be obtained by opening a new  and typing `clear && tty && tee`
- Block states
    - So as explained in `src/core/block/state.zig`, the vanilla game pre-computes and stores all possible block-states for each and every single blocks. This is higly ineficient in my opinion, a better solution would be to lazily and dynamically create/store and delete them as the game runs. Obviously because not every block states will be used at once in the game (maybe mods would change that, like a recipe viewer or such).
    - Gotta implement a block-state cache along with weak references.