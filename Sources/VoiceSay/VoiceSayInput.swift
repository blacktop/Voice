import ArgumentParser
import Darwin
import Foundation

enum VoiceSayInput {
    static let maximumBytes = 4 * 1024 * 1024

    static func readFile(_ path: String) throws -> String {
        var info = stat()
        guard fstatat(AT_FDCWD, path, &info, 0) == 0 else { throw fileError(path) }
        try validate(info)

        // Nonblocking open also covers a path replaced with a FIFO after stat.
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOCTTY)
        guard descriptor >= 0 else { throw fileError(path) }
        defer { close(descriptor) }
        guard fstat(descriptor, &info) == 0 else { throw fileError(path) }
        try validate(info)
        return try read(FileHandle(fileDescriptor: descriptor, closeOnDealloc: false))
    }

    static func read(_ input: FileHandle) throws -> String {
        var data = Data()
        while let chunk = try input.read(upToCount: min(65_536, maximumBytes + 1 - data.count)),
            !chunk.isEmpty
        {
            guard chunk.count <= maximumBytes - data.count else {
                throw ValidationError("Document input exceeds the 4 MiB limit.")
            }
            data.append(chunk)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ValidationError("Input must be UTF-8 text.")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func validate(_ info: stat) throws {
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw ValidationError("--file requires a regular file; use --file - for stdin.")
        }
        guard info.st_size >= 0, info.st_size <= off_t(maximumBytes) else {
            throw ValidationError("Document input exceeds the 4 MiB limit.")
        }
    }

    private static func fileError(_ path: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
    }
}
