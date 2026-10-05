/// A bidirectional stream of framed SFTP packets — the seam between `SFTPClient` and the ssh
/// subsystem it runs over. The real one (`SFTPSession`) spawns `ssh … -s sftp`; tests use an
/// in-process loopback to a fake server. A conformer must serialize its own `send` and
/// `receive`, because the client pipelines requests and may call `send` from several tasks at
/// once.
public protocol SFTPTransport: Sendable {
    /// Write one complete frame (`uint32 length` + body), as produced by `SFTPPacket.encode()`.
    func send(_ frame: [UInt8]) async throws
    /// Read the next complete frame. Throws `SFTPError.transportClosed` at end of stream.
    func receive() async throws -> [UInt8]
    /// Stop the transport; a `receive` in flight and any that follow throw.
    func close() async
}
