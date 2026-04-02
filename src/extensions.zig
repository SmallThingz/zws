const std = @import("std");

pub const ParsePerMessageDeflateError = error{
    DuplicateExtensionOffer,
    DuplicateExtensionParameter,
    InvalidExtensionParameter,
};

pub const PerMessageDeflate = struct {
    server_no_context_takeover: bool = true,
    client_no_context_takeover: bool = true,

    pub fn responseHeaderValue(self: @This()) []const u8 {
        if (self.server_no_context_takeover and self.client_no_context_takeover) {
            return "permessage-deflate; server_no_context_takeover; client_no_context_takeover";
        }
        if (self.server_no_context_takeover) {
            return "permessage-deflate; server_no_context_takeover";
        }
        if (self.client_no_context_takeover) {
            return "permessage-deflate; client_no_context_takeover";
        }
        return "permessage-deflate";
    }
};

pub const PerMessageDeflateOfferIterator = struct {
    header_value: []const u8,
    cursor: usize = 0,
    done: bool = false,

    pub fn next(self: *@This()) ParsePerMessageDeflateError!?PerMessageDeflate {
        while (!self.done) {
            const tail = self.header_value[self.cursor..];
            const comma = std.mem.indexOfScalar(u8, tail, ',') orelse tail.len;
            const extension_part = tail[0..comma];
            self.cursor += comma;
            if (self.cursor == self.header_value.len) {
                self.done = true;
            } else {
                self.cursor += 1;
            }

            // Handshake requests may repeat `permessage-deflate` to advertise
            // alternative parameter sets. Preserve those as separate iterator
            // results so negotiation can choose the best compatible offer.
            var param_it = std.mem.splitScalar(u8, extension_part, ';');
            const name = std.mem.trim(u8, param_it.next() orelse continue, " \t");
            if (!std.ascii.eqlIgnoreCase(name, "permessage-deflate")) continue;

            var parsed: PerMessageDeflate = .{
                .server_no_context_takeover = false,
                .client_no_context_takeover = false,
            };
            var saw_server_no_context_takeover = false;
            var saw_client_no_context_takeover = false;
            var saw_server_max_window_bits = false;
            var saw_client_max_window_bits = false;

            while (param_it.next()) |param_part| {
                const param = std.mem.trim(u8, param_part, " \t");
                if (param.len == 0) continue;
                const eq = std.mem.indexOfScalar(u8, param, '=');
                const param_name = std.mem.trim(u8, if (eq) |idx| param[0..idx] else param, " \t");
                const param_value = if (eq) |idx| std.mem.trim(u8, param[idx + 1 ..], " \t") else null;

                if (std.ascii.eqlIgnoreCase(param_name, "server_no_context_takeover")) {
                    if (param_value != null) return error.InvalidExtensionParameter;
                    if (saw_server_no_context_takeover) return error.DuplicateExtensionParameter;
                    saw_server_no_context_takeover = true;
                    parsed.server_no_context_takeover = true;
                    continue;
                }
                if (std.ascii.eqlIgnoreCase(param_name, "client_no_context_takeover")) {
                    if (param_value != null) return error.InvalidExtensionParameter;
                    if (saw_client_no_context_takeover) return error.DuplicateExtensionParameter;
                    saw_client_no_context_takeover = true;
                    parsed.client_no_context_takeover = true;
                    continue;
                }
                if (std.ascii.eqlIgnoreCase(param_name, "server_max_window_bits")) {
                    if (saw_server_max_window_bits) return error.DuplicateExtensionParameter;
                    const value = param_value orelse return error.InvalidExtensionParameter;
                    _ = parseWindowBits(value) catch return error.InvalidExtensionParameter;
                    saw_server_max_window_bits = true;
                    continue;
                }
                if (std.ascii.eqlIgnoreCase(param_name, "client_max_window_bits")) {
                    if (saw_client_max_window_bits) return error.DuplicateExtensionParameter;
                    if (param_value) |value| {
                        _ = parseWindowBits(value) catch return error.InvalidExtensionParameter;
                    }
                    saw_client_max_window_bits = true;
                    continue;
                }
                return error.InvalidExtensionParameter;
            }

            return parsed;
        }
        return null;
    }
};

pub fn offersPerMessageDeflate(header_value: []const u8) bool {
    var extension_it = std.mem.splitScalar(u8, header_value, ',');
    while (extension_it.next()) |extension_part| {
        var param_it = std.mem.splitScalar(u8, extension_part, ';');
        const name = std.mem.trim(u8, param_it.next() orelse continue, " \t");
        if (std.ascii.eqlIgnoreCase(name, "permessage-deflate")) return true;
    }
    return false;
}

pub fn parsePerMessageDeflate(header_value: []const u8) PerMessageDeflateOfferIterator {
    return .{ .header_value = header_value };
}

pub fn parsePerMessageDeflateFirst(header_value: []const u8) ParsePerMessageDeflateError!?PerMessageDeflate {
    // Use the iterator when parsing request offers. This helper is the stricter
    // response-style path: at most one negotiated permessage-deflate token may
    // remain after filtering unrelated extensions.
    var offers = parsePerMessageDeflate(header_value);
    const first = try offers.next();
    if (first == null) return null;
    if ((try offers.next()) != null) return error.DuplicateExtensionOffer;
    return first;
}

fn parseWindowBits(value: []const u8) error{InvalidWindowBits}!u8 {
    const parsed = std.fmt.parseInt(u8, value, 10) catch return error.InvalidWindowBits;
    if (parsed < 8 or parsed > 15) return error.InvalidWindowBits;
    return parsed;
}

test "offersPerMessageDeflate matches extension tokens regardless of parameters" {
    try std.testing.expect(offersPerMessageDeflate("permessage-deflate"));
    try std.testing.expect(offersPerMessageDeflate("permessage-deflate; client_max_window_bits"));
    try std.testing.expect(offersPerMessageDeflate("foo, permessage-deflate; client_no_context_takeover"));
    try std.testing.expect(!offersPerMessageDeflate("permessage-deflatex"));
    try std.testing.expect(!offersPerMessageDeflate("x-webkit-deflate-frame"));
}

test "parsePerMessageDeflate parses negotiated parameters and rejects malformed ones" {
    try std.testing.expectEqualDeep(
        PerMessageDeflate{
            .server_no_context_takeover = true,
            .client_no_context_takeover = false,
        },
        (try parsePerMessageDeflateFirst("permessage-deflate; server_no_context_takeover")).?,
    );
    try std.testing.expectEqualDeep(
        PerMessageDeflate{
            .server_no_context_takeover = false,
            .client_no_context_takeover = true,
        },
        (try parsePerMessageDeflateFirst("foo, permessage-deflate; client_no_context_takeover")).?,
    );
    try std.testing.expectEqualDeep(
        PerMessageDeflate{
            .server_no_context_takeover = false,
            .client_no_context_takeover = false,
        },
        (try parsePerMessageDeflateFirst("permessage-deflate; client_max_window_bits")).?,
    );
    try std.testing.expectEqual(@as(?PerMessageDeflate, null), try parsePerMessageDeflateFirst("x-test"));
    try std.testing.expectError(
        error.InvalidExtensionParameter,
        parsePerMessageDeflateFirst("permessage-deflate; unknown=1"),
    );
    try std.testing.expectError(
        error.InvalidExtensionParameter,
        parsePerMessageDeflateFirst("permessage-deflate; server_no_context_takeover=1"),
    );
    try std.testing.expectError(
        error.InvalidExtensionParameter,
        parsePerMessageDeflateFirst("permessage-deflate; server_max_window_bits=99"),
    );
    try std.testing.expectError(
        error.DuplicateExtensionParameter,
        parsePerMessageDeflateFirst("permessage-deflate; client_no_context_takeover; client_no_context_takeover"),
    );
    try std.testing.expectError(
        error.DuplicateExtensionParameter,
        parsePerMessageDeflateFirst("permessage-deflate; client_max_window_bits; client_max_window_bits=15"),
    );
}

test "parsePerMessageDeflate preserves repeated offers as alternatives" {
    var offers = parsePerMessageDeflate(
        "permessage-deflate; client_no_context_takeover, permessage-deflate",
    );
    try std.testing.expectEqualDeep(
        PerMessageDeflate{
            .server_no_context_takeover = false,
            .client_no_context_takeover = true,
        },
        (try offers.next()).?,
    );
    try std.testing.expectEqualDeep(
        PerMessageDeflate{
            .server_no_context_takeover = false,
            .client_no_context_takeover = false,
        },
        (try offers.next()).?,
    );
    try std.testing.expectEqual(@as(?PerMessageDeflate, null), try offers.next());
    try std.testing.expectError(
        error.DuplicateExtensionOffer,
        parsePerMessageDeflateFirst("permessage-deflate, permessage-deflate; client_no_context_takeover"),
    );
}

test "parsePerMessageDeflate iterator propagates malformed offers after valid alternatives" {
    var offers = parsePerMessageDeflate(
        "permessage-deflate; client_no_context_takeover, permessage-deflate; server_max_window_bits=99",
    );

    try std.testing.expectEqualDeep(
        PerMessageDeflate{
            .server_no_context_takeover = false,
            .client_no_context_takeover = true,
        },
        (try offers.next()).?,
    );
    try std.testing.expectError(error.InvalidExtensionParameter, offers.next());
}

test "parsePerMessageDeflate iterator stays exhausted after reaching the end" {
    var offers = parsePerMessageDeflate("foo, permessage-deflate");
    try std.testing.expectEqualDeep(
        PerMessageDeflate{
            .server_no_context_takeover = false,
            .client_no_context_takeover = false,
        },
        (try offers.next()).?,
    );
    try std.testing.expectEqual(@as(?PerMessageDeflate, null), try offers.next());
    try std.testing.expectEqual(@as(?PerMessageDeflate, null), try offers.next());
}

test "parseWindowBits accepts RFC range only" {
    try std.testing.expectEqual(@as(u8, 8), try parseWindowBits("8"));
    try std.testing.expectEqual(@as(u8, 15), try parseWindowBits("15"));
    try std.testing.expectError(error.InvalidWindowBits, parseWindowBits("7"));
    try std.testing.expectError(error.InvalidWindowBits, parseWindowBits("16"));
    try std.testing.expectError(error.InvalidWindowBits, parseWindowBits("abc"));
}

test "PerMessageDeflate responseHeaderValue covers the supported parameter combinations" {
    const both = PerMessageDeflate{ .server_no_context_takeover = true, .client_no_context_takeover = true };
    const server_only = PerMessageDeflate{ .client_no_context_takeover = false };
    const client_only = PerMessageDeflate{ .server_no_context_takeover = false };
    const none = PerMessageDeflate{
        .server_no_context_takeover = false,
        .client_no_context_takeover = false,
    };
    try std.testing.expectEqualStrings(
        "permessage-deflate; server_no_context_takeover; client_no_context_takeover",
        both.responseHeaderValue(),
    );
    try std.testing.expectEqualStrings(
        "permessage-deflate; server_no_context_takeover",
        server_only.responseHeaderValue(),
    );
    try std.testing.expectEqualStrings(
        "permessage-deflate; client_no_context_takeover",
        client_only.responseHeaderValue(),
    );
    try std.testing.expectEqualStrings(
        "permessage-deflate",
        none.responseHeaderValue(),
    );
}
