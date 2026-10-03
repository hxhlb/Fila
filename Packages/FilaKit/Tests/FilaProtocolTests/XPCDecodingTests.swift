#if canImport(XPC)
    @testable import FilaProtocol
    import Foundation
    import Testing
    import XPC

    // What the daemon does with a message it did not expect. Only an accepted
    // peer can send one, so none of this is an escalation — but libxpc answers
    // a dictionary accessor on anything else by killing the process, and a
    // killed `filad` takes every running job of every peer with it. The two
    // nested-entry cases crashed the test process before their decoders
    // checked the type; the times passed decoding and trapped later, where
    // they were converted to a kernel time.

    @Suite("Decoding what a peer should not have sent")
    struct XPCDecodingTests {
        @Test
        func `An archive member that is not a dictionary refuses the request`() {
            let request = xpc_dictionary_create(nil, nil, 0)
            ArchiveOptions(members: [ArchiveSelection(index: 0, declaredPath: "a.txt")]).encode(into: request)
            let members = xpc_array_create(nil, 0)
            xpc_array_set_string(members, FilaXPC.arrayAppend, "not a member")
            xpc_dictionary_set_value(request, FilaWireKey.archiveMembers, members)

            #expect(ArchiveOptions(decoding: request) == nil)
        }

        @Test
        func `A search match that is not a dictionary is skipped`() throws {
            let message = SearchBatch(matches: [], limits: []).encoded(jobIdentifier: 7)
            let matches = xpc_array_create(nil, 0)
            xpc_array_set_string(matches, FilaXPC.arrayAppend, "not a match")
            xpc_dictionary_set_value(message, FilaWireKey.matches, matches)

            let decoded = try #require(SearchBatch.decode(message))
            #expect(decoded.jobIdentifier == 7)
            #expect(decoded.batch.matches.isEmpty)
        }

        @Test(arguments: [Double.nan, .infinity, -.infinity, 1e19, -1e19])
        func `A time the kernel cannot hold refuses the change`(time: Double) {
            // `time_t(time)` traps on every one of these, inside the root
            // daemon, in the middle of `utimes`.
            let modified = AttributeChange(modified: time).encoded()
            #expect(AttributeChange(decoding: modified) == nil)
            let accessed = AttributeChange(accessed: time).encoded()
            #expect(AttributeChange(decoding: accessed) == nil)
        }

        @Test
        func `A time that is not a number refuses the change`() {
            let change = AttributeChange(mode: 0o644).encoded()
            xpc_dictionary_set_string(change, "mt", "yesterday")
            #expect(AttributeChange(decoding: change) == nil)
        }

        /// The hard-link marker is an explicit zero. A kind this build does
        /// not know, one of the wrong type or none at all must not read as
        /// "link this path" and make a second name for whatever it names.
        @Test
        func `A node kind that is missing, mistyped or unknown refuses the creation`() {
            let unknown = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_uint64(unknown, FilaWireKey.nodeKind, 99)
            xpc_dictionary_set_string(unknown, FilaWireKey.linkTarget, "/etc/passwd")
            #expect(NodeTemplate(decoding: unknown) == nil)

            let mistyped = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(mistyped, FilaWireKey.nodeKind, "file")
            xpc_dictionary_set_string(mistyped, FilaWireKey.linkTarget, "/etc/passwd")
            #expect(NodeTemplate(decoding: mistyped) == nil)

            let missing = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(missing, FilaWireKey.linkTarget, "/etc/passwd")
            #expect(NodeTemplate(decoding: missing) == nil)
        }

        @Test(arguments: [NodeTemplate.directory, .emptyFile, .symbolicLink(target: "t"), .hardLink(existing: "/a")])
        func `Every node template survives the wire`(_ template: NodeTemplate) {
            let request = xpc_dictionary_create(nil, nil, 0)
            template.encode(into: request)
            #expect(NodeTemplate(decoding: request) == template)
        }

        @Test
        func `Ordinary times still arrive`() throws {
            let change = AttributeChange(modified: 1_756_000_000.5, accessed: -1.25)
            let decoded = try #require(AttributeChange(decoding: change.encoded()))
            #expect(decoded.modified == 1_756_000_000.5)
            #expect(decoded.accessed == -1.25)
        }
    }
#endif
