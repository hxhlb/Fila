# SMBClient, vendored

Upstream: https://github.com/kishikawakatsumi/SMBClient
Revision: `66eafaa6d17e034e8036dee4b3ebc1b52cb53919` (main, 2026-04-27)
Licence: MIT, `LICENSE` beside this file, unchanged.

Why a copy rather than a package reference: `Session.queryDirectory` collects
a whole directory into one array before it returns, and every request
primitive under it is `private`. Fila lists remote directories one server
response at a time so a listing can be budgeted and cancelled between pages,
which needs one method inside the module. Everything else is upstream as-is
apart from the changes listed below, each marked `// Fila:` in the source.

Why this revision rather than the last tag (0.3.1, 2024-12-10): the commits
since fix a large-download stall in the `NWConnection` receive loop, a crash
on a partial DirectTCP header, a retain cycle in the state handler and a
double resume of a continuation. All four are in the transport every
operation goes through.

What was left out: `Tests/` (44 MB of fixtures and a mock server),
`Examples/`, the Docker files and the README. The library builds and tests
under Fila's own harness.

## Changes

`Sources/SMBClient/Session.swift`: added `queryDirectoryPage(fileId:pattern:restart:)`
after `queryDirectory(path:pattern:)`. One QUERY_DIRECTORY request against a
directory handle the caller opened with `create` and closes with `close`;
returns the entries of that response and whether the server has more. A
page with no entries ends the listing whatever its status, and a first page
answered STATUS_NO_SUCH_FILE is an empty directory (an empty NTFS volume
root has no `.` or `..`), not an error. The output buffer it asks for is
never below 64 KiB, the least MS-SMB2 lets a server negotiate as
MaxTransactSize: a session whose negotiated size is 0 would otherwise make
`creditSize(size:)` underflow and trap. The reply is checked with
`QueryDirectory.Response.isWellFormed(_:)`, added at the end of
`Messages/QueryDirectory.swift`, before it is parsed: the output buffer and
every entry in it, name included, must lie inside the reply, or the request
fails as `ConnectionError.malformedResponse` rather than trapping on a
server-chosen offset. Marked `// Fila:` in the source.

`Sources/SMBClient/Session.swift`: added `nodeStat(path:)` after it —
`fileStat(path:)` with `.openReparsePoint`, so a junction or symlink is
described as itself and a caller deciding whether to walk or move a tree is
never sent through it. After it, `reparseTag(path:)`: the same node's
FILE_ATTRIBUTE_TAG_INFORMATION, because the reparse-point attribute alone
also marks deduplicated files and cloud placeholders, which are not links;
only a name-surrogate tag is. A reply too short to hold the tag fails as
`ConnectionError.malformedResponse`. A listing still carries no tag, so its
entries take every reparse point for a link.

`Sources/SMBClient/Messages/QueryInfo.swift`: `QueryInfo.Response.init(data:)`
reads no further than the reply holds, where upstream trapped in the reader.
The reply ends at its `NextCommand` inside a compound. A reply shorter than
its fixed fields, or one whose `OutputBufferLength` runs past its end, gives
an empty buffer, which `reparseTag(path:)` refuses as malformed. Marked
`// Fila:` in the source.

`Sources/SMBClient/Session.swift`: added `rename(from:to:replaceIfExists:)`
after `move(from:to:)` — the same compound with the rename's replace flag
exposed, so a publication can be exclusive (an occupied name fails and
nothing moves) or a replacement, as the caller decided. `setInfo(path:_:)`
opens without DELETE access and cannot rename. Unlike `move`, it opens its
source with `.openReparsePoint` (a link is renamed, not its target) and sends
the new name as given: `move` composes it to NFC, which on a server that
compares bytes renames a decomposed name to a different one. Fila also
creates directories with `create` rather than `createDirectory(path:)`, for
the same reason; that method is unchanged.

`Sources/SMBClient/Session.swift`: added `deleteNode(path:directory:)`
after it — delete-on-close of exactly one node, with the create options
pinning the kind and opening a reparse point as itself. Upstream's
`deleteDirectory(path:)` lists and deletes a directory's contents first,
which a move's source cleanup must never do. Both marked `// Fila:`.

`Sources/SMBClient/Connection.swift`: `Connection` is declared
`@unchecked Sendable`. Its send completion is a `@Sendable` closure that calls
back into `receive`, which warns about capturing a non-Sendable `self` — the
only warning the harness reports in this copy. The reason the claim holds is
in a `// Fila:` comment above the declaration.

`Sources/SMBClient/Connection.swift`: `receive` refuses a message shorter
than what will be read from it, including one that a compound's
`NextCommand` places past the end: a header (64 bytes) before `Header`
reads it, a success with at least the smallest body any response has
(SET_INFO's StructureSize 2, 66 bytes), and an error with the 4 bytes of
body `ErrorResponse` reads (68). The failure is the added
`ConnectionError.malformedResponse`. The compound splitter in `Session.send`
refuses a reply too short for its header, and a compound answered with
fewer replies than it sent.
The other response parsers still trust the sizes inside a well-framed reply
— a hostile server can trap the process through them — and are upstream's.

## Updating

Check out the new upstream revision, copy `Sources/SMBClient` and `LICENSE`
over this directory, reapply the changes above, update the revision here, and
run `make harness`.
