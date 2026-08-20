const std = @import("std");
const BigInt = @import("math").BigInt;
const crypto = std.crypto;

// fn isPrime(allocator: Allocator, bits: usize, noalias buf: [*]const Limb) Allocator.Error!bool {
//     assert(bits > 0);

//     const limbs = buf[0 .. @divFloor(bits - 1, limb_size) + 1];
//     if (limbs[0] & 1 == 0) return false;

//     const a = big_int.Managed{ .allocator = .failing, .limbs = @constCast(limbs), .metadata = limbs.len };
//     if (a.order(big_num_1).compare(.ltq)) return false;
//     if (a.order(big_num_2).compare(.eq) or a.order(big_num_3).compare(.eq)) return true;

//     var n = try big_int.Managed.initCapacity(allocator, a.limbs.len);
//     defer n.deinit();
//     var d = try big_int.Managed.initCapacity(allocator, a.limbs.len);
//     defer n.deinit();
//     var div = try big_int.Managed.initCapacity(allocator, a.limbs.len);
//     defer n.deinit();
//     var mod = try big_int.Managed.initCapacity(allocator, a.limbs.len);
//     defer n.deinit();
//     try d.set(3);

//     try n.sqrt(&a);

//     while (true) {
//         try div.divTrunc(&mod, &n, &d);

//         if (mod.eqlZero()) return false;

//         if (try d.addWrap(&d, &big_num_2, .unsigned, bits)) break;
//     }

//     return true;
// }

// fn rabinMiller(
//     io: std.Io,
//     allocator: Allocator,
//     bits: usize,
//     /// `@divFloor(bits - 1, limb_size) + 1`
//     noalias buf: [*]const Limb,
//     k: usize,
// ) bool {
//     assert(bits > 0);

//     const limbs = buf[0 .. @divFloor(bits - 1, limb_size) + 1];

//     const n = big_int.Managed{
//         .allocator = .failing,
//         .limbs = @constCast(limbs),
//         .metadata = limbs.len,
//     };
//     if (n.order(big_num_1).compare(.ltq)) return false;
//     if (n.order(big_num_2).compare(.eq) or n.order(big_num_3).compare(.eq)) return true;

//     var a = try big_int.Managed.initCapacity(allocator, n.limbs.len);
//     defer a.deinit();

//     var pow_iter = try big_int.Managed.initCapacity(allocator, n.limbs.len);
//     defer pow_iter.deinit();

//     var pow_temp = try big_int.Managed.initCapacity(allocator, n.limbs.len);
//     defer pow_temp.deinit();

//     var pow_res = try big_int.Managed.initCapacity(allocator, n.limbs.len);
//     defer pow_res.deinit();

//     for (0..k) |_| {
//         try pow_iter.ensureCapacity(a.limbs.len);
//         @memcpy(pow_iter.limbs[0..a.len()], a.limbs[0..a.len()]);
//         while (pow_iter.order(big_num_max32).compare(.gte)) {
//             try pow_iter.sub(&pow_iter, &big_num_max32);
//             try a.pow(&pow_res, std.math.maxInt(u32));
//         }
//     }
// }

fn totient_eulerProductFormula(n_arg: usize) usize {
    var n = n_arg;
    var res = n;
    var p: usize = 2;
    while (p * p <= n) : (p += 1) {
        if (n % p != 0) continue;

        while (n % p == 0) n /= p;
        res -= res / p;
    }

    if (n > 1) res -= res / n;

    return res;
}

/// Output result is written in little-endian
// fn genPrime(io: std.Io, bits: usize, out: []Limb) void {
//     assert(out.len * limb_size >= bits);

//     const State = enum { gen_random, post_gen, test_prime, confirm_prime };
//     const buffer = out[0 .. @divFloor(bits - 1, limb_size) - 1];
//     sw: switch (State.gen_random) {
//         .gen_random => {
//             io.randomSecure(@ptrCast(buffer)) catch io.random(@ptrCast(buffer));
//             continue :sw .post_gen;
//         },
//         .post_gen => {
//             // Ensure odd
//             buffer[0] |= 1;
//             // Ensure exact bit length

//             // 0 - limb_size
//             const last_bit_idx = limb_size - ((bits - 1) % limb_size);
//             const last_bit: Limb = @as(Limb, 1) << @intCast(last_bit_idx);
//             buffer[buffer.len] &= (std.math.maxInt(Limb) >> limb_size - last_bit_idx);
//             buffer[buffer.len] |= last_bit;
//         },
//         .test_prime => {},
//         .confirm_prime => {},
//     }
// }

pub fn main(init: std.process.Init) !void {
    
    const Part = usize;
    var rnd_Part: [1024 / @bitSizeOf(Part)]Part = undefined;
    init.io.random(@ptrCast(&rnd_Part));
    rnd_Part[rnd_Part.len - 1] |= 1 << (@bitSizeOf(Part) - 1);
    rnd_Part[0] &= ~@as(Part, 1);

    const BigIntSized = BigInt(Part);
    const some_big_int = BigIntSized.Const.fromParts(&rnd_Part);
    // std.log.debug("{any}, {d}", .{ some_big_int.parts, some_big_int.bit_size });
    const alt = try some_big_int.alt(init.gpa, 1e9, .{
        .mode = .hex,
        .case = .upper,
    });
    defer alt.deinit(init.gpa);
    std.log.debug("{f}", .{alt});
}
