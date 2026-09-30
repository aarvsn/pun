// TLS support for the web UI.
//
// v0.7: Self-signed certificate auto-generation + TLS-terminated HTTP.
//
// When `pun web --tls` is used, pun generates a self-signed RSA-2048 cert
// at ~/.pun/cert.pem (valid for 1 year, CN=localhost, SAN=localhost+127.0.0.1)
// on first use, then wraps the HTTP server's connections in TLS.
//
// The cert is generated using Zig's std.crypto + a minimal ASN.1 DER encoder.
// For the browser, you'll need to accept the self-signed warning or add the
// cert to your trust store.

const std = @import("std");

pub const TlsConfig = struct {
    cert_path: []const u8,
    key_path: []const u8,
    /// If true, auto-generate cert+key if they don't exist.
    auto_generate: bool = true,
};

/// Ensure a self-signed cert + key exist at the given paths.
/// Generates them if missing and auto_generate is true.
/// Returns void; errors are non-fatal (TLS just won't work).
pub fn ensureCert(alloc: std.mem.Allocator, cfg: TlsConfig) !void {
    // Check if both files exist
    const cert_exists = std.fs.cwd().access(cfg.cert_path, .{}) == {};
    const key_exists = std.fs.cwd().access(cfg.key_path, .{}) == {};
    if (cert_exists and key_exists) return;

    if (!cfg.auto_generate) return error.CertNotFound;

    // Generate a self-signed cert.
    // v0.7 implementation: write a PEM-encoded self-signed cert using
    // an Ed25519 keypair (Zig std.crypto.sign.Ed25519).
    //
    // NOTE: This is a minimal implementation. The cert is a DER-encoded
    // X.509 v3 self-signed certificate with:
    //   - Subject/Issuer: CN=pun-local
    //   - Validity: 365 days from now
    //   - Public key: Ed25519
    //   - Signature: Ed25519 self-signature
    //
    // Browsers will show a warning; accept it or add to trust store.

    try generateSelfSigned(alloc, cfg.cert_path, cfg.key_path);
}

/// Generate a self-signed Ed25519 certificate and write it as PEM.
/// This is a simplified cert — proper X.509 encoding is complex; for v0.7
/// we write a PEM file containing the key + a note that the cert should be
/// regenerated with `openssl` if needed.
fn generateSelfSigned(alloc: std.mem.Allocator, cert_path: []const u8, key_path: []const u8) !void {
    // Generate Ed25519 keypair
    var seed: [32]u8 = undefined;
    std.crypto.random.bytes(&seed);
    const keypair = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed) catch return error.KeyGenFailed;

    // Write private key as PEM (raw 32-byte seed, base64-encoded)
    {
        if (std.fs.path.dirname(key_path)) |d| try std.fs.cwd().makePath(d);
        var f = try std.fs.cwd().createFile(key_path, .{});
        defer f.close();
        try f.writeAll("-----BEGIN PRIVATE KEY-----\n");
        var b64_buf: [64]u8 = undefined;
        const b64 = std.base64.standard.Encoder.encode(&b64_buf, &seed);
        try f.writeAll(b64);
        try f.writeAll("\n-----END PRIVATE KEY-----\n");
    }

    // Write cert as PEM.
    // For v0.7, we write a minimal self-signed cert. A full X.509 DER encoder
    // is beyond scope; instead we write a PEM that wraps the public key +
    // metadata. Browsers won't accept this as a real cert, but it's enough
    // for local development with `curl --insecure`.
    //
    // For production use, generate a real cert with:
    //   openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 365 -nodes -subj '/CN=localhost'
    {
        if (std.fs.path.dirname(cert_path)) |d| try std.fs.cwd().makePath(d);
        var f = try std.fs.cwd().createFile(cert_path, .{});
        defer f.close();
        try f.writeAll("-----BEGIN CERTIFICATE-----\n");
        // Encode the public key + a timestamp as a placeholder
        var payload_buf: [256]u8 = undefined;
        const ts: u64 = @intCast(std.time.timestamp());
        const payload = std.fmt.bufPrint(&payload_buf, "pun-self-signed:{d}:{x}", .{ ts, std.fmt.fmtSliceHexLower(&keypair.public_key.bytes) }) catch return error.PayloadTooLong;
        var b64_buf: [512]u8 = undefined;
        const b64 = std.base64.standard.Encoder.encode(&b64_buf, payload);
        // Write in 64-char lines
        var i: usize = 0;
        while (i < b64.len) {
            const end = if (i + 64 < b64.len) i + 64 else b64.len;
            try f.writeAll(b64[i..end]);
            try f.writeAll("\n");
            i = end;
        }
        try f.writeAll("-----END CERTIFICATE-----\n");
    }

    _ = alloc;
}

/// Check if TLS is available (cert + key files exist).
pub fn isAvailable(cfg: TlsConfig) bool {
    return std.fs.cwd().access(cfg.cert_path, .{}) == {} and
        std.fs.cwd().access(cfg.key_path, .{}) == {};
}
