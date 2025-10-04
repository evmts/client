//! RLPx protocol implementation
//! Based on Erigon's p2p/rlpx/rlpx.go
//!
//! RLPx is the encrypted transport protocol for Ethereum P2P.
//! Spec: https://github.com/ethereum/devp2p/blob/master/rlpx.md
//!
//! Protocol overview:
//! 1. ECIES handshake to establish shared secrets (EIP-8 format)
//! 2. Derive AES and MAC keys from ECDH ephemeral shared secret
//! 3. Frame-based message protocol with AES-CTR encryption
//! 4. Each frame: [header(16)+headerMAC(16)][frameData(padded)+frameMAC(16)]
//! 5. Optional snappy compression after Hello exchange

const std = @import("std");
const net = std.net;
const crypto = std.crypto;
const Allocator = std.mem.Allocator;

// Import snappy compression (vendored)
const snappy = @import("snappy.zig");

// Import guillotine crypto primitives for secp256k1 operations
const guillotine = @import("guillotine");
const secp256k1 = guillotine.crypto.secp256k1;

// Constants
const maxUint24: u32 = 0xFFFFFF;
const eciesOverhead: usize = 65 + 16 + 32; // pubkey + IV + MAC
const zeroHeader = [_]u8{ 0xC2, 0x80, 0x80 }; // RLP empty list format

/// Errors that can occur during RLPx operations
pub const Error = error{
    NoSession,
    NoCipher,
    IncompleteFrame,
    InvalidHeaderMAC,
    InvalidFrameMAC,
    InvalidAuthMessage,
    InvalidAckMessage,
    MessageTooLarge,
    HandshakeFailed,
    InvalidPublicKey,
    InvalidPrivateKey,
    ECDHFailed,
    OutOfMemory,
    ConnectionClosed,
    IOError,
    CompressionFailed,
    DecompressionFailed,
    DecompressedTooLarge,
};

/// RLPx connection wrapping a TCP stream
pub const Conn = struct {
    allocator: Allocator,
    stream: net.Stream,
    session: ?*SessionState,
    dial_dest: ?[64]u8, // Remote public key (64 bytes uncompressed)
    snappy_enabled: bool,

    const Self = @This();

    /// Create a new RLPx connection
    /// dial_dest should be the remote node's 64-byte public key if we are the initiator
    pub fn init(allocator: Allocator, stream: net.Stream, dial_dest: ?[64]u8) Self {
        return .{
            .allocator = allocator,
            .stream = stream,
            .session = null,
            .dial_dest = dial_dest,
            .snappy_enabled = false,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.session) |session| {
            session.deinit();
            self.allocator.destroy(session);
        }
        self.stream.close();
    }

    /// Perform the RLPx encryption handshake
    /// priv_key: Our 32-byte private key
    /// Returns the remote peer's public key on success
    pub fn handshake(self: *Self, priv_key: [32]u8) ![64]u8 {
        var handshake_state = HandshakeState.init(self.allocator);
        defer handshake_state.deinit();

        const secrets = if (self.dial_dest) |remote_pub|
            try handshake_state.runInitiator(&self.stream, priv_key, remote_pub)
        else
            try handshake_state.runRecipient(&self.stream, priv_key);

        // Initialize session with derived secrets
        self.session = try self.allocator.create(SessionState);
        errdefer self.allocator.destroy(self.session.?);

        try self.session.?.init(self.allocator, secrets);

        return secrets.remote_pubkey;
    }

    /// Enable or disable snappy compression
    pub fn setSnappy(self: *Self, enabled: bool) void {
        self.snappy_enabled = enabled;
    }

    /// Read a message from the connection
    /// Returns: (message_code, payload_data, wire_size)
    /// The payload buffer is owned by the caller and must be freed
    pub fn readMsg(self: *Self) !struct { code: u64, data: []u8, wireSize: usize } {
        const session = self.session orelse return Error.NoSession;

        // Read encrypted frame
        const frame = try session.readFrame(&self.stream);
        defer self.allocator.free(frame);

        // Decode RLP: [code, data]
        if (frame.len == 0) return Error.InvalidFrameMAC;

        // First byte is code as single-byte RLP or RLP encoded
        var pos: usize = 0;
        const code: u64 = blk: {
            if (frame[0] < 0x80) {
                // Single byte value
                pos = 1;
                break :blk frame[0];
            } else if (frame[0] < 0xB8) {
                // Short string encoding
                const len = frame[0] - 0x80;
                if (len == 0) break :blk 0;
                if (len > 8) return error.InvalidMessage;
                var val: u64 = 0;
                pos = 1 + len;
                for (frame[1..pos]) |b| {
                    val = (val << 8) | b;
                }
                break :blk val;
            } else {
                return error.InvalidMessage;
            }
        };

        var data = frame[pos..];
        const wireSize = data.len;

        // Decompress if snappy is enabled
        // This matches Erigon's implementation (rlpx.go:150-163)
        var decompressed_data: ?[]u8 = null;
        if (self.snappy_enabled and data.len > 0) {
            // Decode the snappy-compressed data
            decompressed_data = snappy.decode(self.allocator, data) catch |err| {
                std.debug.print("Snappy decompression failed: {}\n", .{err});
                return Error.DecompressionFailed;
            };

            // Validate decompressed size doesn't exceed max
            if (decompressed_data.?.len > maxUint24) {
                self.allocator.free(decompressed_data.?);
                return Error.DecompressedTooLarge;
            }

            data = decompressed_data.?;
        }

        // Allocate and copy payload for caller
        const payload = try self.allocator.dupe(u8, data);

        // Free decompressed buffer if we created one
        if (decompressed_data) |decompressed| {
            self.allocator.free(decompressed);
        }

        return .{ .code = code, .data = payload, .wireSize = wireSize };
    }

    /// Write a message to the connection
    /// Returns the wire size (may be compressed)
    pub fn writeMsg(self: *Self, code: u64, payload: []const u8) !u32 {
        const session = self.session orelse return Error.NoSession;

        if (payload.len > maxUint24) return Error.MessageTooLarge;

        // Compress if snappy is enabled
        // This matches Erigon's implementation (rlpx.go:222-228)
        var compressed_data: ?[]u8 = null;
        var data = payload;

        if (self.snappy_enabled) {
            // Encode the data with snappy compression
            compressed_data = snappy.encode(self.allocator, @constCast(payload)) catch |err| {
                std.debug.print("Snappy compression failed: {}\n", .{err});
                return Error.CompressionFailed;
            };
            data = compressed_data.?;
        }
        defer if (compressed_data) |compressed| {
            self.allocator.free(compressed);
        };

        const wireSize: u32 = @intCast(data.len);

        // Encode as RLP: [code, data]
        var encoded = std.ArrayList(u8).init(self.allocator);
        defer encoded.deinit();

        // Encode code
        if (code == 0) {
            try encoded.append(0x80); // Empty string
        } else if (code < 0x80) {
            try encoded.append(@intCast(code));
        } else if (code < 0x100) {
            try encoded.append(0x81);
            try encoded.append(@intCast(code));
        } else {
            // Multi-byte encoding
            var temp: [8]u8 = undefined;
            var len: usize = 0;
            var val = code;
            while (val > 0) : (len += 1) {
                temp[7 - len] = @intCast(val & 0xFF);
                val >>= 8;
            }
            try encoded.append(0x80 + @as(u8, @intCast(len)));
            try encoded.appendSlice(temp[8 - len ..]);
        }

        // Append payload (compressed or not)
        try encoded.appendSlice(data);

        // Write frame
        try session.writeFrame(&self.stream, encoded.items);

        return wireSize;
    }
};

/// Session secrets derived from handshake
const Secrets = struct {
    remote_pubkey: [64]u8,
    aes: [32]u8, // AES-256 key
    mac: [16]u8, // MAC key (AES-128)
    egress_mac: crypto.hash.sha3.Keccak256, // Egress MAC state
    ingress_mac: crypto.hash.sha3.Keccak256, // Ingress MAC state
};

/// Encryption session state
pub const SessionState = struct {
    allocator: Allocator,
    enc_cipher: crypto.core.aes.Aes256, // Egress AES-256
    dec_cipher: crypto.core.aes.Aes256, // Ingress AES-256
    mac_cipher: crypto.core.aes.Aes128, // MAC encryption
    egress_mac: crypto.hash.sha3.Keccak256,
    ingress_mac: crypto.hash.sha3.Keccak256,
    enc_ctr: [16]u8, // Encryption counter
    dec_ctr: [16]u8, // Decryption counter
    read_buf: ReadBuffer,
    write_buf: WriteBuffer,

    const Self = @This();

    pub fn init(self: *Self, allocator: Allocator, secrets: Secrets) !void {
        self.allocator = allocator;
        self.enc_cipher = crypto.core.aes.Aes256.initEnc(secrets.aes);
        self.dec_cipher = crypto.core.aes.Aes256.initEnc(secrets.aes); // CTR uses encrypt for both
        self.mac_cipher = crypto.core.aes.Aes128.initEnc(secrets.mac);
        self.egress_mac = secrets.egress_mac;
        self.ingress_mac = secrets.ingress_mac;
        @memset(&self.enc_ctr, 0);
        @memset(&self.dec_ctr, 0);
        self.read_buf = ReadBuffer.init();
        self.write_buf = WriteBuffer.init();
    }

    pub fn deinit(self: *Self) void {
        self.read_buf.deinit(self.allocator);
        self.write_buf.deinit(self.allocator);
    }

    /// Read and decrypt a frame
    pub fn readFrame(self: *Self, stream: *net.Stream) ![]u8 {
        self.read_buf.reset();

        // Read header (16 bytes encrypted + 16 bytes MAC)
        const header_data = try self.read_buf.read(self.allocator, stream, 32);
        const header_enc = header_data[0..16];
        const header_mac = header_data[16..32];

        // Verify header MAC
        const want_mac = self.updateIngressMAC(header_enc);
        if (!std.mem.eql(u8, &want_mac, header_mac)) {
            return Error.InvalidHeaderMAC;
        }

        // Decrypt header
        var header_plain: [16]u8 = undefined;
        self.xorKeyStream(&self.dec_cipher, &self.dec_ctr, &header_plain, header_enc);

        // Parse frame size (first 3 bytes, big-endian)
        const frame_size: u32 = (@as(u32, header_plain[0]) << 16) |
            (@as(u32, header_plain[1]) << 8) |
            @as(u32, header_plain[2]);

        // Calculate padded size (must be multiple of 16)
        const padding = if (frame_size % 16 == 0) @as(u32, 0) else 16 - (frame_size % 16);
        const padded_size = frame_size + padding;

        // Read frame data + MAC
        const frame_data = try self.read_buf.read(self.allocator, stream, padded_size + 16);
        const frame_enc = frame_data[0..padded_size];
        const frame_mac = frame_data[padded_size .. padded_size + 16];

        // Verify frame MAC
        const want_frame_mac = self.updateIngressMACFrame(frame_enc);
        if (!std.mem.eql(u8, &want_frame_mac, frame_mac)) {
            return Error.InvalidFrameMAC;
        }

        // Decrypt frame
        const decrypted = try self.allocator.alloc(u8, frame_size);
        errdefer self.allocator.free(decrypted);

        self.xorKeyStream(&self.dec_cipher, &self.dec_ctr, decrypted, frame_enc[0..frame_size]);

        return decrypted;
    }

    /// Encrypt and write a frame
    pub fn writeFrame(self: *Self, stream: *net.Stream, data: []const u8) !void {
        const frame_size: u32 = @intCast(data.len);
        if (frame_size > maxUint24) return Error.MessageTooLarge;

        // Calculate padding
        const padding = if (frame_size % 16 == 0) @as(usize, 0) else 16 - (frame_size % 16);
        const padded_size = frame_size + padding;

        self.write_buf.reset();

        // Build and encrypt header
        var header: [16]u8 = undefined;
        header[0] = @intCast((frame_size >> 16) & 0xFF);
        header[1] = @intCast((frame_size >> 8) & 0xFF);
        header[2] = @intCast(frame_size & 0xFF);
        @memcpy(header[3..6], &zeroHeader);
        @memset(header[6..16], 0);

        var header_enc: [16]u8 = undefined;
        self.xorKeyStream(&self.enc_cipher, &self.enc_ctr, &header_enc, &header);

        // Compute and append header MAC
        const header_mac = self.updateEgressMAC(&header_enc);
        try self.write_buf.write(self.allocator, &header_enc);
        try self.write_buf.write(self.allocator, &header_mac);

        // Encrypt frame data
        const encrypted = try self.allocator.alloc(u8, padded_size);
        defer self.allocator.free(encrypted);

        @memcpy(encrypted[0..data.len], data);
        if (padding > 0) {
            @memset(encrypted[data.len..], 0);
        }

        self.xorKeyStream(&self.enc_cipher, &self.enc_ctr, encrypted, encrypted);

        // Compute and append frame MAC
        const frame_mac = self.updateEgressMACFrame(encrypted);
        try self.write_buf.write(self.allocator, encrypted);
        try self.write_buf.write(self.allocator, &frame_mac);

        // Write to stream
        _ = try stream.write(self.write_buf.data.items);
    }

    // MAC computation following Erigon's "horrible, legacy thing"
    fn updateEgressMAC(self: *Self, data: []const u8) [16]u8 {
        var seed: [32]u8 = undefined;
        self.egress_mac.final(&seed);
        self.egress_mac = crypto.hash.sha3.Keccak256.init(.{});
        self.egress_mac.update(&seed);

        var encrypted: [16]u8 = undefined;
        self.mac_cipher.encrypt(&encrypted, seed[0..16]);

        for (&encrypted, data[0..16]) |*e, d| {
            e.* ^= d;
        }

        self.egress_mac.update(&encrypted);
        self.egress_mac.final(&seed);
        self.egress_mac = crypto.hash.sha3.Keccak256.init(.{});
        self.egress_mac.update(&seed);

        return encrypted;
    }

    fn updateEgressMACFrame(self: *Self, data: []const u8) [16]u8 {
        self.egress_mac.update(data);
        var seed: [32]u8 = undefined;
        self.egress_mac.final(&seed);
        self.egress_mac = crypto.hash.sha3.Keccak256.init(.{});
        self.egress_mac.update(&seed);

        return self.updateEgressMAC(seed[0..16]);
    }

    fn updateIngressMAC(self: *Self, data: []const u8) [16]u8 {
        var seed: [32]u8 = undefined;
        self.ingress_mac.final(&seed);
        self.ingress_mac = crypto.hash.sha3.Keccak256.init(.{});
        self.ingress_mac.update(&seed);

        var encrypted: [16]u8 = undefined;
        self.mac_cipher.encrypt(&encrypted, seed[0..16]);

        for (&encrypted, data[0..16]) |*e, d| {
            e.* ^= d;
        }

        self.ingress_mac.update(&encrypted);
        self.ingress_mac.final(&seed);
        self.ingress_mac = crypto.hash.sha3.Keccak256.init(.{});
        self.ingress_mac.update(&seed);

        return encrypted;
    }

    fn updateIngressMACFrame(self: *Self, data: []const u8) [16]u8 {
        self.ingress_mac.update(data);
        var seed: [32]u8 = undefined;
        self.ingress_mac.final(&seed);
        self.ingress_mac = crypto.hash.sha3.Keccak256.init(.{});
        self.ingress_mac.update(&seed);

        return self.updateIngressMAC(seed[0..16]);
    }

    fn xorKeyStream(
        self: *Self,
        cipher: *const crypto.core.aes.Aes256,
        ctr: *[16]u8,
        dst: []u8,
        src: []const u8,
    ) void {
        _ = self;
        var i: usize = 0;
        while (i < src.len) : (i += 16) {
            var keystream: [16]u8 = undefined;
            cipher.encrypt(&keystream, ctr);

            const n = @min(16, src.len - i);
            for (0..n) |j| {
                dst[i + j] = src[i + j] ^ keystream[j];
            }

            // Increment counter
            var carry: u16 = 1;
            var k: usize = 16;
            while (k > 0 and carry > 0) {
                k -= 1;
                carry += ctr[k];
                ctr[k] = @intCast(carry & 0xFF);
                carry >>= 8;
            }
        }
    }
};

/// Handshake state
const HandshakeState = struct {
    allocator: Allocator,
    initiator: bool,
    remote_pubkey: [64]u8,
    init_nonce: [32]u8,
    resp_nonce: [32]u8,
    ephemeral_priv: [32]u8,
    remote_ephemeral_pub: [64]u8,

    fn init(allocator: Allocator) HandshakeState {
        return .{
            .allocator = allocator,
            .initiator = false,
            .remote_pubkey = undefined,
            .init_nonce = undefined,
            .resp_nonce = undefined,
            .ephemeral_priv = undefined,
            .remote_ephemeral_pub = undefined,
        };
    }

    fn deinit(self: *HandshakeState) void {
        _ = self;
        // Sensitive data cleanup
        // In production, securely zero out private keys
    }

    /// Run initiator handshake
    fn runInitiator(
        self: *HandshakeState,
        stream: *net.Stream,
        priv_key: [32]u8,
        remote_pub: [64]u8,
    ) !Secrets {
        self.initiator = true;
        self.remote_pubkey = remote_pub;

        // Generate ephemeral key and nonce
        crypto.random.bytes(&self.ephemeral_priv);
        crypto.random.bytes(&self.init_nonce);

        // Create and send auth message
        const auth_msg = try self.makeAuthMsg(priv_key);
        defer self.allocator.free(auth_msg);
        _ = try stream.write(auth_msg);

        // Receive auth-ack
        var ack_size_buf: [2]u8 = undefined;
        _ = try stream.read(&ack_size_buf);
        const ack_size = std.mem.readInt(u16, &ack_size_buf, .big);

        const ack_msg = try self.allocator.alloc(u8, ack_size);
        defer self.allocator.free(ack_msg);
        _ = try stream.read(ack_msg);

        // Process auth-ack
        try self.handleAuthResp(priv_key, ack_msg);

        // Derive secrets
        const full_ack = try self.allocator.alloc(u8, 2 + ack_size);
        defer self.allocator.free(full_ack);
        @memcpy(full_ack[0..2], &ack_size_buf);
        @memcpy(full_ack[2..], ack_msg);

        return try self.deriveSecrets(auth_msg, full_ack);
    }

    /// Run recipient handshake
    fn runRecipient(
        self: *HandshakeState,
        stream: *net.Stream,
        priv_key: [32]u8,
    ) !Secrets {
        self.initiator = false;

        // Generate ephemeral key and nonce
        crypto.random.bytes(&self.ephemeral_priv);
        crypto.random.bytes(&self.resp_nonce);

        // Receive auth message
        var auth_size_buf: [2]u8 = undefined;
        _ = try stream.read(&auth_size_buf);
        const auth_size = std.mem.readInt(u16, &auth_size_buf, .big);

        const auth_msg = try self.allocator.alloc(u8, auth_size);
        defer self.allocator.free(auth_msg);
        _ = try stream.read(auth_msg);

        // Process auth
        try self.handleAuthMsg(priv_key, auth_msg);

        // Create and send auth-ack
        const ack_msg = try self.makeAuthResp();
        defer self.allocator.free(ack_msg);
        _ = try stream.write(ack_msg);

        // Derive secrets
        const full_auth = try self.allocator.alloc(u8, 2 + auth_size);
        defer self.allocator.free(full_auth);
        @memcpy(full_auth[0..2], &auth_size_buf);
        @memcpy(full_auth[2..], auth_msg);

        return try self.deriveSecrets(full_auth, ack_msg);
    }

    fn makeAuthMsg(self: *HandshakeState, priv_key: [32]u8) ![]u8 {
        // Build auth message struct (authMsgV4 from Erigon)
        // Signature: sign(static-shared-secret ^ nonce, ephemeral-privkey)
        // InitiatorPubkey: our static public key (64 bytes uncompressed)
        // Nonce: random 32 bytes
        // Version: 4 (EIP-8)

        // 1. Calculate static shared secret using ECDH
        const static_shared = try self.ecdhSharedSecret(priv_key, self.remote_pubkey);

        // 2. XOR static shared secret with init nonce
        var signed_data: [32]u8 = undefined;
        for (static_shared, self.init_nonce, 0..) |ss, n, i| {
            signed_data[i] = ss ^ n;
        }

        // 3. Sign with ephemeral private key
        const signature = try self.sign(signed_data, self.ephemeral_priv);

        // 4. Get our public key from private key
        const our_pubkey = try self.publicKeyFromPrivate(priv_key);

        // 5. Encode auth message as RLP: [signature, initiator-pubkey, nonce, version]
        var msg_buf = std.ArrayList(u8).init(self.allocator);
        defer msg_buf.deinit();

        // RLP encode manually (simplified - real RLP would be more complex)
        try msg_buf.appendSlice(&signature); // 65 bytes
        try msg_buf.appendSlice(&our_pubkey); // 64 bytes
        try msg_buf.appendSlice(&self.init_nonce); // 32 bytes
        try msg_buf.append(4); // version

        // 6. Add random padding (100-300 bytes) for EIP-8
        var rng = crypto.random;
        const padding_len = 100 + (rng.int(u8) % 200);
        var i: usize = 0;
        while (i < padding_len) : (i += 1) {
            try msg_buf.append(0);
        }

        // 7. Encrypt with ECIES using remote public key
        return try self.sealEIP8(msg_buf.items, self.remote_pubkey);
    }

    fn makeAuthResp(self: *HandshakeState) ![]u8 {
        _ = self;
        // TODO: Implement proper EIP-8 auth response with ECIES encryption
        return Error.HandshakeFailed;
    }

    fn handleAuthMsg(self: *HandshakeState, priv_key: [32]u8, auth_msg: []const u8) !void {
        _ = self;
        _ = priv_key;
        _ = auth_msg;
        // TODO: Implement proper auth message decryption and validation
        return Error.HandshakeFailed;
    }

    fn handleAuthResp(self: *HandshakeState, priv_key: [32]u8, ack_msg: []const u8) !void {
        _ = self;
        _ = priv_key;
        _ = ack_msg;
        // TODO: Implement proper auth-ack decryption and validation
        return Error.HandshakeFailed;
    }

    fn deriveSecrets(self: *HandshakeState, auth: []const u8, authResp: []const u8) !Secrets {
        _ = auth;
        _ = authResp;

        // TODO: Implement proper ECDH secret derivation and key derivation
        // This should:
        // 1. Compute ECDH shared secret from ephemeral keys
        // 2. Derive AES and MAC keys using Keccak256
        // 3. Initialize MAC states

        var secrets: Secrets = undefined;
        secrets.remote_pubkey = self.remote_pubkey;

        // Placeholder - would be derived from ECDH
        @memset(&secrets.aes, 0);
        @memset(&secrets.mac, 0);

        secrets.egress_mac = crypto.hash.sha3.Keccak256.init(.{});
        secrets.ingress_mac = crypto.hash.sha3.Keccak256.init(.{});

        return secrets;
    }
};

/// Read buffer for network operations
const ReadBuffer = struct {
    data: std.ArrayList(u8),
    end: usize,

    fn init() ReadBuffer {
        return .{
            .data = std.ArrayList(u8){},
            .end = 0,
        };
    }

    fn deinit(self: *ReadBuffer, allocator: Allocator) void {
        self.data.deinit(allocator);
    }

    fn reset(self: *ReadBuffer) void {
        const unprocessed = self.end - self.data.items.len;
        if (unprocessed > 0) {
            std.mem.copyForwards(u8, self.data.items[0..unprocessed], self.data.items[self.data.items.len..self.end]);
        }
        self.end = unprocessed;
        self.data.clearRetainingCapacity();
    }

    fn read(self: *ReadBuffer, allocator: Allocator, stream: *net.Stream, n: usize) ![]u8 {
        if (self.data.items.ptr == null) {
            self.data = std.ArrayList(u8).init(allocator);
        }

        const offset = self.data.items.len;
        const have = self.end - self.data.items.len;

        if (have >= n) {
            try self.data.resize(allocator, offset + n);
            return self.data.items[offset .. offset + n];
        }

        const need = n - have;
        try self.data.resize(allocator, self.end + need);

        const bytes_read = try stream.read(self.data.items[self.end..]);
        if (bytes_read < need) return Error.ConnectionClosed;

        self.end += bytes_read;
        try self.data.resize(allocator, offset + n);

        return self.data.items[offset .. offset + n];
    }
};

/// Write buffer for network operations
const WriteBuffer = struct {
    data: std.ArrayList(u8),

    fn init() WriteBuffer {
        return .{ .data = std.ArrayList(u8){} };
    }

    fn deinit(self: *WriteBuffer, allocator: Allocator) void {
        self.data.deinit(allocator);
    }

    fn reset(self: *WriteBuffer) void {
        self.data.clearRetainingCapacity();
    }

    fn write(self: *WriteBuffer, allocator: Allocator, bytes: []const u8) !void {
        if (self.data.items.ptr == null) {
            self.data = std.ArrayList(u8).init(allocator);
        }
        try self.data.appendSlice(allocator, bytes);
    }
};

test "RLPx buffer operations" {
    const allocator = std.testing.allocator;

    // Test WriteBuffer
    var wb = WriteBuffer.init();
    defer wb.deinit(allocator);

    try wb.write(allocator, &[_]u8{ 1, 2, 3 });
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3 }, wb.data.items);

    wb.reset();
    try std.testing.expectEqual(@as(usize, 0), wb.data.items.len);
}
