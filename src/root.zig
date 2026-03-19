//! Low-allocation RFC 6455 websocket primitives for Zig.
//!
//! The hot-path API is `Conn`, which exposes:
//! - low-level frame streaming (`beginFrame`, `readFrameChunk`, `readFrameAll`, `discardFrame`)
//! - convenience helpers (`readFrame`, `readMessage`, `writeFrame`, `writeText`, `writeBinary`)
//! - strict server handshake validation (`acceptServerHandshake`, `writeServerHandshakeResponse`)
const proto = @import("protocol.zig");

pub const Role = proto.Role;
pub const Opcode = proto.Opcode;
pub const MessageOpcode = proto.MessageOpcode;
pub const CloseCode = proto.CloseCode;
pub const isControl = proto.isControl;
pub const isData = proto.isData;
pub const isValidCloseCode = proto.isValidCloseCode;

pub const Header = @import("handshake.zig").Header;
pub const ServerHandshakeRequest = @import("handshake.zig").ServerHandshakeRequest;
pub const ServerHandshakeOptions = @import("handshake.zig").ServerHandshakeOptions;
pub const ServerHandshakeResponse = @import("handshake.zig").ServerHandshakeResponse;
pub const HandshakeError = @import("handshake.zig").HandshakeError;
pub const computeAcceptKey = @import("handshake.zig").computeAcceptKey;
pub const acceptServerHandshake = @import("handshake.zig").acceptServerHandshake;
pub const writeServerHandshakeResponse = @import("handshake.zig").writeServerHandshakeResponse;
pub const serverHandshake = @import("handshake.zig").serverHandshake;

pub const StaticConfig = @import("conn.zig").StaticConfig;
pub const Config = @import("conn.zig").Config;
pub const ProtocolError = @import("conn.zig").ProtocolError;
pub const FrameHeader = @import("conn.zig").FrameHeader;
pub const Frame = @import("conn.zig").Frame;
pub const Message = @import("conn.zig").Message;
pub const CloseFrame = @import("conn.zig").CloseFrame;
pub const BorrowedFrame = @import("conn.zig").BorrowedFrame;
pub const EchoResult = @import("conn.zig").EchoResult;
pub const ConnType = @import("conn.zig").Conn;
pub const Conn = @import("conn.zig").Conn(.{});
pub const ServerConn = @import("conn.zig").Conn(.{ .role = .server });
pub const ClientConn = @import("conn.zig").Conn(.{ .role = .client });
pub const parseClosePayload = @import("conn.zig").parseClosePayload;

test {
    _ = @import("protocol.zig");
    _ = @import("handshake.zig");
    _ = @import("conn.zig");
}
