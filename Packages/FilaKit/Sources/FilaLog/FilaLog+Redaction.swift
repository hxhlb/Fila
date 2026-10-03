import Foundation

/// The one mechanical half of the privacy rule stated at the top of `FilaLog`.
///
/// It cannot stop someone logging a secret on purpose, and it is not trying
/// to. What it stops is the accident that actually happens: a request line, a
/// URL, or an argument vector goes into a log line whole, and one of the words
/// in it was a password. Every message goes through here on its way into the
/// ring *and* into `os_log`, so there is no unredacted copy anywhere.
///
/// The shapes it knows are the ones credentials arrive in:
///
/// | in                                   | out                                   |
/// |--------------------------------------|---------------------------------------|
/// | `Authorization: Basic dXNlcjpwdw==`  | `Authorization: <redacted>`           |
/// | `Bearer eyJhbGci…`                   | `Bearer <redacted>`                   |
/// | `PROPFIND https://bob:hunter2@dav/`  | `PROPFIND https://bob:<redacted>@dav/`|
/// | `?password=hunter2`                  | `?password=<redacted>`                |
/// | `mount --password hunter2`           | `mount --password <redacted>`         |
/// | `token:hunter2`                      | `token:<redacted>`                    |
///
/// Over-redaction is the safe direction and the list leans that way — a `key=`
/// that turns out to have been harmless costs a reader nothing, and this
/// module never sees an extended attribute's value in the first place.
public extension FilaLog {
    static let redactedPlaceholder = "<redacted>"

    /// Tokens that announce a credential in the token after them. A command's
    /// password flag and an auth scheme are the same shape and the same fix,
    /// so they share one list rather than two identical branches.
    private static let announcesASecret: Set<String> = [
        "-p", "--password", "--passwd", "--pass",
        "--token", "--secret", "--apikey", "--api-key",
        "basic", "bearer", "digest",
    ]

    /// A header whose entire remaining value is the credential. Matched at the
    /// start of a token, so a value written without the space after the colon
    /// (`authorization:Basic …`) is caught as well.
    private static let secretHeaders = [
        "authorization:", "proxy-authorization:", "www-authenticate:",
        "cookie:", "set-cookie:",
    ]

    /// Matched against the end of the key in `key=value` and `key:value`, so
    /// `db_password=` and `X-Auth-Token:` are caught along with the bare words.
    private static let secretKeys = [
        "password", "passwd", "pass", "pw",
        "token", "secret", "apikey", "api_key", "key",
        "auth", "credential", "credentials",
    ]

    /// The message with anything credential-shaped replaced.
    ///
    /// Every line is split and walked, with no character-based early-out — the
    /// obvious one (skip a line with no `@`, `=` or `:`) is wrong, because
    /// `Basic Ym9iOnB3` and `--password hunter2` contain none of the three and
    /// are the two shapes most worth catching. The cost is a split and a
    /// lowercase per token, a microsecond or so; verbose writes a line per XPC
    /// round trip, which is hundreds a second at its worst, not thousands.
    static func redacting(_ message: String) -> String {
        var tokens = message.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var redactNextToken = false
        var index = 0
        while index < tokens.count {
            defer { index += 1 }
            let token = tokens[index]
            // A run of spaces is not the value the flag was pointing at.
            if token.isEmpty {
                continue
            }

            if redactNextToken {
                redactNextToken = false
                tokens[index] = redactedPlaceholder
                continue
            }

            let lowered = token.lowercased()
            if let header = secretHeaders.first(where: { lowered.hasPrefix($0) }) {
                // A header's value is the credential in full, and it may be
                // several tokens (`Basic` plus the payload). Nothing after it
                // on the line is worth more than the leak would cost.
                if lowered.count > header.count {
                    tokens[index] = String(token.prefix(header.count)) + redactedPlaceholder
                    tokens.removeSubrange((index + 1)...)
                } else {
                    tokens.replaceSubrange((index + 1)..., with: [redactedPlaceholder])
                }
                break
            }
            if announcesASecret.contains(lowered) {
                redactNextToken = true
                continue
            }
            if let redacted = redactingUserInfo(token) {
                tokens[index] = redacted
                continue
            }
            if let assignment = redactingAssignment(token) {
                tokens[index] = assignment.redacted
                // `password: hunter2`, `X-Auth-Token: abc` — the separator
                // ends the token, so the value is the next one.
                redactNextToken = assignment.valueFollows
            }
        }
        return tokens.joined(separator: " ")
    }

    /// `scheme://user:pass@host` and the bare `user:pass@host` both. The user
    /// stays — knowing *which* account failed to authenticate is most of the
    /// diagnosis, and it is not the secret.
    private static func redactingUserInfo(_ token: String) -> String? {
        // The last `@`, because a password may legally contain one.
        guard let at = token.lastIndex(of: "@") else { return nil }
        let head = token[..<at]
        let start = head.range(of: "//")?.upperBound ?? head.startIndex
        guard let colon = head[start...].firstIndex(of: ":") else { return nil }
        return token[...colon] + redactedPlaceholder + token[at...]
    }

    /// `key=value` and `key:value`, when the key ends in a word that names a
    /// secret. A port (`host:8080`) and a time survive because neither key is
    /// on the list.
    ///
    /// Every parameter of a query is its own assignment — `/a?x=1&token=…`
    /// names its secret after the first `=` — and the first secret one takes
    /// the rest of the token with it, since a value may itself contain a `&`.
    /// `valueFollows` is a secret key whose separator ends the token, as in
    /// a header written `X-Auth-Token: abc`: the value is the next token.
    private static func redactingAssignment(_ token: String) -> (redacted: String, valueFollows: Bool)? {
        var start = token.startIndex
        while start < token.endIndex {
            let end = token[start...].firstIndex(where: { $0 == "?" || $0 == "&" }) ?? token.endIndex
            // Indexed on `token` itself and only the key is lowercased, so the
            // cut is never taken against a string whose length lowercasing
            // changed.
            if let separator = token[start ..< end].firstIndex(where: { $0 == "=" || $0 == ":" }) {
                let key = token[start ..< separator].lowercased()
                if !key.isEmpty, secretKeys.contains(where: { key.hasSuffix($0) }) {
                    let valueStart = token.index(after: separator)
                    guard valueStart < token.endIndex else { return (token, true) }
                    return (token[...separator] + redactedPlaceholder, false)
                }
            }
            guard end < token.endIndex else { break }
            start = token.index(after: end)
        }
        return nil
    }
}
