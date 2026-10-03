@testable import FilaProtocol
import Foundation
import Testing
#if canImport(XPC)
    import XPC
#endif

struct FailureWireTests {
    @Test(arguments: FilaFailureReason.allCases)
    func `Detailed transfer refusals survive helper JSON`(_ reason: FilaFailureReason) throws {
        let failure = FilaFailure(code: .invalidRequest, systemError: EINVAL, path: "/source", reason: reason)
        #expect(try JSONDecoder().decode(FilaFailure.self, from: JSONEncoder().encode(failure)) == failure)
    }

    @Test
    func `Failures from an older helper have no detailed reason`() throws {
        let failure = FilaFailure(code: .invalidRequest, systemError: EINVAL)
        let encoded = try JSONEncoder().encode(failure)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["reason"] == nil)
        #expect(try JSONDecoder().decode(FilaFailure.self, from: encoded) == failure)
    }

    #if canImport(XPC)
        @Test(arguments: FilaFailureReason.allCases)
        func `Detailed transfer refusals survive replies and job events`(_ reason: FilaFailureReason) throws {
            let failure = FilaFailure(code: .invalidRequest, systemError: EINVAL, path: "/source", reason: reason)
            let reply = xpc_dictionary_create(nil, nil, 0)
            failure.encode(into: reply)
            #expect(FilaFailure.decode(reply) == failure)
            let event = JobEvent.completed(failure, skipped: 0).encoded(jobIdentifier: 42)
            let decoded = try #require(JobEvent.decode(event))
            guard case let .completed(result, _) = decoded.event else { Issue.record("Expected a completed job"); return }
            #expect(result == failure)
            #expect(decoded.jobIdentifier == 42)
        }

        @Test
        func `A completion carries its skipped members, and a message without them reads as none`() throws {
            let partial = JobEvent.completed(FilaFailure(code: .success), skipped: 3).encoded(jobIdentifier: 7)
            #expect(JobEvent.decode(partial)?.event == .completed(FilaFailure(code: .success), skipped: 3))

            let older = JobEvent.completed(FilaFailure(code: .success), skipped: 0).encoded(jobIdentifier: 7)
            xpc_dictionary_set_value(older, FilaWireKey.skippedItems, nil)
            #expect(JobEvent.decode(older)?.event == .completed(FilaFailure(code: .success), skipped: 0))

            let hostile = JobEvent.completed(FilaFailure(code: .success), skipped: -5).encoded(jobIdentifier: 7)
            #expect(JobEvent.decode(hostile)?.event == .completed(FilaFailure(code: .success), skipped: 0))
        }
    #endif
}
