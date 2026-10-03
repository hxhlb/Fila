import Foundation

public enum QueryInfo {
    public struct Request: Message.Request {
        public typealias Response = QueryInfo.Response

        public let header: Header
        public let structureSize: UInt16
        public let infoType: InfoType
        public let fileInfoClass: FileInfoClass
        public let outputBufferLength: UInt32
        public let inputBufferOffset: UInt16
        public let reserved: UInt16
        public let inputBufferLength: UInt32
        public let additionalInformation: UInt32
        public let flags: Flags
        public let fileId: Data
        public let buffer: Data

        public init(
            headerFlags: Header.Flags = [],
            messageId: UInt64,
            treeId: UInt32,
            sessionId: UInt64,
            infoType: InfoType,
            fileInfoClass: FileInfoClass,
            flags: Flags = [],
            fileId: Data,
        ) {
            header = Header(
                creditCharge: 1,
                command: .queryInfo,
                creditRequest: 64,
                flags: headerFlags,
                messageId: messageId,
                treeId: treeId,
                sessionId: sessionId,
            )

            structureSize = 41
            self.infoType = infoType
            self.fileInfoClass = fileInfoClass
            outputBufferLength = 1124
            inputBufferOffset = 0
            reserved = 0
            inputBufferLength = 0
            additionalInformation = 0
            self.flags = flags
            self.fileId = fileId
            buffer = Data()
        }

        public func encoded() -> Data {
            var data = Data()

            data += header.encoded()

            data += structureSize
            data += infoType.rawValue
            data += fileInfoClass.rawValue
            data += outputBufferLength
            data += inputBufferOffset
            data += reserved
            data += inputBufferLength
            data += additionalInformation
            data += flags.rawValue
            data += fileId
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
            // Fila: the fixed fields and the buffer length are the server's
            // to state, and a reply shorter than either trapped in the
            // reader. In a compound, `data` runs on through the replies after
            // this one, so this reply ends at its NextCommand. A buffer it
            // claims but does not hold is no buffer: empty, which a caller that
            // needs bytes refuses as malformed, as `reparseTag(path:)` does.
            let end = header.nextCommand == 0 ? data.count : min(Int(header.nextCommand), data.count)
            guard end >= 72 else {
                structureSize = 0
                outputBufferOffset = 0
                outputBufferLength = 0
                buffer = Data()
                return
            }
            structureSize = reader.read()
            outputBufferOffset = reader.read()
            outputBufferLength = reader.read()
            buffer = Int(outputBufferLength) <= end - 72 ? reader.read(count: Int(outputBufferLength)) : Data()
        }
    }

    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        public static let restartScans = Flags(rawValue: 0x0000_0001)
        public static let returnSingleEntry = Flags(rawValue: 0x0000_0002)
        public static let indexSpecified = Flags(rawValue: 0x0000_0004)
    }
}
