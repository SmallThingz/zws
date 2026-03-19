const std = @import("std");

pub const Role = enum {
    server,
    client,
};

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
};

pub const MessageOpcode = enum {
    text,
    binary,
};

pub const CloseCode = enum(u16) {
    normal_closure = 1000,
    going_away = 1001,
    protocol_error = 1002,
    unsupported_data = 1003,
    invalid_frame_payload_data = 1007,
    policy_violation = 1008,
    message_too_big = 1009,
    mandatory_extension = 1010,
    internal_error = 1011,
    service_restart = 1012,
    try_again_later = 1013,
    bad_gateway = 1014,
};

pub fn isControl(opcode: Opcode) bool {
    return switch (opcode) {
        .close, .ping, .pong => true,
        else => false,
    };
}

pub fn isData(opcode: Opcode) bool {
    return switch (opcode) {
        .text, .binary => true,
        else => false,
    };
}

pub fn messageOpcode(opcode: Opcode) ?MessageOpcode {
    return switch (opcode) {
        .text => .text,
        .binary => .binary,
        else => null,
    };
}

pub fn isValidCloseCode(code: u16) bool {
    if (code < 1000 or code >= 5000) return false;
    return switch (code) {
        1004, 1005, 1006, 1015 => false,
        else => true,
    };
}

test "close code validation" {
    try std.testing.expect(isValidCloseCode(1000));
    try std.testing.expect(isValidCloseCode(1014));
    try std.testing.expect(isValidCloseCode(3000));
    try std.testing.expect(!isValidCloseCode(999));
    try std.testing.expect(!isValidCloseCode(1005));
    try std.testing.expect(!isValidCloseCode(5000));
}

test "opcode classification covers all supported opcodes" {
    try std.testing.expect(!isControl(.continuation));
    try std.testing.expect(!isControl(.text));
    try std.testing.expect(!isControl(.binary));
    try std.testing.expect(isControl(.close));
    try std.testing.expect(isControl(.ping));
    try std.testing.expect(isControl(.pong));

    try std.testing.expect(!isData(.continuation));
    try std.testing.expect(isData(.text));
    try std.testing.expect(isData(.binary));
    try std.testing.expect(!isData(.close));
    try std.testing.expect(!isData(.ping));
    try std.testing.expect(!isData(.pong));
}

test "messageOpcode returns only data opcodes" {
    try std.testing.expectEqual(MessageOpcode.text, messageOpcode(.text).?);
    try std.testing.expectEqual(MessageOpcode.binary, messageOpcode(.binary).?);
    try std.testing.expect(messageOpcode(.continuation) == null);
    try std.testing.expect(messageOpcode(.close) == null);
    try std.testing.expect(messageOpcode(.ping) == null);
    try std.testing.expect(messageOpcode(.pong) == null);
}

test "close code reserved boundaries are rejected" {
    inline for ([_]u16{ 1004, 1005, 1006, 1015 }) |code| {
        try std.testing.expect(!isValidCloseCode(code));
    }
    try std.testing.expect(isValidCloseCode(1016));
    try std.testing.expect(isValidCloseCode(4999));
}
