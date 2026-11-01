# Bare Blocks
A minecraft server... or client idk.

I am apparently to undecisive whether to do a server or client, for now it is a server implementation
though there IS a start of client implementation (src/main_client.zig) but ye, I'll just keep everything
within this single repo, even silly demos for now. Anything useful really.

# The Goal
I'd like it to be fully vanilla complient/has full vanilla parity (java).

Will prob take some time.

Also be a somewhat serious project but seeing so many different r\*st (ew) minecraft server implementations
popping up everywhere (PumpkinMC, SteelMC, and others idk) kinda discourages me 'cause they have so many things
done RAAAAH.

# TODO
  - [ ] Networking
    - [x] Compression
    - [x] Encryption
    - [ ] Transfers
    - [ ] Legacy server listing
      - Not planned
    - [x] Handshake
      - [x] Serverbound
      - [x] Clientbound (technically none)
    - [x] Status
      - [x] Serverbound
      - [x] Clientbound
    - [x] Login
      - [x] Serverbound
      - [x] Clientbound
    - [ ] Configuration
      - [ ] Serverbound
      - [ ] Clientbound
    - [ ] Play
      - [ ] Serverbound
      - [ ] Clientbound
  - [ ] Game Logic
    - [x] Registries (Only the in-memory layout is figured, but they'll be filled during dev)
    - [ ] Chat
    - [ ] Commands
    - [ ] Entities
    - [ ] Threaded world
    - [ ] Per-players worlds
      - [ ] Per-player world borders
    - [ ] World generation
        - [ ] Overworld
        - [ ] Nether
        - [ ] The End
  - [ ] Modding/plugin support
    - [ ] Wasm, lua, custom or smth
  - [ ] Utilities
    - [ ] Custom implementation for encryption (openssl works well, just for the statically linking haven)
    - [ ] TUI for dedicated servers
    - [ ] Custom (de)serialisation (like for storing worlds and stuff)

# Contributing and issues
If you want to participate in this ambitious project, you can try to file a PR as issues would be kinda useless. I am expecting a somewhat decent quality from PR's. You can look at the repo's content to see how I organise files, code and such.