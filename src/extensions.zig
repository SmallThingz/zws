const std = @import("std");

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

pub fn offersPerMessageDeflate(header_value: []const u8) bool {
    var extension_it = std.mem.splitScalar(u8, header_value, ',');
    while (extension_it.next()) |extension_part| {
        var param_it = std.mem.splitScalar(u8, extension_part, ';');
        const name = std.mem.trim(u8, param_it.next() orelse continue, " \t");
        if (std.ascii.eqlIgnoreCase(name, "permessage-deflate")) return true;
    }
    return false;
}

test "offersPerMessageDeflate matches extension tokens regardless of parameters" {
    try std.testing.expect(offersPerMessageDeflate("permessage-deflate"));
    try std.testing.expect(offersPerMessageDeflate("permessage-deflate; client_max_window_bits"));
    try std.testing.expect(offersPerMessageDeflate("foo, permessage-deflate; client_no_context_takeover"));
    try std.testing.expect(!offersPerMessageDeflate("permessage-deflatex"));
    try std.testing.expect(!offersPerMessageDeflate("x-webkit-deflate-frame"));
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
