# Coroutines
Attempt at implementing [coroutines](https://wikipedia.org/wiki/Coroutine) in Zig.

Currently only available for Linux and x86_64 architecture.

## How to use
Run this command in your zig project folder:
```
zig fetch --save git+https://github.com/Darkfllame/coroutines
```

This will add the `master` branch to your zig project's dependencies,
you can then use it in your `build.zig.zon` file with:
```zig
const coro_mod = b.dependencies("coroutines", .{
    .target = target,
    .optimize = optimize,
}).module("coroutines");

<...>

module.addImport("coro", coro_mod);
```

Then use it in your project like:
```zig
const coro = @import("coro");

var a_coroutine: coro.Coroutine(void) = undefined;
// Yes, This is a method so it needs to be called like this.
try a_coroutine.init(.{
    .stack_size = 1 * 1024 * 1024, // usize | default value: 1 MiB,
    .max_sleep_time = 10 * std.time.ns_per_us, // ?u96 | default value: 10 µs (micro-seconds)
}, myCoroutine, .{
    // no arguments
});
// here 'ret' will be be a transformed type from the
// original function return type:
// void -> bool
// T -> ?T
// E!void -> E!bool
// E!T -> E!?T
// null/false value means the coroutine didn't return yet and should continue
// to live on or be canceled with Coroutine(T).await(.await/.cancel).
const ret = a_coroutine.@"resume"(); // can also be .resumeRaw() to not modify return type.
// when the function terminates, the stack memory left behind still remains allocated,
// unlike std.Io's 'Future(T).await', so it needs to be freed manually.
a_coroutine.deinit();

// note that the first argument of a coroutine MUST be of type '*coro.AnyCoroutine',
// otherwise the program will emit a compile error.
// This function cannot be generic or variadic.
fn myCoroutine(co: *coro.AnyCoroutine) void {
    std.log.debug("Hello!", .{});
    co.yield() catch unreachable; // Can return error.Canceled
    std.log.debug("Hello again!", .{});
}
```

## Coroutines and `std.Io`
These coroutines also implement some of `std.Io`'s functions:
- [ ] async/concurrent/await/cancel related functions (see [Notes](#notes))
- [ ] futex (Semaphore, Mutex)
- [ ] operate
- [ ] filesystem
- [ ] processes
- [x] time
- [ ] random (antropy)
- [x] networking (excluding netWriteFile, netSend, netReceive, netInterfaceName, netLookup)

You can get the interface by calling `.io()` on a `*AnyCoroutine`.

Functions that can block will just yield instead, returning control flow to the caller of `.@"resume"`
with a `null`/`false` value.

### Notes
- Futures are not planned as the `Io` provided by the library isn't supposed to be
a full-blown `std.Io` interface but rather a small connector allowing other libraries so benefit
from this one.
- Files and Stream provided by the `Io` interface will not work with other interfaces as they use
non-blocking operations at the syscall level (i.e: internally, blocking operation will return some
sort of "WouldBlock" error then yield the coroutine)

## Why this over `std.Io.Evented` ?
While `std.Io.Evented` do implements coroutines (or "fibers" as they call it), they still need
to conform to their own API's specs; They cannot be manually managed, and I think it kind of
betrays all the point of "user-managed threads", as this library allow you to fine-control your
asynchronous tasks without relying on guessing or praying for your task to run. Also ensures your
application to be single-threaded (no need for mutexes, semaphore or any sort of multi-threading bullsh\*t
that no-one wants to deal with)

## Final note
This library is a part (and developped along) [Gecko (private, WIP)](http://github.com/Darkfllame/Gecko), a Minecraft
server software written in Zig, from scratch.