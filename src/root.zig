//! Low-allocation RFC 6455 websocket primitives for Zig.
//!
//! The hot-path API is `Conn`, which exposes:
//! - low-level frame streaming (`beginFrame`, `readFrameChunk`, `readFrameAll`, `discardFrame`)
//! - convenience helpers (`readFrame`, `readMessage`, `writeFrame`, `writeText`, `writeBinary`)
//! - strict server handshake validation (`acceptServerHandshake`, `writeServerHandshakeResponse`)
//! - `zhttp` compatibility helpers for upgrade routes and `101` response construction
//!
//! `ConnType` exposes the comptime-specialized connection type constructor.
//! `Conn`, `ServerConn`, and `ClientConn` are convenient aliases for common
//! configurations.
const proto = @import("protocol.zig");
const handshake = @import("handshake.zig");
const conn = @import("conn.zig");
const zhttp_compat = @import("zhttp_compat.zig");

pub const Role = proto.Role;
pub const Opcode = proto.Opcode;
pub const MessageOpcode = proto.MessageOpcode;
pub const CloseCode = proto.CloseCode;
pub const isControl = proto.isControl;
pub const isData = proto.isData;
pub const isValidCloseCode = proto.isValidCloseCode;

pub const Header = handshake.Header;
pub const ServerHandshakeRequest = handshake.ServerHandshakeRequest;
pub const ServerHandshakeOptions = handshake.ServerHandshakeOptions;
pub const ServerHandshakeResponse = handshake.ServerHandshakeResponse;
pub const HandshakeError = handshake.HandshakeError;
pub const computeAcceptKey = handshake.computeAcceptKey;
pub const acceptServerHandshake = handshake.acceptServerHandshake;
pub const writeServerHandshakeResponse = handshake.writeServerHandshakeResponse;
pub const serverHandshake = handshake.serverHandshake;

pub const ZhttpCompatError = zhttp_compat.CompatError;
pub const ZhttpUpgradeHeaders = zhttp_compat.UpgradeHeaders;
pub const zhttpRequestFromHeaders = zhttp_compat.requestFromHeaders;
pub const zhttpRequest = zhttp_compat.requestFromZhttp;
pub const acceptZhttpUpgrade = zhttp_compat.acceptZhttpUpgrade;
pub const zhttpResponseHeaderCount = zhttp_compat.responseHeaderCount;
pub const fillZhttpResponseHeaders = zhttp_compat.fillResponseHeaders;
pub const makeZhttpUpgradeResponse = zhttp_compat.makeUpgradeResponse;

pub const StaticConfig = conn.StaticConfig;
pub const Config = conn.Config;
pub const ProtocolError = conn.ProtocolError;
pub const FrameHeader = conn.FrameHeader;
pub const Frame = conn.Frame;
pub const Message = conn.Message;
pub const CloseFrame = conn.CloseFrame;
pub const BorrowedFrame = conn.BorrowedFrame;
pub const EchoResult = conn.EchoResult;
pub const ConnType = conn.Conn;
pub const Conn = conn.Conn(.{});
pub const ServerConn = conn.Conn(.{ .role = .server });
pub const ClientConn = conn.Conn(.{ .role = .client });
pub const parseClosePayload = conn.parseClosePayload;

test {
    _ = @import("protocol.zig");
    _ = @import("handshake.zig");
    _ = @import("conn.zig");
    _ = @import("zhttp_compat.zig");
}
