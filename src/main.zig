const std = @import("std");
const rsa = @import("rsa.zig");
const net = @import("net");
const crypto = std.crypto;
const big_int = std.math.big.int;

const asn1 = crypto.codecs.asn1;
const der = crypto.codecs.asn1.der;
const Allocator = std.mem.Allocator;

const bytes = [_]u8{
    0x01, 0x00, // server_id: "\0"

    0xA2, 0x01, // public_key
    0x30, 0x81, 0x9F, // top value
        0x30, 0x0D, // algorithm
            0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, // algorithm
            0x05, 0x00, // parameters
        0x03, 0x81, 0x8D, // subjectPublicKey
            0x00, // padding
            0x30, 0x81, 0x89, // value
                0x02, 0x81, 0x81, // modulus
                    0x00, 0x84, 0x6F, 0x3E, 0x34, 0x0A, 0xAA, 0x39, 0xE0, 0x24, 0x19, 0x05, 0xC5, 0x2A, 0x95, 0xB8, //
                    0x5D, 0xBD, 0x5F, 0xC0, 0xB8, 0xE0, 0xC5, 0x15, 0x6E, 0x95, 0xCE, 0xAC, 0x80, 0x78, 0x39, 0xA7, //
                    0xD7, 0xA8, 0x50, 0x22, 0x98, 0x13, 0x4B, 0xB0, 0x04, 0xCF, 0x1E, 0xD9, 0x47, 0x1F, 0x7D, 0x1E, //
                    0xEE, 0x35, 0x75, 0x4B, 0xD7, 0xA4, 0xBC, 0xEC, 0x67, 0x3D, 0xC5, 0x0C, 0xD9, 0x76, 0x7B, 0x37, //
                    0xD7, 0x79, 0x7E, 0x64, 0xCA, 0x81, 0x82, 0xBE, 0xA8, 0xCA, 0xAA, 0x87, 0x17, 0xC5, 0x2F, 0x87, //
                    0xF4, 0x3B, 0xF2, 0xB3, 0x98, 0xC6, 0xF5, 0x11, 0x0D, 0x80, 0x5C, 0xD0, 0x04, 0x65, 0x4F, 0x17, //
                    0x60, 0x51, 0xB9, 0x3A, 0x10, 0xBB, 0xFA, 0x70, 0xC8, 0xD5, 0x31, 0x49, 0x4E, 0xB9, 0x16, 0xA2, //
                    0x33, 0x56, 0x8E, 0x49, 0x1F, 0xE7, 0x0E, 0x4B, 0xA4, 0x60, 0xDA, 0xE0, 0x76, 0x91, 0x6F, 0xDD, //
                    0x07, //
                0x02, 0x03, 0x01, 0x00, 0x01, // exponent

    0x04, 0xCB, 0x26, 0x1F, 0xD1, // verify_token
    0x01, // should_authenticate
};

const PublicKeyDER = struct {

    algorithm: struct {
        algorithm: asn1.Oid = .fromDotComptime("1.2.840.113549.1.1.1"),
        parameter: ?enum { none } = null,
    } = .{},
    subject_public_key: struct {
        modulus: @Int(.unsigned, @bitSizeOf(rsa.BitsType) + 8),
        public_exponent: u32,
    },

    pub fn decodeDer(decoder: *der.Decoder) !PublicKeyDER {
        var res: PublicKeyDER = undefined;

        const root = try decoder.element(.init(.sequence, true, .universal));
        defer decoder.index = root.slice.end;

        res.algorithm = try decoder.any(@FieldType(PublicKeyDER, "algorithm"));
        res.algorithm.parameter = null;
        {
            const bitstring_elem = try decoder.element(.init(.bitstring, false, .universal));
            defer decoder.index = bitstring_elem.slice.end;
            decoder.index = bitstring_elem.slice.start + 1;
            if (decoder.bytes[bitstring_elem.slice.start] != 0) return error.BadBitstring;

            res.subject_public_key = try decoder.any(@FieldType(PublicKeyDER, "subject_public_key"));
        }
    }

    pub fn writeDer(self: PublicKeyDER, writer: *std.Io.Writer) !void {
        _=self;
        _=writer;
        // TODO: Fuck do I really gotta make my own DER writer :sob:
        // const algo_oid_size = self.algorithm.algorithm.encoded.len;
        // const algorithm_size = algo_oid_size;
        // var total_len: usize = 0;
    }
};

pub fn main(init: std.process.Init) !void {
    var reader = std.Io.Reader.fixed(&bytes);
    const res = try net.packets.encryption_request_s2c.readRoot(init.gpa, init.arena.allocator(), &reader);
    std.log.debug("{f}", .{net.packets.encryption_request_s2c.formatted(res)});
    var pkey: PublicKeyDER = undefined;
    var dec = der.Decoder{ .bytes = res.public_key };
    {
        const root = try dec.element(.init(.sequence, true, .universal));
        defer dec.index = root.slice.end;

        pkey.algorithm = try dec.any(@FieldType(PublicKeyDER, "algorithm"));
        pkey.algorithm.parameter = null;
        {
            const bitstring_elem = try dec.element(.init(.bitstring, false, .universal));
            defer dec.index = bitstring_elem.slice.end;
            dec.index = bitstring_elem.slice.start + 1;

            pkey.subject_public_key = try dec.any(@FieldType(PublicKeyDER, "subject_public_key"));
        }
    }
    if (dec.index != res.public_key.len) return error.LengthMismatch;

    std.log.debug("pkey.algorithm.algorithm: {s}", .{pkey.algorithm.algorithm.encoded});

    // var out_buffer: [bytes.len]u8 = undefined;
}
