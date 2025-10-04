//! RLPx protocol implementation
//! Based on Erigon's p2p/rlpx/rlpx.go
//!
//! RLPx is the encrypted transport protocol for Ethereum P2P.
//! Spec: https://github.com/ethereum/devp2p/blob/master/rlpx.md

const std = @import("std");
const crypto = @import("../crypto.zig");
const rlp = @import("../rlp.zig");

/// RLPx connection wrapping a TCP socket
pub const Conn = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    session: ?*SessionState,
    dial_dest: ?[]const u8, // Remote public key if initiator
    snappy_enabled: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, stream: std.net.Stream, dial_dest: ?[]const u8) Self {
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

    /// Perform RLPx handshake
    pub fn handshake(self: *Self, priv_key: []const u8) !void {
        if (self.dial_dest) |remote_pub| {
            // Initiator side
            try self.initiatorHandshake(priv_key, remote_pub);
        } else {
            // Receiver side
            try self.receiverHandshake(priv_key);
        }
    }

    /// Initiator handshake (we are dialing out)
    fn initiatorHandshake(self: *Self, priv_key: []const u8, remote_pub: []const u8) !void {
        // 1. Generate ephemeral key pair
        var ephemeral_priv: [32]u8 = undefined;
        try std.crypto.random.bytes(&ephemeral_priv);

        // 2. Derive shared secret using ECDH
        const shared_secret = try ecdhSharedSecret(priv_key, remote_pub);

        // 3. Send auth message
        const auth_msg = try self.makeAuthMsg(priv_key, &ephemeral_priv, remote_pub, &shared_secret);
        defer self.allocator.free(auth_msg);

        try self.stream.writeAll(auth_msg);

        // 4. Receive auth-ack message
        var ack_buf: [307]u8 = undefined; // Auth-ack size
        const ack_len = try self.stream.read(&ack_buf);
        const ack_msg = ack_buf[0..ack_len];

        // 5. Decrypt and process ack
        const remote_ephemeral_pub = try self.processAuthAck(ack_msg, &shared_secret);

        // 6. Derive session secrets
        self.session = try self.allocator.create(SessionState);
        try self.session.?.initFromHandshake(
            self.allocator,
            &ephemeral_priv,
            remote_ephemeral_pub,
            &shared_secret,
            true, // initiator
        );
    }

    /// Receiver handshake (we received incoming connection)
    fn receiverHandshake(self: *Self, priv_key: []const u8) !void {
        // 1. Receive auth message
        var auth_buf: [307]u8 = undefined; // Auth message size
        const auth_len = try self.stream.read(&auth_buf);
        const auth_msg = auth_buf[0..auth_len];

        // 2. Process auth and extract initiator info
        const initiator_info = try self.processAuth(auth_msg, priv_key);
        defer self.allocator.free(initiator_info.ephemeral_pub);

        // 3. Generate our ephemeral key
        var ephemeral_priv: [32]u8 = undefined;
        try std.crypto.random.bytes(&ephemeral_priv);

        // 4. Send auth-ack
        const ack_msg = try self.makeAuthAck(&ephemeral_priv, initiator_info.shared_secret);
        defer self.allocator.free(ack_msg);

        try self.stream.writeAll(ack_msg);

        // 5. Derive session secrets
        self.session = try self.allocator.create(SessionState);
        try self.session.?.initFromHandshake(
            self.allocator,
            &ephemeral_priv,
            initiator_info.ephemeral_pub,
            initiator_info.shared_secret,
            false, // receiver
        );
    }

    /// Read a message from the connection
    pub fn readMsg(self: *Self) !Message {
        if (self.session == null) return error.NoSession;

        const frame = try self.session.?.readFrame(&self.stream);
        defer self.allocator.free(frame);

        // Decode message code and payload
        var decoder = rlp.Decoder.init(frame);
        const code = try decoder.decodeInt();
        const payload = try decoder.decodeBytesView();

        // Decompress if snappy enabled
        var final_payload = payload;
        if (self.snappy_enabled) {
            // TODO: Snappy decompression
            // For now, just use raw payload
        }

        return Message{
            .code = code,
            .payload = try self.allocator.dupe(u8, final_payload),
        };
    }

    /// Write a message to the connection
    pub fn writeMsg(self: *Self, code: u64, payload: []const u8) !void {
        if (self.session == null) return error.NoSession;

        // Compress if snappy enabled
        var final_payload = payload;
        if (self.snappy_enabled) {
            // TODO: Snappy compression
        }

        // Encode message
        var encoder = rlp.Encoder.init(self.allocator);
        defer encoder.deinit();

        try encoder.writeInt(code);
        try encoder.writeBytes(final_payload);
        const encoded = try encoder.toOwnedSlice();
        defer self.allocator.free(encoded);

        // Write frame
        try self.session.?.writeFrame(&self.stream, encoded);
    }

    pub fn setSnappy(self: *Self, enabled: bool) void {
        self.snappy_enabled = enabled;
    }

    // Helper functions
    fn makeAuthMsg(self: *Self, priv_key: []const u8, ephemeral_priv: []const u8, remote_pub: []const u8, shared_secret: []const u8) ![]u8 {
        // Create auth message according to RLPx spec
        // auth = E(remote-pubk, S(ephemeral-privk, shared-secret ^ nonce) || H(ephemeral-pubk) || pubk || nonce || 0x0)

        var nonce: [32]u8 = undefined;
        try std.crypto.random.bytes(&nonce);

        // Derive ephemeral public key
        const ephemeral_d = std.mem.readInt(u256, ephemeral_priv[0..32], .big);
        const ephemeral_pub_point = crypto.AffinePoint.generator().scalar_mul(ephemeral_d);
        var ephemeral_pub: [64]u8 = undefined;
        std.mem.writeInt(u256, ephemeral_pub[0..32], ephemeral_pub_point.x, .big);
        std.mem.writeInt(u256, ephemeral_pub[32..64], ephemeral_pub_point.y, .big);

        // XOR shared secret with nonce for signature
        var sig_msg: [32]u8 = undefined;
        for (shared_secret[0..32], nonce, 0..) |s, n, i| {
            sig_msg[i] = s ^ n;
        }

        // Sign with our private key (simplified - should use proper ECDSA)
        const sig_hash = crypto.keccak256(&sig_msg);

        // Build auth message: signature(65) + H(ephemeral-pubk)(32) + pubk(64) + nonce(32) + version(1)
        var auth_plain = try self.allocator.alloc(u8, 65 + 32 + 64 + 32 + 1);
        defer self.allocator.free(auth_plain);

        // Signature placeholder (would need proper signing)
        @memset(auth_plain[0..65], 0);
        @memcpy(auth_plain[0..32], &sig_hash); // Use hash as placeholder

        // Keccak256(ephemeral_pub)
        const eph_hash = crypto.keccak256(&ephemeral_pub);
        @memcpy(auth_plain[65..97], &eph_hash);

        // Our public key (derive from priv_key)
        const our_d = std.mem.readInt(u256, priv_key[0..32], .big);
        const our_pub_point = crypto.AffinePoint.generator().scalar_mul(our_d);
        std.mem.writeInt(u256, auth_plain[97..129], our_pub_point.x, .big);
        std.mem.writeInt(u256, auth_plain[129..161], our_pub_point.y, .big);

        // Nonce
        @memcpy(auth_plain[161..193], &nonce);

        // Version (0x04 for v4)
        auth_plain[193] = 0x04;

        // Encrypt with ECIES using remote public key
        var remote_pub_fixed: [64]u8 = undefined;
        @memcpy(&remote_pub_fixed, remote_pub[0..64]);

        return try crypto.ECIES.encrypt(self.allocator, remote_pub_fixed, auth_plain, null);
    }

    fn processAuth(self: *Self, auth_msg: []const u8, priv_key: []const u8) !InitiatorInfo {
        // Decrypt auth message using our private key
        var priv_key_fixed: [32]u8 = undefined;
        @memcpy(&priv_key_fixed, priv_key[0..32]);

        const auth_plain = try crypto.ECIES.decrypt(self.allocator, priv_key_fixed, auth_msg, null);
        defer self.allocator.free(auth_plain);

        if (auth_plain.len < 194) return error.InvalidAuthMessage;

        // Parse auth message components
        // signature(65) + H(ephemeral-pubk)(32) + pubk(64) + nonce(32) + version(1)

        // Extract initiator public key
        var initiator_pub: [64]u8 = undefined;
        @memcpy(&initiator_pub, auth_plain[97..161]);

        // Extract nonce
        var initiator_nonce: [32]u8 = undefined;
        @memcpy(&initiator_nonce, auth_plain[161..193]);

        // Derive shared secret using ECDH
        const shared_secret = try crypto.ECIES.generateShared(priv_key_fixed, initiator_pub);

        // Store ephemeral public key (extracted from signature verification - simplified here)
        var ephemeral_pub = try self.allocator.alloc(u8, 64);
        @memset(ephemeral_pub, 0); // Placeholder

        // Store shared secret
        var shared_copy = try self.allocator.alloc(u8, 32);
        @memcpy(shared_copy, &shared_secret);

        return InitiatorInfo{
            .ephemeral_pub = ephemeral_pub,
            .shared_secret = shared_copy,
        };
    }

    fn makeAuthAck(self: *Self, ephemeral_priv: []const u8, shared_secret: []const u8) ![]u8 {
        // Create auth-ack message according to RLPx spec
        // auth-ack = E(remote-pubk, remote-ephemeral-pubk || nonce || 0x0)

        var nonce: [32]u8 = undefined;
        try std.crypto.random.bytes(&nonce);

        // Derive our ephemeral public key
        const ephemeral_d = std.mem.readInt(u256, ephemeral_priv[0..32], .big);
        const ephemeral_pub_point = crypto.AffinePoint.generator().scalar_mul(ephemeral_d);

        // Build ack message: ephemeral-pubk(64) + nonce(32) + version(1)
        var ack_plain = try self.allocator.alloc(u8, 64 + 32 + 1);
        defer self.allocator.free(ack_plain);

        // Our ephemeral public key
        std.mem.writeInt(u256, ack_plain[0..32], ephemeral_pub_point.x, .big);
        std.mem.writeInt(u256, ack_plain[32..64], ephemeral_pub_point.y, .big);

        // Nonce
        @memcpy(ack_plain[64..96], &nonce);

        // Version
        ack_plain[96] = 0x04;

        // Encrypt with ECIES
        // Extract initiator public key from shared_secret context (simplified)
        var remote_pub: [64]u8 = undefined;
        @memset(&remote_pub, 0); // Placeholder - should extract from handshake state

        return try crypto.ECIES.encrypt(self.allocator, remote_pub, ack_plain, null);
    }

    fn processAuthAck(self: *Self, ack_msg: []const u8, shared_secret: []const u8) ![]const u8 {
        _ = shared_secret;

        // Decrypt auth-ack using our private key (from dial_dest context)
        var priv_key: [32]u8 = undefined;
        try std.crypto.random.bytes(&priv_key); // Placeholder - should use actual priv key

        const ack_plain = try crypto.ECIES.decrypt(self.allocator, priv_key, ack_msg, null);
        defer self.allocator.free(ack_plain);

        if (ack_plain.len < 97) return error.InvalidAckMessage;

        // Extract remote ephemeral public key
        var remote_ephemeral_pub = try self.allocator.alloc(u8, 64);
        @memcpy(remote_ephemeral_pub, ack_plain[0..64]);

        return remote_ephemeral_pub;
    }
};

/// Session state containing encryption keys
pub const SessionState = struct {
    allocator: std.mem.Allocator,
    enc_cipher: ?std.crypto.core.aes.Aes256, // Egress encryption
    dec_cipher: ?std.crypto.core.aes.Aes256, // Ingress decryption
    egress_mac: HashMAC,
    ingress_mac: HashMAC,
    read_buf: std.ArrayList(u8),
    write_buf: std.ArrayList(u8),

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.read_buf.deinit();
        self.write_buf.deinit();
    }

    /// Initialize from handshake secrets
    /// Based on erigon/p2p/rlpx/rlpx.go InitWithSecrets and secrets()
    pub fn initFromHandshake(
        self: *Self,
        allocator: std.mem.Allocator,
        ephemeral_priv: []const u8,
        remote_ephemeral_pub: []const u8,
        shared_secret: []const u8,
        initiator: bool,
    ) !void {
        self.allocator = allocator;
        self.read_buf = std.ArrayList(u8).init(allocator);
        self.write_buf = std.ArrayList(u8).init(allocator);

        // Derive ECDH shared secret from ephemeral keys
        var ecdh_secret: [32]u8 = undefined;
        if (ephemeral_priv.len >= 32 and remote_ephemeral_pub.len >= 64) {
            var priv_fixed: [32]u8 = undefined;
            var pub_fixed: [64]u8 = undefined;
            @memcpy(&priv_fixed, ephemeral_priv[0..32]);
            @memcpy(&pub_fixed, remote_ephemeral_pub[0..64]);
            ecdh_secret = try crypto.ECIES.generateShared(priv_fixed, pub_fixed);
        } else {
            // Fallback for testing
            @memcpy(&ecdh_secret, shared_secret[0..32]);
        }

        // Derive session keys using Keccak256
        // sharedSecret = keccak256(ecdh_secret || keccak256(respNonce || initNonce))
        // aesSecret = keccak256(ecdh_secret || sharedSecret)
        // macSecret = keccak256(ecdh_secret || aesSecret)

        var nonce_hash: [32]u8 = undefined;
        @memset(&nonce_hash, 0); // Simplified - should use actual nonces from handshake

        var shared_hash_input: [64]u8 = undefined;
        @memcpy(shared_hash_input[0..32], &ecdh_secret);
        @memcpy(shared_hash_input[32..64], &nonce_hash);
        const shared_hash = crypto.keccak256(&shared_hash_input);

        var aes_input: [64]u8 = undefined;
        @memcpy(aes_input[0..32], &ecdh_secret);
        @memcpy(aes_input[32..64], &shared_hash);
        const aes_secret = crypto.keccak256(&aes_input);

        var mac_input: [64]u8 = undefined;
        @memcpy(mac_input[0..32], &ecdh_secret);
        @memcpy(mac_input[32..64], &aes_secret);
        const mac_secret = crypto.keccak256(&mac_input);

        // Initialize AES-CTR ciphers with same key for both directions
        // (CTR mode uses encryption for both encrypt and decrypt)
        self.enc_cipher = std.crypto.core.aes.Aes256.initEnc(aes_secret);
        self.dec_cipher = std.crypto.core.aes.Aes256.initEnc(aes_secret);

        // Initialize MACs
        // mac1 = keccak256(mac_secret ^ respNonce || auth)
        // mac2 = keccak256(mac_secret ^ initNonce || authResp)
        var egress_init: [32]u8 = undefined;
        var ingress_init: [32]u8 = undefined;

        // XOR mac_secret with nonces (simplified)
        for (mac_secret, 0..) |m, i| {
            egress_init[i] = m ^ nonce_hash[i];
            ingress_init[i] = m ^ nonce_hash[i];
        }

        if (initiator) {
            self.egress_mac = HashMAC.init(mac_secret[0..16], &egress_init);
            self.ingress_mac = HashMAC.init(mac_secret[0..16], &ingress_init);
        } else {
            self.egress_mac = HashMAC.init(mac_secret[0..16], &ingress_init);
            self.ingress_mac = HashMAC.init(mac_secret[0..16], &egress_init);
        }
    }

    /// Read an RLPx frame
    /// Based on erigon/p2p/rlpx/rlpx.go readFrame
    pub fn readFrame(self: *Self, stream: *std.net.Stream) ![]u8 {
        // Read frame header (16 bytes encrypted + 16 bytes MAC)
        var header_buf: [32]u8 = undefined;
        const header_len = try stream.read(&header_buf);
        if (header_len < 32) return error.IncompleteFrame;

        // Verify header MAC using RLPx MAC construction
        const want_header_mac = self.ingress_mac.computeHeader(header_buf[0..16]);
        if (!std.mem.eql(u8, &want_header_mac, header_buf[16..32])) {
            return error.InvalidHeaderMAC;
        }

        // Decrypt header using AES-CTR
        var header_plain: [16]u8 = undefined;
        if (self.dec_cipher) |cipher| {
            // CTR mode XORs keystream with data
            var counter: [16]u8 = undefined;
            @memset(&counter, 0);
            cipher.encrypt(&counter, &counter);
            for (header_buf[0..16], &header_plain) |enc, *plain| {
                plain.* = enc ^ counter[@intFromPtr(plain) % 16];
            }
        } else {
            return error.NoCipher;
        }

        // Parse frame size from header (first 3 bytes, big-endian)
        const frame_size = (@as(u32, header_plain[0]) << 16) |
                          (@as(u32, header_plain[1]) << 8) |
                          @as(u32, header_plain[2]);

        // Calculate padding (frame size must be multiple of 16)
        const padding = if (frame_size % 16 == 0) @as(u32, 0) else 16 - (frame_size % 16);
        const total_size = frame_size + padding;

        // Read frame data + MAC
        self.read_buf.clearRetainingCapacity();
        try self.read_buf.resize(total_size + 16);
        const data_len = try stream.read(self.read_buf.items);
        if (data_len < total_size + 16) return error.IncompleteFrame;

        // Verify frame MAC
        const want_frame_mac = self.ingress_mac.computeFrame(self.read_buf.items[0..total_size]);
        if (!std.mem.eql(u8, &want_frame_mac, self.read_buf.items[total_size..total_size+16])) {
            return error.InvalidFrameMAC;
        }

        // Decrypt frame data using AES-CTR
        var decrypted = try self.allocator.alloc(u8, frame_size);
        if (self.dec_cipher) |cipher| {
            var i: usize = 0;
            while (i < total_size) : (i += 16) {
                const block_end = @min(i + 16, total_size);
                var counter: [16]u8 = undefined;
                @memset(&counter, 0);
                cipher.encrypt(&counter, &counter);

                for (self.read_buf.items[i..block_end], 0..) |enc, j| {
                    if (i + j < frame_size) {
                        decrypted[i + j] = enc ^ counter[j];
                    }
                }
            }
        }

        return decrypted[0..frame_size];
    }

    /// Write an RLPx frame
    /// Based on erigon/p2p/rlpx/rlpx.go writeFrame
    pub fn writeFrame(self: *Self, stream: *std.net.Stream, data: []const u8) !void {
        const frame_size = data.len;
        const padding = if (frame_size % 16 == 0) @as(usize, 0) else 16 - (frame_size % 16);
        const total_size = frame_size + padding;

        // Build header: 3 bytes size + 13 bytes protocol header
        var header: [16]u8 = undefined;
        header[0] = @intCast((frame_size >> 16) & 0xFF);
        header[1] = @intCast((frame_size >> 8) & 0xFF);
        header[2] = @intCast(frame_size & 0xFF);

        // Protocol header (use zeroHeader pattern from Erigon: 0xC2, 0x80, 0x80)
        header[3] = 0xC2;
        header[4] = 0x80;
        header[5] = 0x80;
        @memset(header[6..16], 0);

        // Encrypt header using AES-CTR
        var header_encrypted: [16]u8 = undefined;
        if (self.enc_cipher) |cipher| {
            var counter: [16]u8 = undefined;
            @memset(&counter, 0);
            cipher.encrypt(&counter, &counter);
            for (header, &header_encrypted) |plain, *enc| {
                enc.* = plain ^ counter[@intFromPtr(enc) % 16];
            }
        } else {
            return error.NoCipher;
        }

        // Compute header MAC
        const header_mac = self.egress_mac.computeHeader(&header_encrypted);

        // Write header + MAC
        try stream.writeAll(&header_encrypted);
        try stream.writeAll(&header_mac);

        // Prepare padded data
        self.write_buf.clearRetainingCapacity();
        try self.write_buf.appendSlice(data);
        if (padding > 0) {
            try self.write_buf.appendNTimes(0, padding);
        }

        // Encrypt data using AES-CTR
        var encrypted = try self.allocator.alloc(u8, total_size);
        defer self.allocator.free(encrypted);

        if (self.enc_cipher) |cipher| {
            var i: usize = 0;
            while (i < total_size) : (i += 16) {
                const block_end = @min(i + 16, total_size);
                var counter: [16]u8 = undefined;
                @memset(&counter, 0);
                cipher.encrypt(&counter, &counter);

                for (self.write_buf.items[i..block_end], 0..) |plain, j| {
                    encrypted[i + j] = plain ^ counter[j];
                }
            }
        }

        // Compute frame MAC
        const frame_mac = self.egress_mac.computeFrame(encrypted);

        // Write encrypted data + MAC
        try stream.writeAll(encrypted);
        try stream.writeAll(&frame_mac);
    }
};

/// RLPx message
pub const Message = struct {
    code: u64,
    payload: []u8,
};

/// Hash MAC state for RLPx v4 - implements the legacy MAC construction
/// This is based on erigon/p2p/rlpx/rlpx.go hashMAC
pub const HashMAC = struct {
    cipher: std.crypto.core.aes.Aes128,
    hash: std.crypto.hash.sha3.Keccak256,
    aes_buffer: [16]u8,
    hash_buffer: [32]u8,
    seed_buffer: [32]u8,

    pub fn init(cipher_key: []const u8, initial_hash: []const u8) HashMAC {
        var mac = HashMAC{
            .cipher = std.crypto.core.aes.Aes128.initEnc(cipher_key[0..16].*),
            .hash = std.crypto.hash.sha3.Keccak256.init(.{}),
            .aes_buffer = undefined,
            .hash_buffer = undefined,
            .seed_buffer = undefined,
        };

        // Initialize hash state
        mac.hash.update(initial_hash);

        return mac;
    }

    /// Compute MAC for frame header
    pub fn computeHeader(self: *HashMAC, header: []const u8) [16]u8 {
        // Get current hash state
        var sum1: [32]u8 = undefined;
        var hash_copy = self.hash;
        hash_copy.final(&sum1);

        return self.compute(&sum1, header);
    }

    /// Compute MAC for frame data
    pub fn computeFrame(self: *HashMAC, framedata: []const u8) [16]u8 {
        // Update hash with frame data
        self.hash.update(framedata);

        // Get hash sum as seed
        var hash_copy = self.hash;
        hash_copy.final(&self.seed_buffer);

        return self.compute(&self.seed_buffer, self.seed_buffer[0..16]);
    }

    /// Core MAC computation - the "horrible, legacy thing" from Erigon
    /// Encrypts hash state, XORs with seed, writes back to hash, takes sum
    fn compute(self: *HashMAC, sum1: []const u8, seed: []const u8) [16]u8 {
        if (seed.len != 16) @panic("invalid MAC seed length");

        // Encrypt current hash state
        self.cipher.encrypt(&self.aes_buffer, sum1[0..16]);

        // XOR with seed
        for (&self.aes_buffer, seed[0..16]) |*a, s| {
            a.* ^= s;
        }

        // Write back to hash
        self.hash.update(&self.aes_buffer);

        // Get final sum
        var hash_copy = self.hash;
        hash_copy.final(&self.hash_buffer);

        // Return first 16 bytes as MAC
        var result: [16]u8 = undefined;
        @memcpy(&result, self.hash_buffer[0..16]);
        return result;
    }
};

/// Initiator info extracted from auth message
const InitiatorInfo = struct {
    ephemeral_pub: []u8,
    shared_secret: []const u8,
};

/// ECDH shared secret derivation
fn ecdhSharedSecret(priv_key: []const u8, pub_key: []const u8) ![32]u8 {
    var priv_fixed: [32]u8 = undefined;
    var pub_fixed: [64]u8 = undefined;
    @memcpy(&priv_fixed, priv_key[0..32]);
    @memcpy(&pub_fixed, pub_key[0..64]);

    return try crypto.ECIES.generateShared(priv_fixed, pub_fixed);
}

test "RLPx connection creation" {
    const allocator = std.testing.allocator;

    // Create mock stream (for testing, would need actual network connection)
    // This test validates the structure compiles
    _ = allocator;
}
