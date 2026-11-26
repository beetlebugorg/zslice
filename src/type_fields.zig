//! The fields of a struct or an enum as one array of records.
//!
//! Zig 0.17 gives the names, the types, and the values of the fields as
//! separate arrays in `@typeInfo`. The loops of zslice read one record for
//! each field: `name` and `type` for a struct, `name` and `value` for an
//! enum. Each function here runs at compile time and zips the arrays of
//! `@typeInfo` into those records.
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");

/// One field of a struct.
pub const StructField = struct {
    name: [:0]const u8,
    type: type,
};

/// One field of an enum.
pub const EnumField = struct {
    name: [:0]const u8,
    value: comptime_int,
};

/// The fields of the struct `T`, in order.
pub inline fn structFields(comptime T: type) []const StructField {
    return structInfoFields(@typeInfo(T).@"struct");
}

/// The fields of a struct from its `@typeInfo`, in order.
pub inline fn structInfoFields(comptime info: std.builtin.Type.Struct) []const StructField {
    comptime {
        var out: [info.field_names.len]StructField = undefined;
        for (info.field_names, info.field_types, 0..) |n, t, i| out[i] = .{ .name = n, .type = t };
        const final = out;
        return &final;
    }
}

/// The fields of the enum `T`, in order.
pub inline fn enumFields(comptime T: type) []const EnumField {
    comptime {
        const info = @typeInfo(T).@"enum";
        var out: [info.field_names.len]EnumField = undefined;
        for (info.field_names, info.field_values, 0..) |n, v, i| out[i] = .{ .name = n, .value = v };
        const final = out;
        return &final;
    }
}

test "structFields and enumFields keep the order of the fields" {
    const S = struct { a: u8, b: f32 };
    const E = enum(u8) { x = 3, y = 7 };
    const sf = comptime structFields(S);
    try std.testing.expectEqualStrings("b", sf[1].name);
    try std.testing.expect(sf[1].type == f32);
    const ef = comptime enumFields(E);
    try std.testing.expectEqual(7, ef[1].value);
}
