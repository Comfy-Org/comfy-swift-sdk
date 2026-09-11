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
    ///   still enters the arm below — it surfaces as
    ///   `.unknown(OAuthTokenEndpointError)`, never `.authExpired` and never
    ///   `.network`.
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
        // again — a user who let the authorization code expire in an open browser
        // hits this every time. For the refresh grant it additionally hides
        // `.authExpired`, the one signal the app's re-sign-in flow keys on.
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
    /// On the REFRESH grant `invalid_grant` is the one recoverable-by-re-authentication
    /// case: the refresh token is expired, revoked, reused, or unknown to the server,
    /// and `.authExpired` is what routes the user back through sign-in.
    ///
    /// On the AUTHORIZATION-CODE grant the same code means the *code* was expired,
    /// already redeemed, or refused — a failed first sign-in, with no session to
    /// expire — so it must NOT become `.authExpired`, which drives a "your session
    /// ended, sign in again" sheet that misdescribes what happened and sends the user
    /// back into the sign-in they just failed. It lands on `.unknown` carrying the
    /// endpoint's own code, alongside every other 400.
    ///
    /// Every other defined code (`invalid_request`, `invalid_client`,
    /// `unauthorized_client`, `unsupported_grant_type`) reports a malformed request —
    /// a client bug — and an unparseable body is equally not something a retry fixes,
    /// so both surface as `.unknown` rather than `.network`, which would invite a
    /// useless retry loop.
    private static func grantRejection(
        from data: Data,
        isRefreshGrant: Bool,
        redacting secrets: [String]
    ) -> ComfyError {
        guard let dto = try? JSONDecoder().decode(TokenErrorDTO.self, from: data) else {
            return .unknown(underlying: OAuthTokenEndpointError(code: nil, detail: nil))
        }
        // Match on a normalized code. RFC 6749 §5.2 codes are canonically lowercase,
        // so this is off the happy path, but a proxy that re-cases or pads the value
        // must not cost the user the one route back into re-authentication.
        let normalizedCode = dto.error.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if isRefreshGrant, normalizedCode == "invalid_grant" {
            return .authExpired
        }
        let code = scrub(dto.error, redacting: secrets, to: 64)
        let detail = dto.errorDescription.map { scrub($0, redacting: secrets, to: 200) }
        return .unknown(
            underlying: OAuthTokenEndpointError(
                // An `error` that is empty (or only separators) carries nothing a
                // consumer can branch on, and `nil` is what `code` promises for that.
                code: code.isEmpty ? nil : code,
                detail: detail
            )
        )
    }

    /// Prepares an endpoint-controlled string for an error a consumer may log:
    /// redact the request's own secrets, flatten anything that could forge a log
    /// line, then bound the length — in that order. Redaction runs BEFORE clamping
    /// because clamping first could split a secret in half and leave the surviving
    /// prefix in the message.
    ///
    /// It runs on BOTH sides of `sanitize`, because neither pass alone is enough.
    /// Before, so a secret whose own bytes `sanitize` would rewrite (an embedded
    /// space it collapses) is still matched verbatim. After, because a server can
    /// echo a secret with Cc/Cf scalars spliced through it — `ab\u{00ad}cd` for
    /// `abcd`, invisible when rendered — which defeats the exact match on the first
    /// pass; `sanitize` then strips those scalars and reassembles the plaintext
    /// credential. Re-matching the sanitized text is what keeps it out of `detail`
    /// (NFR-S2).
    private static func scrub(_ text: String, redacting secrets: [String], to limit: Int) -> String {
        let redacted = redact(secrets, in: sanitize(redact(secrets, in: text)))
        return OAuthTokenEndpointError.clamp(redacted, to: limit)
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

    /// Values shorter than this are not treated as secrets. `redact` is an
    /// unanchored substring replacement, so a very short value also matches inside
    /// ordinary words: a `code_verifier` of `"v"` rewrites the endpoint's own code
    /// into `in<redacted>alid_grant`, destroying the one machine-readable field a
    /// consumer can branch on. Nothing worth protecting is skipped — RFC 7636 §4.1
    /// puts a `code_verifier` at 43–128 characters, and authorization codes and
    /// refresh tokens are opaque high-entropy strings of comparable length, so a
    /// value this short is not a credential.
    private static let minimumRedactableLength = 8

    private static func redact(_ secrets: [String], in text: String) -> String {
        let placeholder = "<redacted>"
        // Longest first: the replacements are sequential, so a shorter secret that
        // happens to be a substring of a longer one would otherwise punch a hole
        // through the longer value before its own match runs, fragmenting it and
        // leaving most of that credential in the message.
        let redactable = secrets
            .filter { $0.count >= minimumRedactableLength }
            .sorted { $0.count > $1.count }
        return redactable.reduce(text) { partial, secret in
            // A server can echo back either the value we sent or the percent-encoded
            // form it actually received on the wire — a standard-base64 token
            // containing `+`, `/` or `=` travels as `%2B`, `%2F`, `%3D` — so a
            // redaction that only matches the decoded value leaves a reversible
            // credential in the message. Both variants have to go.
            let stripped = partial.replacingOccurrences(of: secret, with: placeholder)
            guard let encoded = percentEncoded(secret), encoded != secret else {
                return stripped
            }
            return stripped.replacingOccurrences(of: encoded, with: placeholder)
        }
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

/// The token endpoint rejected the request with an HTTP 400 that is not
/// `invalid_grant` — a client implementation bug rather than a dead session —
/// or with a 400 whose body could not be parsed as RFC 6749 §5.2.
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
