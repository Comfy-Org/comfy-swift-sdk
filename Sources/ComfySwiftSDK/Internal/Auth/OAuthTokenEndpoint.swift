import Foundation

/// Shared token-endpoint POST used by both `OAuthExchanger` (authorization-code
/// grant) and `OAuthTokenRefreshExecutor` (refresh grant). Both flows run the
/// identical five-step dance — form-encode the body, POST as
/// `application/x-www-form-urlencoded`, translate transport errors, check the
/// HTTP status, decode the token DTO, and build `OAuthTokenResponse` — so it
/// lives here once. Callers still own building their own query items (the two
/// grants carry different parameters).
internal enum OAuthTokenEndpoint {

    private struct TokenDTO: Codable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case accessToken  = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn    = "expires_in"
        }
    }

    /// RFC 6749 §5.2 error response. The token endpoint answers a rejected grant
    /// with HTTP 400 and this body — `invalid_grant` for a refresh token that is
    /// expired, revoked, reused, or simply unknown to the server.
    private struct TokenErrorDTO: Decodable {
        let error: String
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }

    /// POSTs a form-encoded token request and decodes the standard token response.
    ///
    /// An HTTP 400 is classified here for BOTH grants rather than falling through to
    /// `Transport.checkStatus`: a 400 on either grant is the endpoint *refusing* the
    /// credential we sent, which is never the retryable transport failure
    /// `.network(URLError(.badServerResponse))` describes.
    /// - Parameter isRefreshGrant: `true` for the refresh grant, which classifies a
    ///   dead session differently from the authorization-code grant in two places:
    ///   an HTTP 400 `invalid_grant` becomes `.authExpired`, and an HTTP 401/403
    ///   (`ComfyError.authInvalid` from `Transport.checkStatus`) is remapped to
    ///   `.authExpired` as well. Exchange callers pass `false`: a rejected
    ///   authorization code is a failed *sign-in*, not an expired session, so
    ///   routing it to the app's re-authentication flow would only loop. Their 400
    ///   still enters the arm below — EVERY 400 on that grant surfaces as
    ///   `ComfyError.authCodeRejected`, never `.authExpired`, never `.network`, and
    ///   never `.unknown`.
    static func post(
        queryItems: [URLQueryItem],
        session: URLSession,
        isRefreshGrant: Bool
    ) async throws -> OAuthTokenResponse {
        var request = URLRequest(url: OAuthConfiguration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        guard let bodyData = formURLEncoded(queryItems).data(using: .utf8) else {
            throw ComfyError.unknown(underlying: URLError(.badURL))
        }
        request.httpBody = bodyData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Transport.translate(error)
        }

        // The 400 arm has to run BEFORE `Transport.checkStatus`, whose `default:`
        // maps every unmodelled status to `.network(URLError(.badServerResponse))`.
        // That is wrong for BOTH grants, for the same reason: a rejected grant is a
        // client-side refusal no retry can fix, so reporting it as a transient
        // "check your connection" failure invites a retry loop that can only fail
        // again — an authorization code lives ~60s from the redirect and is
        // single-use, so a slow or repeated redemption hits this every time. For the
        // refresh grant it additionally hides `.authExpired`, the one signal the
        // app's re-sign-in flow keys on; for the authorization-code grant it hides
        // `.authCodeRejected`, the signal a consumer branches on to restart sign-in.
        if (response as? HTTPURLResponse)?.statusCode == 400 {
            throw grantRejection(
                from: data,
                isRefreshGrant: isRefreshGrant,
                redacting: secretValues(in: queryItems)
            )
        }

        do {
            try Transport.checkStatus(response)
        } catch ComfyError.authInvalid where isRefreshGrant {
            // Defence in depth: 400 `invalid_grant` is what the production token
            // endpoint actually sends for a dead refresh token, but a proxy or CDN
            // in front of it may answer 401/403 instead.
            throw ComfyError.authExpired
        }

        let dto: TokenDTO
        do {
            dto = try JSONDecoder().decode(TokenDTO.self, from: data)
        } catch {
            throw ComfyError.unknown(underlying: error)
        }

        return OAuthTokenResponse(
            accessToken: dto.accessToken,
            refreshToken: dto.refreshToken,
            expiresIn: dto.expiresIn
        )
    }

    /// Classifies an RFC 6749 §5.2 error body returned for a rejected grant.
    ///
    /// On the AUTHORIZATION-CODE grant every 400 is `ComfyError.authCodeRejected`,
    /// parseable body or not. The HTTP 400 on this grant *is* the refusal signal —
    /// the code was expired, already redeemed, unknown, or mismatched against the
    /// `client_id` / `redirect_uri` / PKCE verifier — and there is no
    /// consumer-meaningful difference between "refused with a body we could not
    /// parse" and "refused", so the unparseable case carries `code: nil, detail: nil`
    /// rather than landing somewhere else. It must NOT become `.authExpired`: that
    /// drives a "your session ended, sign in again" sheet, and there is no session to
    /// expire — this is a failed first sign-in.
    ///
    /// The non-`invalid_grant` codes reach the same case rather than `.unknown`
    /// because on this grant they are still a refusal of *this* exchange, and the
    /// consumer's one public handle on that is `.authCodeRejected`. What separates
    /// them is the recovery, not the classification, so `code` carries the
    /// distinction and `ComfyError.authCodeRejected` documents it per-value: only
    /// `invalid_grant` says "start sign-in again", and the rest say "your client
    /// configuration is wrong". That is the asymmetry with the refresh grant below,
    /// where `.authExpired` encodes one specific recovery and so cannot absorb them.
    ///
    /// On the REFRESH grant `invalid_grant` is the one recoverable-by-re-authentication
    /// case: the refresh token is expired, revoked, reused, or unknown to the server,
    /// and `.authExpired` is what routes the user back through sign-in. Every other
    /// code there (`invalid_request`, `invalid_client`, `unauthorized_client`,
    /// `unsupported_grant_type` — a malformed request, i.e. a client bug) and an
    /// unparseable body surface as `.unknown(OAuthTokenEndpointError)` rather than
    /// `.network`, which would invite a retry loop that can only fail again.
    private static func grantRejection(
        from data: Data,
        isRefreshGrant: Bool,
        redacting secrets: [String]
    ) -> ComfyError {
        guard let dto = try? JSONDecoder().decode(TokenErrorDTO.self, from: data) else {
            return isRefreshGrant
                ? .unknown(underlying: OAuthTokenEndpointError(code: nil, detail: nil))
                : .authCodeRejected(code: nil, detail: nil)
        }
        // Match on a normalized code. RFC 6749 §5.2 codes are canonically lowercase,
        // so this is off the happy path, but a proxy that re-cases, pads, or splices a
        // BOM through the value must not cost the user the one route back into
        // re-authentication — `normalizeCode` sanitizes, so the match sees exactly the
        // string reported below rather than a rawer one that can disagree with it.
        // Redaction is deliberately NOT applied here: it is the one step that can
        // destroy a genuine code, and an `invalid_grant` cannot contain one of the
        // request's own secrets for it to strike out.
        if isRefreshGrant, normalizeCode(dto.error) == "invalid_grant" {
            return .authExpired
        }
        // The length floor applies to the RFC code ONLY — see
        // `minimumSecretLengthForCodeRedaction`. `error_description` is free text a
        // server can echo a credential into, so every non-empty secret is struck
        // from it regardless of length.
        let codeSecrets = secrets.filter { $0.count >= minimumSecretLengthForCodeRedaction }
        // Scrub FIRST, then normalize. `redact` matches the request's secrets
        // verbatim, so lowercasing first would let a secret the server echoed back
        // with different casing slip past redaction and into a consumer's logs.
        // Then clamp AGAIN, because the clamp inside `scrub` necessarily ran before
        // that case folding and folding is not length-preserving: U+0130 lowercases
        // to two scalars (2 UTF-8 bytes becoming 3), so a run of them would leave the
        // 64-byte bound `ComfyError.authCodeRejected` documents unconditionally by
        // half. Re-clamping is idempotent for every ordinary code.
        let code = OAuthTokenEndpointError.clamp(
            normalizeCode(scrub(dto.error, redacting: codeSecrets, to: 64)),
            to: 64
        )
        let detail = dto.errorDescription.map { scrub($0, redacting: secrets, to: 200) }
        // Empty is `nil` for BOTH fields. An `error` that is empty (or only separators)
        // carries nothing a consumer can branch on, and an `error_description` that was
        // sent empty — or that `sanitize` reduced to empty — carries nothing to show.
        // `OAuthTokenEndpointError.description` hides an empty `detail` behind its own
        // check, but `ComfyError.authCodeRejected` is a bare payload with no renderer,
        // so without this a consumer's `if let detail { show(detail) }` renders blank.
        let reportableCode = code.isEmpty ? nil : code
        let reportableDetail = (detail?.isEmpty == true) ? nil : detail
        guard isRefreshGrant else {
            return .authCodeRejected(code: reportableCode, detail: reportableDetail)
        }
        return .unknown(
            underlying: OAuthTokenEndpointError(code: reportableCode, detail: reportableDetail)
        )
    }

    /// The single normalization applied to an endpoint-supplied RFC 6749 §5.2 `error`
    /// — by the refresh grant's `invalid_grant` match and by both public payloads
    /// (`ComfyError.authCodeRejected`'s `code` and `OAuthTokenEndpointError.code`), so
    /// what the SDK branches on and what it hands the consumer agree.
    ///
    /// `sanitize` runs first so that agreement actually holds. Without it the two
    /// disagree on everything `sanitize` strips that
    /// `trimmingCharacters(in: .whitespacesAndNewlines)` does not — any Cc/Cf scalar,
    /// a BOM being the likeliest from a proxy. An `error` of `"\u{feff}invalid_grant"`
    /// would then miss the refresh grant's `invalid_grant` branch below and still be
    /// reported as `code: "invalid_grant"`: a dead refresh token surfacing as
    /// `.unknown`, with the app never routed into re-authentication.
    private static func normalizeCode(_ value: String) -> String {
        sanitize(value).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Prepares an endpoint-controlled string for an error a consumer may log:
    /// redact the request's own secrets, flatten anything that could forge a log
    /// line, then bound the length — in that order. Redaction runs BEFORE clamping
    /// because clamping first could split a secret in half and leave the surviving
    /// prefix in the message. Running it before `sanitize` loses nothing: the match
    /// already ignores every scalar `sanitize` would drop or collapse, so it sees
    /// the same credential either side of that step.
    private static func scrub(_ text: String, redacting secrets: [String], to limit: Int) -> String {
        OAuthTokenEndpointError.clamp(sanitize(redact(secrets, in: text)), to: limit)
    }

    /// Strips Unicode control and format characters — newlines, ANSI escapes, bidi
    /// overrides — and collapses whitespace runs. `LocalizedError.errorDescription`
    /// makes these server-controlled strings the value of `localizedDescription`,
    /// which consumers log and render, so a misbehaving endpoint must not be able to
    /// forge extra log lines or reorder the text of a user-facing alert.
    private static func sanitize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var wantsSeparator = false
        for scalar in text.unicodeScalars {
            // Whitespace first: newlines and tabs are control characters too, but they
            // separate words, so they collapse to a space rather than vanishing.
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                wantsSeparator = !scalars.isEmpty
                continue
            }
            if CharacterSet.controlCharacters.contains(scalar) {
                continue
            }
            if wantsSeparator {
                scalars.append(" ")
                wantsSeparator = false
            }
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// The request values that must never survive into an error a consumer may log
    /// (NFR-S2). The 400 body has no token fields of its own per RFC 6749 §5.2, so
    /// this guards only against a server echoing back what we sent it.
    private static func secretValues(in items: [URLQueryItem]) -> [String] {
        let sensitive: Set<String> = ["refresh_token", "code", "code_verifier", "client_secret"]
        return items.compactMap { item in
            guard sensitive.contains(item.name), let value = item.value, !value.isEmpty else {
                return nil
            }
            return value
        }
    }

    /// The length floor for redacting inside the RFC 6749 §5.2 `error` code, and
    /// only there. Matching is unanchored, so a very short value also matches inside
    /// ordinary words: a `code_verifier` of `"v"` rewrites the code into
    /// `in<redacted>alid_grant` and destroys the one machine-readable field a
    /// consumer can branch on. Skipping short values costs nothing here, because the
    /// codes are a fixed RFC vocabulary that never carries a credential. The
    /// free-text `error_description` is the opposite case and takes no floor.
    private static let minimumSecretLengthForCodeRedaction = 8

    private static func redact(_ secrets: [String], in text: String) -> String {
        let placeholder = "<redacted>"
        // Longest first: the replacements are sequential, so a shorter secret that
        // happens to be a substring of a longer one would otherwise punch a hole
        // through the longer value before its own match runs, fragmenting it and
        // leaving most of that credential in the message.
        return secrets.sorted { $0.count > $1.count }.reduce(text) { partial, secret in
            // A server can echo back either the value we sent or the percent-encoded
            // form it actually received on the wire — a standard-base64 token
            // containing `+`, `/` or `=` travels as `%2B`, `%2F`, `%3D` — so a
            // redaction that only matches the decoded value leaves a reversible
            // credential in the message. Both variants have to go.
            let stripped = replacingMatches(of: secret, in: partial, with: placeholder)
            guard let encoded = percentEncoded(secret), encoded != secret else {
                return stripped
            }
            return replacingMatches(of: encoded, in: stripped, with: placeholder)
        }
    }

    /// Scalars a server can splice through an echoed credential without changing how
    /// it reads back: whitespace, which `sanitize` collapses to a single space, and
    /// Unicode control/format characters (Cc/Cf — `\u{00ad}`, `\u{200d}`), which it
    /// deletes outright. Neither leaves the credential unrecoverable to a reader, so
    /// an exact match is the wrong test: `ab\ncd` and `ab\u{00ad}cd` are both `abcd`
    /// to anyone reading the log. Matching ignores them on both sides instead.
    private static func isSeparatorForMatching(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(scalar)
            || CharacterSet.controlCharacters.contains(scalar)
    }

    /// Case-folds the hex digits of every `%XX` escape to uppercase and leaves every
    /// other scalar exactly as it was.
    ///
    /// `addingPercentEncoding` emits uppercase escapes, so `percentEncoded` produces
    /// `%2B` — but RFC 3986 §6.2.2.1 makes `%2b` the same octet, and an endpoint or
    /// proxy that re-encodes the value it echoes back may well emit the lowercase
    /// form. `replacingMatches` compares scalars exactly, so without this the
    /// percent-encoded pass in `redact` misses that echo and a trivially reversible
    /// credential survives into `ComfyError.authCodeRejected` (NFR-S2). Folding is
    /// confined to escape hex rather than applied to the whole string because the
    /// secrets themselves are case-sensitive (a base64 `code` re-cased is a different
    /// value), and a blanket case-insensitive match would over-redact ordinary words
    /// out of `error_description`.
    ///
    /// The mapping is scalar-for-scalar, so index alignment with the input is exact —
    /// which is what lets `replacingMatches` match on the folded form while still
    /// slicing the original.
    private static func normalizingEscapeHex(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var folded = scalars
        var index = 0
        while index + 2 < folded.count {
            guard folded[index] == "%",
                  isASCIIHexDigit(folded[index + 1]),
                  isASCIIHexDigit(folded[index + 2]) else {
                index += 1
                continue
            }
            folded[index + 1] = uppercasedASCII(folded[index + 1])
            folded[index + 2] = uppercasedASCII(folded[index + 2])
            index += 3
        }
        return folded
    }

    private static func isASCIIHexDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && Character(scalar).isHexDigit
    }

    private static func uppercasedASCII(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        guard scalar.value >= 0x61, scalar.value <= 0x7A,
              let upper = Unicode.Scalar(scalar.value - 0x20) else { return scalar }
        return upper
    }

    /// Replaces every occurrence of `needle` in `text` with `placeholder`, ignoring
    /// any separator scalars spliced through either side and any difference in the
    /// hex case of `%XX` escapes (NFR-S2).
    ///
    /// Both sides are reduced to the scalars that actually carry them, each surviving
    /// haystack scalar remembering where it came from, so a hit in the reduced form
    /// maps back to the span it occupied in the original. The whole span goes — the
    /// spliced separators inside it disappear with the credential — while separators
    /// that merely sit next to it are left alone, since the mapped span runs from the
    /// match's first carrying scalar to its last. Matching runs over the
    /// escape-hex-folded view of both sides, but the output is always sliced from the
    /// untouched original, so a haystack that was never a match comes back byte-identical.
    private static func replacingMatches(
        of needle: String,
        in text: String,
        with placeholder: String
    ) -> String {
        let needleScalars = Array(needle.unicodeScalars.filter { !isSeparatorForMatching($0) })
        guard !needleScalars.isEmpty else { return text }
        let needleMatch = normalizingEscapeHex(needleScalars)

        let textScalars = Array(text.unicodeScalars)
        var carrying: [Unicode.Scalar] = []
        var origin: [Int] = []
        carrying.reserveCapacity(textScalars.count)
        origin.reserveCapacity(textScalars.count)
        for (index, scalar) in textScalars.enumerated() where !isSeparatorForMatching(scalar) {
            carrying.append(scalar)
            origin.append(index)
        }
        guard carrying.count >= needleMatch.count else { return text }
        let carryingMatch = normalizingEscapeHex(carrying)

        var output = String.UnicodeScalarView()
        var emitted = 0
        var probe = 0
        var foundAny = false
        while probe + needleMatch.count <= carryingMatch.count {
            var isMatch = true
            for offset in 0..<needleMatch.count where carryingMatch[probe + offset] != needleMatch[offset] {
                isMatch = false
                break
            }
            guard isMatch else {
                probe += 1
                continue
            }
            let start = origin[probe]
            let end = origin[probe + needleMatch.count - 1]
            output.append(contentsOf: textScalars[emitted..<start])
            output.append(contentsOf: placeholder.unicodeScalars)
            emitted = end + 1
            probe += needleMatch.count
            foundAny = true
        }
        guard foundAny else { return text }
        output.append(contentsOf: textScalars[emitted...])
        return String(output)
    }

    /// The RFC 3986 unreserved set. Everything outside it is percent-encoded in the
    /// form body — and must therefore also be recognised by `redact`.
    private static var formURLUnreserved: CharacterSet {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }

    private static func percentEncoded(_ value: String) -> String? {
        value.addingPercentEncoding(withAllowedCharacters: formURLUnreserved)
    }

    /// Serializes query items as an `application/x-www-form-urlencoded` body.
    /// Unlike `URLComponents.query` (which encodes with `.urlQueryAllowed` and
    /// leaves `+`, `&`, and `=` unescaped), this percent-encodes every character
    /// outside the RFC 3986 unreserved set, so an opaque token value — e.g. a
    /// standard-base64 `code`/`refresh_token` containing `+` — survives the
    /// round-trip instead of being decoded server-side as a space or corrupting
    /// adjacent form fields.
    private static func formURLEncoded(_ items: [URLQueryItem]) -> String {
        items
            .map { "\(percentEncoded($0.name) ?? "")=\(percentEncoded($0.value ?? "") ?? "")" }
            .joined(separator: "&")
    }
}

/// The REFRESH grant's token endpoint rejected the request with an HTTP 400 that is
/// not `invalid_grant` — a client implementation bug rather than a dead session — or
/// with a 400 whose body could not be parsed as RFC 6749 §5.2. Those are the only
/// paths that reach this type: the refresh grant's `invalid_grant` is
/// `ComfyError.authExpired`, and every authorization-code-grant 400 is
/// `ComfyError.authCodeRejected`, which carries the same two fields publicly.
///
/// Only the endpoint's own `error` / `error_description` fields are carried — the
/// raw body is never retained — and both are scrubbed of the request's own secret
/// values (in both their raw and percent-encoded forms), stripped of control
/// characters, and length-clamped, so a server that echoes back what we sent it
/// cannot leak a credential into a consumer's logs through here (NFR-S2).
struct OAuthTokenEndpointError: Error, CustomStringConvertible, LocalizedError {
    /// The RFC 6749 §5.2 `error` code, or `nil` when the body was unparseable or
    /// carried no usable code.
    let code: String?
    /// The optional `error_description`, redacted, sanitized, and clamped.
    let detail: String?

    /// Bounds an endpoint-controlled string for logging. The cap is a UTF-8 **byte**
    /// budget rather than `count`, which measures grapheme clusters: one base
    /// character carrying a long run of combining marks has `count == 1` and would
    /// slip through a character-based cap whole. The ellipsis is charged against the
    /// same budget, so the result never exceeds `limit` bytes.
    static func clamp(_ value: String, to limit: Int) -> String {
        guard value.utf8.count > limit else { return value }
        let ellipsis = "…"
        let budget = limit - ellipsis.utf8.count
        var truncated = ""
        var used = 0
        for character in value {
            let width = String(character).utf8.count
            guard used + width <= budget else { break }
            truncated.append(character)
            used += width
        }
        return truncated + ellipsis
    }

    var description: String {
        let base = "OAuth token endpoint returned HTTP 400"
        let shownDetail = (detail?.isEmpty == false) ? detail : nil
        switch (code, shownDetail) {
        case let (code?, shownDetail?):
            return "\(base) \(code): \(shownDetail)"
        case let (code?, nil):
            return "\(base) \(code)"
        case let (nil, shownDetail?):
            return "\(base) with no error code: \(shownDetail)"
        case (nil, nil):
            return "\(base) with an unparseable body"
        }
    }

    var errorDescription: String? { description }
}
