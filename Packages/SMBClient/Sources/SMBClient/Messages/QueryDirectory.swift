import Foundation

public enum QueryDirectory {
    public struct Request: Message.Request {
        public typealias Response = QueryDirectory.Response

        public let header: Header
        public let structureSize: UInt16
        public let fileInformationClass: FileInformationClass
        public let flags: Flags
        public let fileIndex: UInt32
        public let fileId: Data
        public let fileNameOffset: UInt16
        public let fileNameLength: UInt16
        public let outputBufferLength: UInt32
        public let buffer: Data

        public init(
            creditCharge: UInt16 = 1,
            headerFlags: Header.Flags = [],
            messageId: UInt64,
            treeId: UInt32,
            sessionId: UInt64,
            fileInformationClass: FileInformationClass,
            flags: Flags = [.restartScans],
            fileId: Data,
            fileName: String,
            outputBufferLength: UInt32 = 65535,
        ) {
            header = Header(
                creditCharge: creditCharge,
                command: .queryDirectory,
                creditRequest: 256,
                flags: headerFlags,
                messageId: messageId,
                treeId: treeId,
                sessionId: sessionId,
            )

            structureSize = 33
            self.fileInformationClass = fileInformationClass
            self.flags = flags
            fileIndex = 0
            self.fileId = fileId

            let fileNameData = fileName.encoded()
            fileNameOffset = 96
            fileNameLength = UInt16(truncatingIfNeeded: fileNameData.count)

            self.outputBufferLength = outputBufferLength
            buffer = fileNameData + Data(count: 2)
        }

        public func encoded() -> Data {
            var data = Data()

            data += header.encoded()
            data += structureSize
            data += fileInformationClass.rawValue
            data += flags.rawValue
            data += fileIndex
            data += fileId
            data += fileNameOffset
            data += fileNameLength
            data += outputBufferLength
            data += buffer

            return data
        }
    }

    public struct Response: Message.Response {
        public let header: Header
        public let structureSize: UInt16
        public let outputBufferOffset: UInt16
        public let outputBufferLength: UInt32
        public let buffer: Data

        public init(data: Data) {
            let reader = ByteReader(data)

            header = reader.read()

            structureSize = reader.read()
            outputBufferOffset = reader.read()
            outputBufferLength = reader.read()
            buffer = reader.read(from: Int(outputBufferOffset), count: Int(outputBufferLength))
        }

        public func files() -> [FileDirectoryInformation] {
            var files = [FileDirectoryInformation]()
            if outputBufferLength > 0 {
                var data = Data(buffer)
                repeat {
                    let fileInformation = FileDirectoryInformation(data: data)
                    files.append(fileInformation)
                    data = Data(data[(fileInformation.nextEntryOffset)...])
                } while files.last!.nextEntryOffset != 0
            }

            return files
        }
    }

    public enum FileInformationClass: UInt8 {
        case fileDirectoryInformation = 0x01
        case fileFullDirectoryInformation = 0x02
        case fileIdFullDirectoryInformation = 0x26
        case fileBothDirectoryInformation = 0x03
        case fileIdBothDirectoryInformation = 0x25
        case fileNamesInformation = 0x0C
        case fileIdExtdDirectoryInformation = 0x3C
        case fileInfomationClass_Reserved = 0x64
    }

    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public static let restartScans = Flags(rawValue: 0x01)
        public static let returnSingleEntry = Flags(rawValue: 0x02)
        public static let indexSpecified = Flags(rawValue: 0x04)
        public static let reopen = Flags(rawValue: 0x10)
    }
}

// Fila: `Response.init(data:)` and `files()` slice the reply at offsets and
// lengths the server chose, and trap on any that point outside it. A reply
// is checked with this before it is parsed: the output buffer inside the
// message, and every entry inside the buffer, its name included. Entries
// are FILE_DIRECTORY_INFORMATION, a fixed 64 bytes whose last four are the
// name's length, then the name.
public extension QueryDirectory.Response {
    static func isWellFormed(_ data: Data) -> Bool {
        // The header, then StructureSize, OutputBufferOffset and
        // OutputBufferLength.
        guard data.count >= 72 else { return false }
        let offset = Int(littleEndian(data, at: 66, count: 2))
        let length = Int(littleEndian(data, at: 68, count: 4))
        guard offset <= data.count, length <= data.count - offset else { return false }
        guard length > 0 else { return true }
        var entry = 0
        while true {
            guard entry <= length - 64 else { return false }
            let nameLength = Int(littleEndian(data, at: offset + entry + 60, count: 4))
            guard nameLength <= length - entry - 64 else { return false }
            let next = Int(littleEndian(data, at: offset + entry, count: 4))
            if next == 0 {
                return true
            }
            entry += next
        }
    }

    private static func littleEndian(_ data: Data, at position: Int, count: Int) -> UInt32 {
        let start = data.startIndex + position
        return (0 ..< count).reduce(UInt32(0)) { value, byte in
            value | UInt32(data[start + byte]) << (8 * byte)
        }
    }
}
