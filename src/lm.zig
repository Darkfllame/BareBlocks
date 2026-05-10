//! SIMD Oriented linear math
//! library.

// TODO: Quaternions

const LM = @This();

const std = @import("std");
const testing = std.testing;

const Type = std.builtin.Type;
const ctPrint = std.fmt.comptimePrint;
const math = std.math;
const sqrt = math.sqrt;
const assert = std.debug.assert;

const LMType = enum { vector, matrix, quaternion };

pub inline fn supportsArithmetics(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .float, .comptime_int, .comptime_float => true,
        else => false,
    };
}

/// A generic-sized and typed vector.
///
/// **Parameters**:
/// - `T`: The type of the vector, must be a scalar type.
/// - `DIM`: The dimension of the vector, must be between 1 and 4.
///
/// **Note**:
/// - If `DIM` is 1, this function will just return `T`
pub fn Vec(comptime T: type, comptime DIM: comptime_int) type {
    if (DIM == 1) return T;
    if (comptime DIM < 2 or DIM > 4) {
        @compileError(ctPrint("Vec dimension must be between 2 and 4, got {d}", .{DIM}));
    }
    if (comptime !supportsArithmetics(T)) {
        @compileError("Vec subtype must support arithmetics (ints or floats)");
    }
    return extern struct {
        /// The array containing the data
        /// of the vector.
        fields: [DIM]T = [1]T{0} ** DIM,

        const Self = @This();
        const VecSelf = @Vector(DIM, T);

        fn Field(comptime i: comptime_int) type {
            return struct {
                pub inline fn get(self: Self) T {
                    return self.fields[i];
                }

                pub inline fn set(self: *Self, v: T) void {
                    self.fields[i] = v;
                }
            };
        }

        fn SwizzleResult(comptime s: []const u8) type {
            return switch (s.len) {
                1, 2, 3, 4 => |d| Vec(T, d),
                else => @compileError("Swizzle string length must be at least 1 and max 4"),
            };
        }
        fn newCropped(_x: T, _y: T, _z: T, _w: T) Self {
            var arr: [DIM]T = undefined;
            arr[0] = _x;
            arr[1] = _y;
            if (DIM >= 3) arr[2] = _z;
            if (DIM >= 4) arr[3] = _w;
            return new(arr);
        }
        const CrossProductResult = switch (DIM) {
            2 => T,
            3 => Self,
            4 => @compileError("Cannot get the cross product of a 4D vector"),
            else => unreachable,
        };

        pub const LM_TYPE = LMType.vector;

        pub const zero = newUniform(0);
        pub const one = newUniform(1);
        /// The horizontal unit vector.
        pub const unitX = newCropped(1, 0, 0, 0);
        /// The vertical component of the vector.
        pub const unitY = newCropped(0, 1, 0, 0);
        /// The depth unit vector.
        ///
        /// **Available if**: `DIM` >= 3
        pub const unitZ = newCropped(0, 0, 1, 0);
        /// The 4th component unit vector.
        ///
        /// **Available if**: `DIM` == 4
        pub const unitW = newCropped(0, 0, 0, 1);

        /// Used for `std.fmt.format`
        pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            const realFmt = if (fmt.len == 0)
                "d"
            else
                fmt;
            try writer.print("(", .{});
            inline for (self.fields, 0..) |v, i| {
                try std.fmt.formatType(v, realFmt, .{
                    .alignment = options.alignment,
                    .fill = options.fill,
                    .precision = options.precision,
                    .width = options.width,
                }, writer, math.maxInt(usize));
                if (i != DIM - 1)
                    try writer.print(",", .{});
            }
            try writer.print(")", .{});
        }

        /// **Parameters**:
        /// - `args`: An array containing the vector data.
        /// **Returns**: A new vector from the given values.
        ///
        /// **Note**:
        /// - `args`'s fields have a default value of 0.
        pub fn new(args: [DIM]T) Self {
            return .{ .fields = args };
        }
        /// **Returns**: A new uniformely-scaled vector
        pub fn newUniform(s: T) Self {
            return new([1]T{s} ** DIM);
        }

        /// The horizontal component of the vector.
        pub const x = Field(0).get;
        /// The vertical component of the vector.
        pub const y = Field(1).get;
        /// The depth component of the vector.
        ///
        /// **Available if**: `DIM` >= 3
        pub const z = Field(2).get;
        /// The 4th component of the vector.
        ///
        /// **Available if**: `DIM` == 4
        pub const w = Field(3).get;
        /// Sets the horizontal component of the vector.
        pub const setX = Field(0).set;
        /// Sets the vertical component of the vector.
        pub const setY = Field(1).set;
        /// Sets the depth component of the vector.
        ///
        /// **Available if**: `DIM` >= 3
        pub const setZ = Field(2).set;
        /// Sets the 4th component of the vector.
        ///
        /// **Available if**: `DIM` == 4
        pub const setW = Field(3).set;

        /// **Returns**: A comptime string to pass to `swizzle`
        /// with this type to get a `Vec(T, targetDim)`
        pub inline fn swizzleString(comptime targetDim: comptime_int) []const u8 {
            comptime return swizzleStringDefault(targetDim, 0);
        }

        /// Like `swizzleString`, `default` is wether
        /// to use 0 or 1 in the string if `targetDim`
        /// is larger than `D` for new elements.
        pub fn swizzleStringDefault(comptime targetDim: comptime_int, comptime default: u1) []const u8 {
            if (targetDim < 2 or targetDim > 4)
                @compileError("Swizzle string length must be at least 2 and max 4");
            const field_swizzle: []const u8 = ("xyzw"[0..@min(DIM, targetDim)]);
            const zero_swizzle_size = targetDim - field_swizzle.len;
            const val = field_swizzle ++ ([1]u8{'0' + @as(u8, default)} ** zero_swizzle_size);
            // @compileLog(targetDim, DIM, field_swizzle, zero_swizzle_size, val);
            comptime return val;
        }

        /// Swizzle elements of this vector like glsl.
        ///
        /// Valid swizzle string can contain `0`, `1`, `x` or `z`.
        /// Additionally `z` and `w` if the size is larger or equal
        /// to 3 and 4 respectively.
        ///
        /// **Parameters**:
        /// - `s`: The swizzle string to use.
        ///
        /// **Note**:
        /// - The result type will scale with the size of
        ///   `s`. i.e: Vec(T, s.len) and just `T` if `s.len == 1`.
        pub inline fn swizzle(self: Self, comptime s: []const u8) SwizzleResult(s) {
            return if (comptime s.len == 0)
                @compileError("Empty swizzle")
            else if (comptime s.len == 1)
                @field(Self, s)(self)
            else if (comptime std.mem.eql(u8, s, "xyzw"[0..DIM]))
                self
            else ret: {
                const mask: @Vector(s.len, i32) = comptime shuffle_mask: {
                    var mask = [1]i32{0} ** s.len;
                    for (s, &mask) |c, *m| {
                        m.* = switch (c) {
                            inline '0', '1' => |v| ~@as(i32, v - '0'),
                            inline 'w'...'z' => |v| if (v >= 'x' and (v - 'x') <= DIM)
                                v - 'x'
                            else if (DIM != 4)
                                @compileError(ctPrint("Invalid swizzle field: '{c}'", .{c}))
                            else
                                3,
                            else => @compileError(ctPrint("Invalid swizzle field: '{c}'", .{c})),
                        };
                    }
                    break :shuffle_mask mask;
                };
                break :ret .{ .fields = @shuffle(T, self.toVector(), @Vector(2, T){ 0, 1 }, mask) };
            };
        }

        /// Casts the vector to a same-sized vector but
        /// with a different sub-type.
        ///
        /// **Parameters**:
        /// - `NewType`: The type to cast the vector to.
        ///
        /// **Note**:
        /// - This could generate a panic if you
        ///   try to convert a float vector to an
        ///   int-one.
        pub fn cast(self: Self, comptime NewType: type) Vec(NewType, DIM) {
            if (NewType == T) return self;
            var result: Vec(NewType, DIM) = undefined;
            inline for (&result.fields, 0..) |*f, i| {
                f.* = _castArithType(T, NewType, self.fields[i]);
            }
            return result;
        }

        fn convert(v: anytype, comptime get_value: bool) if (get_value) Self else bool {
            const V = @TypeOf(v);
            if (isVec(V)) {
                const vDIM = comptime @as(V, undefined).fields.len;
                if (get_value) {
                    return if (vDIM >= DIM)
                        v.swizzle("xyzw"[0..DIM]).cast(T)
                    else
                        @compileError("Unable to convert \"" ++ @typeName(V) ++ "\" to " ++ @typeName(Self));
                } else return vDIM >= DIM;
            }

            const info = @typeInfo(V);
            if (info == .pointer) {
                return convert(if (get_value) v.* else @as(@TypeOf(v.*), undefined), get_value);
            } else if (info == .array or info == .vector) {
                const subinfo = if (info == .array)
                    info.array
                else
                    info.vector;
                if (subinfo.len != DIM or !supportsArithmetics(subinfo.child)) {
                    return if (get_value)
                        @compileError(ctPrint("Given array type \"{s}\" isn't right length (\"{d}\")" ++
                            " and/or doesn't support arithmetics (isn't int or float)", .{
                            @typeName(V),
                            v.len,
                        }))
                    else
                        false;
                }
                if (get_value) {
                    if (subinfo.child == T) {
                        return .{ .fields = v };
                    }
                    var res: Self = undefined;
                    for (0..DIM) |i| {
                        res.fields[i] = _castArithType(subinfo.child, T, v[i]);
                    }
                    return res;
                } else return true;
            } else if (info == .@"struct") {
                const sinfo = info.@"struct";
                const fields = sinfo.fields;
                var res: Self = zero;
                inline for (fields, 0..) |f, i| {
                    const BAD_FIELD_NAME = ctPrint(
                        "Bad field name: {s}",
                        .{f.name},
                    );
                    const resFI = if (sinfo.is_tuple)
                        i
                    else if (f.name.len == 1) switch (f.name[0]) {
                        inline 'x'...'x' + DIM => |c| c - 'x',
                        'w' => if (DIM == 4)
                            3
                        else
                            return if (get_value) @compileError(BAD_FIELD_NAME) else false,
                        else => return if (get_value) @compileError(BAD_FIELD_NAME) else false,
                    } else return if (get_value) @compileError(BAD_FIELD_NAME) else false;
                    if (get_value)
                        res.fields[resFI] = _castArithType(f.type, T, @field(v, f.name))
                    else if (!supportsArithmetics(f.type))
                        return false;
                }
                return if (get_value) res else true;
            } else if (supportsArithmetics(V)) {
                return if (get_value) newUniform(_castArithType(V, T, v)) else true;
            }
            return if (get_value) @compileError("Cannot convert \"" ++ @typeName(V) ++ "\" to " ++ @typeName(Self)) else false;
        }

        /// **Returns**: Whether the given type could be converted
        ///              to `Self` via `from`.
        pub inline fn couldConvert(comptime V: type) bool {
            return comptime convert(@as(V, undefined), false);
        }
        /// Converts `v` to `Self`.
        ///
        /// This supports other `Vec`s, other structs,
        /// arrays, scalars and pointers to one of those.
        ///
        /// **Parameters**:
        /// - `v`: The value to converts.
        ///
        /// **Note**:
        /// - `v` can be a scalar value, in
        ///       that case it will convert
        ///       to a uniformaly scaled
        ///       vector.
        pub fn from(v: anytype) Self {
            return convert(v, true);
        }

        /// **Returns**: The dot product between `self`
        /// and `b`.
        ///
        /// **Note**:
        /// - This functions uses `from` to convert
        ///   `b` to `Self`.
        pub fn dot(self: Self, b: Self) T {
            return @reduce(.Add, self.toVector() * b.toVector());
        }
        /// **Returns**: The cross product for the given vectors.
        ///
        /// **Note**:
        /// - Result is:
        ///   - A scalar value for 2D vectors.
        ///   - A 3D vectors for 3D vectors
        /// - Only valid for 2D and 3D vectors.
        /// - Result obei the left hand rule.
        /// - This functions uses `from` to convert
        ///   `b` to `Self`.
        pub fn cross(self: Self, b: Self) CrossProductResult {
            const z_scale = self.x() * b.y() - b.x() * self.y();
            if (DIM == 2) {
                return z_scale;
            }
            // self.yzx * b.zxy - b.yzx * self.zxy
            return new(.{
                self.y() * b.z() - b.y() * self.z(),
                self.z() * b.x() - b.z() * self.x(),
                z_scale,
            });
        }
        /// **Returns**: The squared length of the vector.
        ///
        /// **Note**:
        /// - This function is equivalent to `self.dot(self)`
        /// - Does not use square root.
        pub fn length2(self: Self) T {
            return self.dot(self);
        }
        /// **Returns**: The length of the vector.
        pub fn length(self: Self) T {
            return sqrt(self.length2());
        }
        /// **Returns**: The vector distance between `self` and `b`.
        ///
        /// **Note**:
        /// - Does not use square root.
        /// - This functions is equivalent to `b - self`.
        /// - This functions uses `from` to convert
        ///   `b` to `Self`.
        pub fn distanceVec(self: Self, b: Self) Self {
            return b.sub(self);
        }
        /// **Returns**: The squared distance between `self` and `b`.
        ///
        /// **Note**:
        /// - Does not use square root.
        /// - This functions is equivalent to `self.distanceVec(b).length2()`.
        pub fn distance2(self: Self, b: Self) T {
            return self.distanceVec(b).length2();
        }
        /// **Returns**: The distance between `self` and `b`.
        pub fn distance(self: Self, b: Self) T {
            return self.distanceVec(b).length();
        }
        /// **Returns**: The unit vector of `self`.
        pub fn normalize(self: Self) Self {
            if (self.length2() == 0) return zero;
            return self.div(.from(self.length()));
        }

        /// **Returns**: The homogeneous vector of `self`.
        pub fn homogeneousVec(self: Self) Vec(T, 4) {
            var result = self.swizzle(swizzleString(4));
            result.setW(1);
            return result;
        }
        pub inline fn toVector(self: Self) VecSelf {
            return self.fields;
        }

        /// **Note**:
        /// - Uses `from` to convert `b` to `Self`.
        pub fn add(self: Self, b: Self) Self {
            return from(self.toVector() + b.toVector());
        }
        /// **Note**:
        /// - Uses `from` to convert `b` to `Self`.
        pub fn sub(self: Self, b: Self) Self {
            return from(self.toVector() - b.toVector());
        }
        pub fn neg(self: Self) Self {
            return from(-self.toVector());
        }
        /// **Note**:
        /// - Uses `from` to convert `b` to `Self`.
        pub fn mul(self: Self, b: Self) Self {
            return from(self.toVector() * b.toVector());
        }
        /// **Note**:
        /// - Uses `from` to convert `b` to `Self`.
        pub fn div(self: Self, b: Self) Self {
            return from(self.toVector() / b.toVector());
        }
        pub fn mod(self: Self, b: Self) Self {
            return from(@mod(self.toVector(), b.toVector()));
        }
        pub fn rem(self: Self, b: Self) Self {
            return from(@rem(self.toVector(), b.toVector()));
        }
        pub fn min(self: Self, b: Self) Self {
            return from(@min(self.toVector(), b.toVector()));
        }
        pub fn max(self: Self, b: Self) Self {
            return from(@max(self.toVector(), from(b).toVector()));
        }
        pub fn componentMin(self: Self) T {
            return @reduce(.Min, self.toVector());
        }
        pub fn componentMax(self: Self) T {
            return @reduce(.Max, self.toVector());
        }
        pub fn abs(self: Self) Self {
            return from(@abs(self.toVector()));
        }
        pub fn round(self: Self) Self {
            return from(@round(self.toVector()));
        }
        pub fn floor(self: Self) Self {
            return from(@floor(self.toVector()));
        }
        pub fn ceil(self: Self) Self {
            return from(@ceil(self.toVector()));
        }

        /// Checks raw equality (no threshold for floats).
        pub fn eql(self: Self, b: Self) bool {
            inline for (self.fields, 0..) |v, i| {
                if (v != b.fields[i]) return false;
            }
            return true;
        }
        pub fn approxEqAbs(self: Self, b: Self, tolerance: T) bool {
            inline for (self.fields, 0..) |v, i| {
                if (!math.approxEqAbs(T, v, b.fields[i], tolerance)) return false;
            }
            return true;
        }

        pub fn lerp(self: Self, b: Self, t: T) Self {
            return self.add(b.sub(self).mul(.from(t)));
        }
    };
}
//#region Vector types
pub const Vec2b = Vec(i8, 2);
pub const Vec2s = Vec(i16, 2);
pub const Vec2i = Vec(i32, 2);
pub const Vec2l = Vec(i64, 2);
pub const Vec2f = Vec(f32, 2);
pub const Vec2d = Vec(f64, 2);
pub const Vec3b = Vec(i8, 3);
pub const Vec3s = Vec(i16, 3);
pub const Vec3i = Vec(i32, 3);
pub const Vec3l = Vec(i64, 3);
pub const Vec3f = Vec(f32, 3);
pub const Vec3d = Vec(f64, 3);
pub const Vec4b = Vec(i8, 4);
pub const Vec4s = Vec(i16, 4);
pub const Vec4i = Vec(i32, 4);
pub const Vec4l = Vec(i64, 4);
pub const Vec4f = Vec(f32, 4);
pub const Vec4d = Vec(f64, 4);
//#endregion

/// TODO: doc
pub fn Mat(comptime T: type, comptime DIM: comptime_int) type {
    if (comptime DIM < 1 or DIM > 4) {
        @compileError(ctPrint("Mat dimension must be between 1 and 4, got {d}", .{DIM}));
    }
    if (comptime !supportsArithmetics(T)) {
        @compileError("Mat subtype must support arithmetics (ints or floats)");
    }
    return extern struct {
        /// column-major list of matrix elements.
        fields: [DIM * DIM]T = [1]T{0} ** (DIM * DIM),

        const Self = @This();
        const VecDIMT = Vec(T, DIM);
        const Vec3T = Vec(T, 3);
        const Mat4T = Mat(T, 4);

        fn MulResult(comptime Rhs: type) type {
            return if ((isVec(Rhs) and
                @as(Rhs, undefined).fields.len == DIM) or
                VecDIMT.couldConvert(Rhs))
                VecDIMT
            else if ((isMat(Rhs) and @as(Rhs, undefined).fields.len == DIM * DIM) or
                supportsArithmetics(Rhs) or couldConvert(Rhs))
                Mat(T, DIM)
            else
                @compileError("Unsupported arithmetic type: " ++ @typeName(Rhs));
        }

        pub const LM_TYPE = LMType.matrix;

        pub const zero = Self{};
        pub const identity = newScaleUniform(1);

        pub fn getElement(self: Self, x: u2, y: u2) T {
            return self.fields[@as(u8, x) * DIM + @as(u8, y)];
        }
        pub fn setElement(self: *Self, x: u2, y: u2, v: T) void {
            self.fields[@as(u8, x) * DIM + @as(u8, y)] = v;
        }
        pub fn getRow(self: Self, r: u2) [DIM]T {
            var res: [DIM]T = undefined;
            inline for (0..DIM) |i| {
                res[i] = self.fields[(r + i) * DIM];
            }
            return res;
        }
        pub fn getRowVec(self: Self, c: u2) VecDIMT {
            return .{ .fields = self.getRow(c) };
        }
        pub fn setRow(self: *Self, r: u2, v: [DIM]T) void {
            inline for (0..DIM) |i| {
                self.fields[(r + i) * DIM] = v[i];
            }
        }
        pub fn getColumn(self: Self, c: u2) [DIM]T {
            return @as(*const [DIM]T, @ptrCast(self.fields[@as(u8, c) * DIM .. @as(u8, c) * DIM + DIM])).*;
        }
        pub fn getColumnVec(self: Self, c: u2) VecDIMT {
            return .{ .fields = self.getColumn(c) };
        }
        pub fn setColumn(self: *Self, c: u2, v: [DIM]T) void {
            @as(*[DIM]T, @ptrCast(self.fields[@as(u8, c) * DIM .. @as(u8, c) * DIM + DIM])).* = v;
        }

        pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.print("(", .{});
            inline for (0..DIM) |col| {
                try self.getColumnVec(col).format(fmt, options, writer);
                if (col != DIM - 1)
                    try writer.print(",", .{});
            }
            try writer.print(")", .{});
        }

        /// The args written in code are row-major,
        /// in the memory however, they are column-major.
        pub fn new(args: [DIM * DIM]T) Self {
            return (Self{ .fields = args }).transpose();
        }
        pub fn newScale(args: [DIM]T) Self {
            var res: Self = zero;
            inline for (0..DIM) |i| {
                res.fields[i * (DIM + 1)] = args[i];
            }
            return res;
        }
        pub fn newScaleUniform(s: T) Self {
            return newScale([1]T{s} ** DIM);
        }

        pub fn newTranslation(xyz: Vec3T) Mat4T {
            const vec = Vec3T.from(xyz);
            return Mat4T.new(.{
                1, 0, 0, vec.x(),
                0, 1, 0, vec.y(),
                0, 0, 1, vec.z(),
                0, 0, 0, 1,
            });
        }
        /// **Parameters**:
        /// - `axis`: The axis that the matrix will rotate
        ///           around.
        /// - `angle`: The angle (in radians) that the matrix
        ///            will rotate.
        /// **Note**:
        /// - Only works on floats.
        /// - `Vec(T, 3).couldConvert(@TypeOf(axis))`
        ///   must be `true`
        pub fn newRotation(axis: Vec3T, angle: T) Mat4T {
            // Implementation taken from zlm
            const cos = @cos(angle);
            const @"1-cos" = 1 - cos;
            const sin = @sin(angle);

            const unitAxis = axis.normalize();
            const x = unitAxis.x();
            const y = unitAxis.y();
            const z = unitAxis.z();

            return Mat4T.new(.{
                cos + x * x * @"1-cos",     y * x * @"1-cos" - z * sin, z * x * @"1-cos" + y * sin, 0,
                x * y * @"1-cos" + z * sin, cos + y * y * @"1-cos",     z * y * @"1-cos" - x * sin, 0,
                x * z * @"1-cos" - y * sin, y * z * @"1-cos" + x * sin, cos + z * z * @"1-cos",     0,
                0,                          0,                          0,                          1,
            });
        }
        /// **Parameters**:
        /// - `fovY`: The vertical field of view angle (in radians).
        /// - `aspect`: The aspect ratio of the screen (height / width).
        /// - `near`: The near clip-plane of the projection matrix.
        /// - `far`: The far clip-plane of the projection matrix.
        ///
        /// **Note**:
        /// - Only works on floats.
        pub fn newPerspective(fovY: T, aspect: T, near: T, far: T) Mat4T {
            // Also taken from zlm ;)
            const invTanHalfFovY = 1 / @tan(fovY / 2);

            return Mat4T.new(.{
                aspect * invTanHalfFovY, 0,              0,                  0,
                0,                       invTanHalfFovY, 0,                  0,
                0,                       0,              far / (far - near), (-far * near) / (far - near),
                0,                       0,              1,                  0,
            });
        }
        pub fn newOrthogonal(left: T, right: T, bottom: T, top: T, near: T, far: T) Mat4T {
            return Mat4T.new(.{
                2 / (right - left),               0,                                0,                            0,
                0,                                2 / (top - bottom),               0,                            0,
                0,                                0,                                -2 / (far - near),            0,
                -(right + left) / (right - left), -(top + bottom) / (top - bottom), -(far + near) / (far - near), 1,
            });
        }
        pub fn newLook(eye: Vec3T, direction: Vec3T, up: Vec3T) Mat4T {
            const zaxis = direction.normalize();
            const xaxis = zaxis.cross(up).normalize();
            const yaxis = zaxis.cross(xaxis);

            return Mat4T.new(.{
                xaxis.x(),       yaxis.x(),       -zaxis.x(),     0,
                xaxis.y(),       yaxis.y(),       -zaxis.y(),     0,
                xaxis.z(),       yaxis.z(),       -zaxis.z(),     0,
                -xaxis.dot(eye), -yaxis.dot(eye), zaxis.dot(eye), 1,
            });
        }
        pub fn newLookAt(eye: Vec3T, center: Vec3T, up: Vec3T) Mat4T {
            return newLook(eye, center.sub(eye), up);
        }

        pub fn cast(self: Self, comptime NT: type) Mat(NT, DIM) {
            var result: Mat(NT, DIM) = undefined;
            inline for (0..DIM * DIM) |i| {
                result.fields[i] = _castArithType(T, NT, self.fields[i]);
            }
            return result;
        }

        fn convert(v: anytype, comptime get_value: bool) if (get_value) Self else bool {
            const V = @TypeOf(v);
            const tinfo = @typeInfo(V);
            var result: Self = zero;
            if (isMat(V)) {
                if (!get_value) return true;
                const vDim = comptime sqrt(@as(V, undefined).fields.len);
                const minDim = @min(DIM, vDim);
                result = identity;
                inline for (0..minDim) |x| {
                    inline for (0..minDim) |y| {
                        result.fields[y * DIM + x] = _castArithType(
                            @TypeOf(v.fields[0]),
                            T,
                            v.fields[y * vDim + x],
                        );
                    }
                }
            } else if (tinfo == .pointer) {
                return convert(if (get_value) v.* else @as(@TypeOf(v.*), undefined), get_value);
            } else if (tinfo == .array) {
                const array = tinfo.array;
                if (!supportsArithmetics(array.child)) {
                    return if (get_value) @compileError(ctPrint("Given array type \"{s}\"" ++
                        " doesn't support arithmetics (isn't int or float)", .{
                        @typeName(V),
                        array.len,
                    })) else false;
                }
                if (array.len != DIM * DIM or !supportsArithmetics(V)) {
                    return if (get_value) @compileError(ctPrint(
                        "Given array type \"{s}\" has bad sub-array type \"{s}\"",
                        .{ @typeName(V), @typeName(array.child) },
                    )) else false;
                }
                if (!get_value) return true;
                for (0..DIM) |x| {
                    for (0..DIM) |y| {
                        result.fields[x * DIM + y] = _castArithType(
                            array.child,
                            T,
                            v[y * DIM + x],
                        );
                    }
                }
            } else if (tinfo == .@"struct") {
                const sInfo = tinfo.@"struct";
                if (!sInfo.is_tuple) {
                    return if (get_value) @compileError(ctPrint(
                        "Given struct type \"{s}\" has to be a tuple, has .{s} layout",
                        .{ @typeName(V), @tagName(sInfo.layout) },
                    )) else false;
                }
                if (sInfo.fields.len != DIM * DIM) {
                    return if (get_value) @compileError(ctPrint(
                        "Given struct type \"{s}\" has to have {d} fields, got {d}",
                        .{ @typeName(V), DIM * DIM, sInfo.fields.len },
                    )) else false;
                }
                if (!get_value) return true;
                inline for (0..DIM) |x| {
                    inline for (0..DIM) |y| {
                        result.fields[x * DIM + y] = _castArithType(
                            @TypeOf(v[y * DIM + x]),
                            T,
                            v[y * DIM + x],
                        );
                    }
                }
            } else {
                return if (get_value)
                    @compileError("Cannot cast \"" ++ @typeName(V) ++ "\" to " ++ @typeName(Self))
                else
                    false;
            }
            if (get_value) return result;
            unreachable;
        }

        pub inline fn couldConvert(comptime V: type) bool {
            return comptime convert(@as(V, undefined), false);
        }
        pub fn from(v: anytype) Self {
            return convert(v, true);
        }

        pub fn transpose(self: Self) Self {
            var res: Self = undefined;
            inline for (0..DIM) |i| {
                inline for (0..DIM) |j| {
                    res.fields[j * DIM + i] = self.fields[i * DIM + j];
                }
            }
            return res;
        }
        /// The minor matrix of the given element.
        ///
        /// **Parameters**:
        /// - `major_col`: The column of the element.
        /// - `major_row`: The row of the element.
        pub fn minor(
            self: Self,
            comptime major_col: comptime_int,
            comptime major_row: comptime_int,
        ) Mat(T, DIM - 1) {
            var result: Mat(T, DIM - 1) = undefined;
            var x: usize = 0;
            inline for (0..DIM) |col| {
                var y: usize = 0;
                if (col != major_col) {
                    inline for (0..DIM) |row| {
                        if (row != major_row) {
                            const v = self.fields[row * DIM + col];
                            result.fields[x * (DIM - 1) + y] = v;
                            y += 1;
                        }
                    }

                    x += 1;
                }
            }
            return result;
        }
        pub fn cofactor(self: Self) Self {
            var result: Self = undefined;
            inline for (0..DIM) |i| {
                inline for (0..DIM) |j| {
                    const sign = -((i + j) % 2 * 2 - 1);
                    result.fields[i * DIM + j] = sign * self.minor(i, j).det();
                }
            }
            return result;
        }
        pub fn adjoint(self: Self) Self {
            return self.cofactor().transpose();
        }
        /// **Returns**: `null` if calculating the inverse
        ///              is not possible (`self.det() == 0`)
        pub fn inverse(self: Self) ?Self {
            const d = self.det();
            if (d == 0) return null;
            const adj = self.adjoint();
            return adj.mul(1 / d);
        }

        /// Calculates the determinant of this matrix
        /// with laplace's expansion formula.
        pub fn det(self: Self) T {
            // Without this, the compiler would emit
            // a compile error because Mat(<type>, 0)
            // is invalid due to this type's first
            // line.
            if (DIM == 1) return self.fields[0];

            var result: T = 0;
            inline for (0..DIM) |major_col| {
                // -1 if even
                // 1 is odd
                const sign = -(@as(comptime_int, major_col) % 2 * 2 - 1);

                const sub_matrix = self.minor(major_col, 0);

                // basically, look at https://www.mathsisfun.com/algebra/matrix-determinant.html
                // to know why this. basically you multiply the x component of the current
                // matrix column (major_col) by the determinant of the rest of the matrix excluding
                // the first row and current column.
                result += sign * self.fields[major_col * DIM] * sub_matrix.det();
            }

            return result;
        }

        pub fn neg(self: Self) Self {
            var result: Self = undefined;
            inline for (self.fields, &result.fields) |v, *f| {
                f.* = -v;
            }
            return result;
        }
        pub fn mul(self: Self, b: Self) Self {
            var result: Self = undefined;
            inline for (0..DIM) |i| {
                result.setColumn(i, self.transform(b.getColumnVec(i)).fields);
            }
            return result;
        }
        pub fn transform(self: Self, v: VecDIMT) VecDIMT {
            var result: VecDIMT = .zero;
            inline for (0..DIM) |i| {
                result = result.add(self.getColumnVec(i).mul(.from(v.fields[i])));
            }
            return result;
        }
        pub fn scale(self: Self, v: T) Self {
            const vecSelf: @Vector(DIM * DIM, T) = @bitCast(self);
            return @bitCast(
                vecSelf *
                    @as(@Vector(DIM * DIM, T), @splat(v)),
            );
        }
        pub fn batchMul(mats: []const Self) Self {
            var res: Self = identity;
            for (mats) |mat| {
                res = res.mul(mat);
            }
            return res;
        }

        pub fn eql(self: Self, b: Self) bool {
            inline for (self.fields, 0..) |v, i| {
                if (v != b.fields[i]) return false;
            }
            return true;
        }
        pub fn approxEqAbs(self: Self, b: Self, tolerance: T) bool {
            inline for (self.fields, 0..) |v, i| {
                if (!math.approxEqAbs(T, v, b.fields[i], tolerance)) return false;
            }
            return true;
        }
    };
}
//#region Matrix types
pub const Mat2b = Mat(i8, 2);
pub const Mat2s = Mat(i16, 2);
pub const Mat2i = Mat(i32, 2);
pub const Mat2l = Mat(i64, 2);
pub const Mat2f = Mat(f32, 2);
pub const Mat2d = Mat(f64, 2);
pub const Mat3b = Mat(i8, 3);
pub const Mat3s = Mat(i16, 3);
pub const Mat3i = Mat(i32, 3);
pub const Mat3l = Mat(i64, 3);
pub const Mat3f = Mat(f32, 3);
pub const Mat4b = Mat(i8, 4);
pub const Mat4s = Mat(i16, 4);
pub const Mat4i = Mat(i32, 4);
pub const Mat4l = Mat(i64, 4);
pub const Mat4f = Mat(f32, 4);
pub const Mat4d = Mat(f64, 4);
//#endregion

/// WIP Quaternion implementation
/// TODO: doc
pub fn Quat(comptime T: type) type {
    if (comptime @typeInfo(T) != .float) {
        @compileError("Quat subtype must be a float");
    }
    return extern struct {
        const Self = @This();
        const Vec3T = Vec(T, 3);
        const Mat4T = Mat(T, 4);

        fn Field(comptime i: comptime_int) type {
            return struct {
                pub inline fn get(self: Self) T {
                    return self.fields[i];
                }

                pub inline fn set(self: *Self, v: T) void {
                    self.fields[i] = v;
                }
            };
        }

        /// `w`, `x`, `y`, `z` values.
        fields: [4]T = [1]T{0} ** 4,

        pub const LM_TYPE = LMType.quaternion;

        pub const identity = Self{ .fields = .{ 1, 0, 0, 0 } };

        pub const w = Field(0).get;
        pub const x = Field(1).get;
        pub const y = Field(2).get;
        pub const z = Field(3).get;
        pub const setW = Field(0).set;
        pub const setX = Field(1).set;
        pub const setY = Field(2).set;
        pub const setZ = Field(3).set;

        pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            const realFmt = if (fmt.len == 0)
                "d"
            else
                fmt;
            try writer.print("(", .{});
            inline for (self.fields, 0..) |v, i| {
                try std.fmt.formatType(v, realFmt, .{
                    .alignment = options.alignment,
                    .fill = options.fill,
                    .precision = options.precision orelse 0,
                    .width = options.width,
                }, writer, math.maxInt(usize));
                if (i != 3)
                    try writer.print(",", .{});
            }
            try writer.print(")", .{});
        }

        fn convert(v: anytype, comptime get_value: bool) if (get_value) Self else bool {
            const V = @TypeOf(v);
            const info = @typeInfo(V);
            if (isQuat(V)) {
                return if (get_value)
                    v.cast(T)
                else
                    true;
            }

            if (info == .pointer) {
                return convert(if (get_value) v.* else @as(@TypeOf(v.*), undefined), get_value);
            } else if (info == .array) {
                const arrayinfo = info.array;
                if (arrayinfo.len != 4 or @typeInfo(arrayinfo.child) != .float) {
                    return if (get_value)
                        @compileError(ctPrint("Given array type \"{s}\" isn't right length (\"{d}\")" ++
                            " and/or isn't float", .{
                            @typeName(V), v.len,
                        }))
                    else
                        false;
                }
                if (!get_value) return true;
                if (arrayinfo.child == T) {
                    return .{ .fields = v };
                }
                var res: Self = undefined;
                inline for (v, &res) |s, *d| {
                    d.* = _castArithType(arrayinfo.child, T, s);
                }
                if (get_value) return res;
                unreachable;
            } else if (info == .@"struct") {
                const sinfo = info.@"struct";
                const fields = sinfo.fields;
                var res: Self = undefined;
                if (fields.len != 4) {
                    return if (get_value)
                        @compileError(ctPrint("Bad field count, expected {d}, got {d}", .{
                            4, fields.len,
                        }))
                    else
                        false;
                }
                inline for (fields, 0..) |f, i| {
                    const BAD_FIELD_NAME = ctPrint(
                        "Bad field name: {s}",
                        .{f.name},
                    );
                    const resFI = if (sinfo.is_tuple)
                        i
                    else if (f.name.len == 1) switch (f.name[0]) {
                        inline 'w'...'z' => |c| if (c >= 'x')
                            c - 'x' + 1
                        else
                            0,
                        else => @compileError(BAD_FIELD_NAME),
                    } else @compileError(BAD_FIELD_NAME);
                    if (get_value)
                        res.fields[resFI] = _castArithType(f.type, T, @field(v, f.name))
                    else if (!supportsArithmetics(f.type))
                        return false;
                }
                return if (get_value) res else true;
            }
            return if (get_value)
                @compileError("Cannot convert \"" ++ @typeInfo(V) ++ "\" to " ++ @typeName(Self))
            else
                false;
        }

        pub fn cast(self: Self, comptime NT: type) Quat(NT) {
            if (T == NT) return self;
            var result: Quat(NT) = undefined;
            inline for (self.fields, &result.fields) |s, *d| {
                d.* = _castArithType(T, NT, s);
            }
            return result;
        }

        pub inline fn couldConvert(comptime V: type) bool {
            return comptime convert(@as(V, undefined), false);
        }

        pub fn from(v: anytype) bool {
            return convert(v, true);
        }

        pub fn new(_w: T, _x: T, _y: T, _z: T) Self {
            return Self{ .fields = .{ _w, _x, _y, _z } };
        }

        pub fn fromVec(_w: T, vec: Vec3T) Self {
            return new(_w, vec.x(), vec.y(), vec.z());
        }

        pub fn fromAxis(rads: T, axis: Vec3T) Self {
            const half_rads = rads / 2;
            return fromVec(
                @cos(half_rads),
                axis.normalize().mul(.from(@sin(half_rads))),
            );
        }

        pub fn fromEuler(axis_in_rads: Vec3T) Self {
            return fromAxis(axis_in_rads.z(), Vec3T.unitZ)
                .mul(fromAxis(axis_in_rads.y(), Vec3T.unitY))
                .mul(fromAxis(axis_in_rads.x(), Vec3T.unitX));
        }

        pub fn normalize(self: Self) Self {
            const self_vec = self.toVector();
            const len2 = @reduce(.Add, self_vec * self_vec);
            if (len2 == 0) return identity;
            const len = sqrt(len2);
            return new(
                self.w() / len,
                self.x() / len,
                self.y() / len,
                self.z() / len,
            );
        }

        pub inline fn toVector(self: Self) @Vector(4, T) {
            return self.fields;
        }

        pub fn toEuler(self: Self) Vec3T {
            // atan2(2 * (yz + wx), ww - xx - yy + zz)
            const yaw = math.atan2(
                2 * (self.y() * self.z() + self.w() * self.x()),
                self.w() * self.w() - self.x() * self.x() - self.y() * self.y() + self.z() * self.z(),
            );
            // asin(-2 * (xz - wy))
            const pitch = math.asin(
                -2 * (self.x() * self.z() - self.w() * self.y()),
            );
            // atan2(2 * (xy + wz), ww + xx - yy - zz)
            const roll = math.atan2(
                2 * (self.x() * self.y() + self.w() * self.z()),
                self.w() * self.w() + self.x() * self.x() - self.y() * self.y() - self.z() * self.z(),
            );
            return Vec3T.new(.{ yaw, pitch, roll });
        }

        pub fn neg(a: Self) Self {
            return a.scale(-1);
        }

        pub fn add(a: Self, b: Self) Self {
            return new(
                a.w() + b.w(),
                a.x() + b.x(),
                a.y() + b.y(),
                a.z() + b.z(),
            );
        }

        pub fn sub(a: Self, b: Self) Self {
            return a.add(b.neg());
        }

        pub fn mul(a: Self, b: Self) Self {
            const use_vector = true; // i can't figure which one is faster bruh
            if (comptime use_vector) {
                const vec_a = Vec(T, 4){ .fields = .{ a.x(), a.y(), a.z(), a.w() } };
                const vec_b = Vec(T, 4){ .fields = .{ b.x(), b.y(), b.z(), b.w() } };
                const _w = vec_a.mul(vec_b.swizzle("xyzw")).mul(.new(.{ -1, -1, -1, 1 })).dot(.one);
                const _x = vec_a.mul(vec_b.swizzle("wzyx")).mul(.new(.{ 1, 1, -1, 1 })).dot(.one);
                const _y = vec_a.mul(vec_b.swizzle("zwxy")).mul(.new(.{ -1, 1, 1, 1 })).dot(.one);
                const _z = vec_a.mul(vec_b.swizzle("yxwz")).mul(.new(.{ 1, -1, 1, 1 })).dot(.one);
                return new(_w, _x, _y, _z);
            } else {
                const _w =
                    (-a.x() * b.x()) +
                    (-a.y() * b.y()) +
                    (-a.z() * b.z()) +
                    (a.w() * b.w());
                const _x =
                    (a.x() * b.w()) +
                    (a.y() * b.z()) +
                    (-a.z() * b.y()) +
                    (a.w() * b.x());
                const _y =
                    (-a.x() * b.z()) +
                    (a.y() * b.w()) +
                    (a.z() * b.x()) +
                    (a.w() * b.y());
                const _z =
                    (a.x() * b.y()) +
                    (-a.y() * b.x()) +
                    (a.z() * b.w()) +
                    (a.w() * b.z());
                return new(_w, _x, _y, _z);
            }
        }

        pub fn scale(a: Self, b: T) Self {
            return new(
                a.w() * b,
                a.x() * b,
                a.y() * b,
                a.z() * b,
            );
        }

        pub fn toRotationMatrix(self: Self) Mat4T {
            const norm = self.normalize();
            const xx = norm.x() * norm.x();
            const yy = norm.y() * norm.y();
            const zz = norm.z() * norm.z();
            const xy = norm.x() * norm.y();
            const xz = norm.x() * norm.z();
            const yz = norm.y() * norm.z();
            const wx = norm.w() * norm.x();
            const wy = norm.w() * norm.y();
            const wz = norm.w() * norm.z();

            return .new(.{
                1 - 2 * (yy + zz), 2 * (xy - wz),     2 * (xz + wy),     0,
                2 * (xy + wz),     1 - 2 * (xx + zz), 2 * (yz - wx),     0,
                2 * (xz - wy),     2 * (yz + wx),     1 - 2 * (xx + yy), 0,
                0,                 0,                 0,                 1,
            });
        }

        pub fn inverse(self: Self) Self {
            const res = new(self.w(), -self.x(), -self.y(), -self.z());
            return res.scale(1 / @reduce(.Add, self.toVector() * self.toVector()));
        }

        pub fn lerp(a: Self, b: Self, t: T) Self {
            return new(
                LM.lerp(T, a.w(), b.w(), t),
                LM.lerp(T, a.x(), b.x(), t),
                LM.lerp(T, a.y(), b.y(), t),
                LM.lerp(T, a.z(), b.z(), t),
            );
        }

        pub fn slerp(a: Self, b: Self, t: T) Self {
            const parallel_threshold = 0.9995;
            var cos_theta = @reduce(.Add, a.toVector() * b.toVector());
            var right1 = b;

            // We need the absolute value of the dot product to take the shortest path
            if (cos_theta < 0) {
                cos_theta *= -1;
                right1 = b.neg();
            }

            if (cos_theta > parallel_threshold) {
                // Use regular old lerp to avoid numerical instability
                return a.lerp(right1, t);
            } else {
                const theta = math.acos(math.clamp(cos_theta, -1, 1));
                const thetap = theta * t;
                var qperp = right1.sub(a.scale(cos_theta)).normalize();
                return a.scale(@cos(thetap)).add(qperp.scale(@sin(thetap)));
            }
        }

        pub fn fromRotationMatrix(mat: Mat4T) Self {
            var t: T = undefined;
            var result: Self = undefined;

            if (mat.getElement(2, 2) < 0) {
                if (mat.getElement(0, 0) > mat.getElement(1, 1)) {
                    t = 1 + mat.getElement(0, 0) - mat.getElement(1, 1) - mat.getElement(2, 2);
                    result = new(
                        mat.getElement(1, 2) - mat.getElement(2, 1),
                        t,
                        mat.getElement(0, 1) + mat.getElement(1, 0),
                        mat.getElement(2, 0) + mat.getElement(0, 2),
                    );
                } else {
                    t = 1 - mat.getElement(0, 0) + mat.getElement(1, 1) - mat.getElement(2, 2);
                    result = new(
                        mat.getElement(2, 0) - mat.getElement(0, 2),
                        mat.getElement(0, 1) + mat.getElement(1, 0),
                        t,
                        mat.getElement(1, 2) + mat.getElement(2, 1),
                    );
                }
            } else {
                if (mat.getElement(0, 0) < -mat.getElement(1, 1)) {
                    t = 1 - mat.getElement(0, 0) - mat.getElement(1, 1) + mat.getElement(2, 2);
                    result = new(
                        mat.getElement(0, 1) - mat.getElement(1, 0),
                        mat.getElement(2, 0) + mat.getElement(0, 2),
                        mat.getElement(1, 2) + mat.getElement(2, 1),
                        t,
                    );
                } else {
                    t = 1 + mat.getElement(0, 0) + mat.getElement(1, 1) + mat.getElement(2, 2);
                    result = new(
                        t,
                        mat.getElement(1, 2) - mat.getElement(2, 1),
                        mat.getElement(2, 0) - mat.getElement(0, 2),
                        mat.getElement(0, 1) - mat.getElement(1, 0),
                    );
                }
            }

            return result.scale(0.5 / @sqrt(t));
        }

        pub fn eql(self: Self, b: Self) bool {
            return self.approxEqAbs(b, 0);
        }
        pub fn approxEqAbs(self: Self, b: Self, tolerance: T) bool {
            inline for (self.fields, 0..) |v, i| {
                if (!math.approxEqAbs(T, v, b.fields[i], tolerance)) return false;
            }
            return true;
        }
    };
}
pub const Quatf = Quat(f32);
pub const Quatd = Quat(f64);

pub fn lerp(comptime T: type, a: T, b: T, t: T) T {
    return a + (b - a) * t;
}

inline fn isLMTypeInner(comptime T: type, comptime LM_TYPE: LMType) ?std.builtin.Type {
    comptime {
        const info = _nonPtrTypeInfo(T);
        if (info != .@"struct") return null;
        if (info.@"struct".is_tuple or
            info.@"struct".layout != .@"extern" or
            !@hasDecl(T, "LM_TYPE") or
            T.LM_TYPE != LM_TYPE)
            return null;
        if (!@hasField(T, "fields"))
            return null;
        const fieldsInfo = @typeInfo(@FieldType(T, "fields"));
        if (fieldsInfo != .array) return null;
        const arrayInfo = fieldsInfo.array;
        if (arrayInfo.len == 0) return null;
        if (!supportsArithmetics(arrayInfo.child)) return null;
        return fieldsInfo;
    }
}

pub inline fn isVec(comptime T: type) bool {
    comptime {
        const arrayInfo = (isLMTypeInner(T, .vector) orelse return false).array;
        if (arrayInfo.len < 2 or arrayInfo.len > 4 or
            !supportsArithmetics(arrayInfo.child)) return false;
        return T == Vec(arrayInfo.child, arrayInfo.len);
    }
}

pub inline fn isMat(comptime T: type) bool {
    comptime {
        const arrayInfo = (isLMTypeInner(T, .matrix) orelse return false).array;
        if (arrayInfo.len < 2 or arrayInfo.len > 4 or
            !supportsArithmetics(arrayInfo.child)) return false;
        return T == Mat(arrayInfo.child, sqrt(arrayInfo.len));
    }
}

pub inline fn isQuat(comptime T: type) bool {
    comptime {
        const arrayInfo = (isLMTypeInner(T, .quaternion) orelse return false).array;
        if (arrayInfo.len != 4 or
            @typeInfo(arrayInfo.child) != .float) return false;
        return T == Quat(arrayInfo.child);
    }
}

test "Vec.cast, Vec.eql and Vec.add" {
    const expect = testing.expect;

    const v2f_0_5 = Vec2f.new(.{ 0, 5 });
    const v2u_0_5 = v2f_0_5.cast(i32).cast(f32);

    try expect(v2f_0_5.eql(v2u_0_5));
    try expect(v2f_0_5.add(v2u_0_5).eql(Vec2f.new(.{ 0, 10 })));
}

test "Mat.det" {
    const expect = testing.expect;

    try expect(Mat2f.identity.det() == 1);
    try expect(Mat3f.identity.det() == 1);
    try expect(Mat4f.identity.det() == 1);
}

test "Mat.mul" {
    const expect = testing.expect;

    try expect(Mat2f.identity.transform(Vec2f.one).eql(Vec2f.one));

    const scale = Mat2f.newScaleUniform(2);
    try expect(scale.transform(Vec2f.one).eql(.from(.{ 2, 2 })));

    const shear = Mat2f.new(.{
        1, 1,
        0, 1,
    });
    try expect(shear.mul(scale).transform(.from(.{ 0, 1 })).eql(.from(.{ 2, 2 })));

    const transform = Mat4f.new(.{
        1, 0, 0, 10,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    });
    try expect(transform.transform(.from(.{ 0, 0, 0, 1 })).eql(.from(.{ 10, 0, 0, 1 })));
}

test "Quat.new" {
    const expectEqual = testing.expectEqual;
    const q = Quat(f32).new(1.5, 2.6, 3.7, 4.7);

    try expectEqual(q.w(), 1.5);
    try expectEqual(q.x(), 2.6);
    try expectEqual(q.y(), 3.7);
    try expectEqual(q.z(), 4.7);
}

test "Quat.eql" {
    const expectEqual = testing.expectEqual;
    const a = Quat(f32).new(1.5, 2.6, 3.7, 4.7);
    const b = Quat(f32).new(1.5, 2.6, 3.7, 4.7);
    const c = Quat(f32).new(2.6, 3.7, 4.8, 5.9);

    try expectEqual(a.eql(b), true);
    try expectEqual(a.eql(c), false);
}

test "Quat.normalize" {
    const expectEqual = testing.expectEqual;
    const a = Quat(f32).fromVec(1, Vec3f.new(.{ 2, 2, 2 }));
    const b = Quat(f32).fromVec(0.2773500978946686, Vec3f.new(.{ 0.5547001957893372, 0.5547001957893372, 0.5547001957893372 }));

    try expectEqual(a.normalize(), b);
}

test "Quat.fromEuler" {
    const expectEqual = testing.expectEqual;
    const a = Quat(f32).fromEuler(Vec3f.new(.{ 10, 5, 45 }).mul(.from(math.rad_per_deg)));
    const a_res = a.toEuler();

    const b = Quat(f32).fromEuler(Vec3f.new(.{ 0, 55, 22 }).mul(.from(math.rad_per_deg)));
    const b_res = b.toEuler();

    try expectEqual(Vec3f.new(.{ 10, 5.0000005, 45.000004 }), a_res.mul(.from(math.deg_per_rad)));
    try expectEqual(Vec3f.new(.{ 0, 54.999992, 22.000004 }), b_res.mul(.from(math.deg_per_rad)));
}

fn _nonPtrTypeInfo(comptime T: type) std.builtin.Type {
    const info = @typeInfo(T);
    const ptrInfo = if (info == .pointer)
        @typeInfo(info.pointer.child)
    else
        info;
    return ptrInfo;
}

inline fn _castArithType(comptime T: type, comptime NT: type, v: T) NT {
    if (comptime !(supportsArithmetics(T) and supportsArithmetics(NT))) {
        @compileError(ctPrint("Both T ({s}) and NT ({s}) must be arithmetics types (ints or floats)", .{
            @typeName(T), @typeName(NT),
        }));
    }

    const tinfo = @typeInfo(T);
    const ntinfo = @typeInfo(NT);
    if (tinfo == .comptime_int or tinfo == .comptime_float or
        ntinfo == .comptime_int or ntinfo == .comptime_float) return v;
    return switch (ntinfo) {
        .int => switch (tinfo) {
            .int => @intCast(v),
            .float => @intFromFloat(v),
            else => unreachable,
        },
        .float => switch (tinfo) {
            .int => @floatFromInt(v),
            .float => @floatCast(v),
            else => unreachable,
        },
        else => unreachable,
    };
}
