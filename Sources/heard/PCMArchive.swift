import Foundation

/// Rotated WAV files retain exactly the PCM sent to Scribe. A crash can affect
/// only the current minute; every completed segment has a valid WAV header.
actor PCMArchive {
    private let directory: URL
    private let source: String
    private var file: FileHandle?
    private var segment = 0
    private var bytesInSegment: UInt32 = 0
    private var samplesTotal: UInt64 = 0

    init(session: String, source: String) throws {
        self.source = source
        directory = HeardPaths.root.appendingPathComponent("recordings", isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    func append(_ pcm: Data) throws {
        guard !pcm.isEmpty, pcm.count.isMultiple(of: 2) else { return }
        if file == nil || bytesInSegment + UInt32(pcm.count) > 1_920_000 {
            try finishSegment()
            try openSegment()
        }
        try file?.write(contentsOf: pcm)
        bytesInSegment += UInt32(pcm.count)
        samplesTotal += UInt64(pcm.count / 2)
    }

    func close() throws { try finishSegment() }

    func statistics() -> (samples: UInt64, segments: Int, directory: String) {
        (samplesTotal, segment, directory.path)
    }

    private func openSegment() throws {
        segment += 1
        bytesInSegment = 0
        let path = directory.appendingPathComponent(String(format: "%@-%05d.wav", source, segment))
        FileManager.default.createFile(atPath: path.path, contents: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        file = try FileHandle(forWritingTo: path)
        try file?.write(contentsOf: Self.header(dataBytes: 0))
    }

    private func finishSegment() throws {
        guard let file else { return }
        try file.seek(toOffset: 0)
        try file.write(contentsOf: Self.header(dataBytes: bytesInSegment))
        try file.synchronize()
        try file.close()
        self.file = nil
    }

    private static func header(dataBytes: UInt32) -> Data {
        var data = Data()
        func label(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) {
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        func u32(_ value: UInt32) {
            for shift in stride(from: 0, through: 24, by: 8) {
                data.append(UInt8(truncatingIfNeeded: value >> shift))
            }
        }
        label("RIFF"); u32(36 + dataBytes); label("WAVE")
        label("fmt "); u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        label("data"); u32(dataBytes)
        return data
    }
}
