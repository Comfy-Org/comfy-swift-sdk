//
//  ImportBoundaryTests.swift
//  ComfySwiftSDKTests
//
//  In-repo SDK import-boundary enforcement. Scans every `.swift` file under
//  `Sources/ComfySwiftSDK/` for forbidden imports (`SwiftUI`, `SwiftData`, `Photos`, `Security`)
//  and asserts that every `import` line resolves to a module in the
//  canonical SDK allowlist (`Foundation`, `CryptoKit`, `os`). The
//  allowlist test catches future drift like an accidental
//  `import Combine`, `import UIKit`, or `import Network`.
//
//  How it works:
//    The scan walks the file system, NOT the loaded module. The goal is
//    to catch forbidden imports as text, before they ever link. In the
//    SDK's own repo the sources are definitionally present at
//    `Sources/ComfySwiftSDK/`, so we anchor the source tree off
//    `#filePath` — the compiled-in path of THIS test file — and climb
//    two directory levels to the package root (see `locateSDKSources()`).
//    This is deliberately NOT the app-target's bundle/DerivedData
//    ancestor-walk (`Bundle(for:).bundleURL`): that mechanism exists to
//    find a REMOTE SPM checkout under a consuming app's DerivedData; here
//    the sources are a fixed sibling of this file, so the `#filePath`
//    anchor is both simpler and more robust. Failure messages
//    name the offending file (with its `Sources/ComfySwiftSDK/`-relative
//    path so two files with the same `lastPathComponent` are unambiguous)
//    and the offending line.
//
//  Import parsing:
//    A naive `trimmed == "import Foundation"` check is too narrow.
//    Swift accepts a number of `import` forms that such a check would
//    either silently allow or silently reject:
//      - `@_implementationOnly import SwiftUI`   ← would bypass
//      - `@_exported import SwiftUI`             ← would bypass
//      - `@preconcurrency import SwiftUI`        ← would bypass
//      - `@testable import SwiftUI`              ← would bypass
//      - `import struct Foundation.Date`         ← would false-positive
//      - `import class Foundation.NSDate`        ← would false-positive
//      - `@preconcurrency @_exported import SwiftUI` (stacked attrs)
//      - `import struct Foundation.Date; import SwiftUI` (`;`-joined)
//    The scan runs in two steps. `strippedForScanning(_:)` first lexes
//    the whole file, blanking comment and string-literal *content*
//    while preserving newlines — so an `import` hidden inside a `/* */`
//    block comment or a `"""..."""` string cannot cause a spurious
//    failure, and a real `import` sharing a line with a comment is
//    still seen. `importModules(in:)` then splits each line on `;` so a
//    second statement after a semicolon is not dropped, and hands each
//    statement to `parseImportModuleName(from:)`, which strips any
//    stacked leading `@`-attributes, skips the optional `struct`/
//    `class`/`func`/`enum`/`protocol`/`var`/`let`/`typealias`/`actor`
//    kind keyword, and extracts the *top-level* module name (e.g.
//    `Foundation` from `Foundation.Date`). The denylist and allowlist
//    checks then both compare module names — never raw line text — so
//    the canonical forms and the attributed/scoped forms behave
//    identically.
//
//  Why this enforcement is load-bearing:
//    The SDK boundary discipline says the SDK never imports SwiftUI,
//    SwiftData, Photos, or Security. Code review catches new violations
//    *most* of the time, but a single accidental `import SwiftUI` in a
//    future change would silently link the SwiftUI runtime into the SDK,
//    defeat the "SDK is reusable across surfaces" property, and force any
//    future consumer to inherit a UI-framework dependency they don't
//    want. This test catches the violation under the package's own
//    `swift test` CI, before the diff lands.
//
//  Note on test scope:
//    The boundary rule applies to `Sources/ComfySwiftSDK/` only.
//    `Tests/ComfySwiftSDKTests/` may import `Testing` and use
//    `@testable import ComfySwiftSDK` because test code is not part of
//    the SDK contract. The scan in this file deliberately walks
//    `Sources/` and not `Tests/`.
//

import Testing
import Foundation

@Suite("ImportBoundary — SDK import boundary (NFR-M1/M2)")
struct ImportBoundaryTests {

    /// The canonical allowlist of modules an SDK source file is
    /// permitted to import. Adding a module here must be reviewed
    /// against the SDK's architectural boundaries — the SDK is meant
    /// to depend only on Foundation. Future low-level additions like
    /// `FoundationNetworking` (Linux) or `Combine` (decision deferred)
    /// need an explicit review before they land in this set.
    ///
    /// `CryptoKit` was reviewed and admitted: the PKCE S256
    /// code-challenge (RFC 7636 §4.2) needs `SHA256`, CryptoKit is a
    /// UI-free Apple system framework outside the four-module denylist,
    /// and the alternative (`Security`/SecRandomCopyBytes or a
    /// hand-rolled SHA-256) is strictly worse. Used only by
    /// `Public/ComfyCloudClient.swift`.
    ///
    /// `os` (unified logging / `os.Logger`) is admitted for the same
    /// reason CryptoKit was, and by the same review flow: the SDK has a
    /// dedicated logging abstraction (`Internal/SDKLog.swift`) that uses
    /// `os.Logger`; `os` is a UI-free Apple system framework outside the
    /// four-module NFR-M1/M2 denylist (`SwiftUI`/`SwiftData`/`Photos`/
    /// `Security`), which the four denylist tests below still enforce
    /// independently of this allowlist. It is the logging analogue of
    /// CryptoKit's crypto — a legitimately-needed low-level system
    /// module, reviewed and admitted rather than a UI-framework leak.
    private static let allowedSDKImports: Set<String> = [
        "Foundation",
        "CryptoKit",
        "os"
    ]

    /// Test failure thrown when the boundary scan cannot proceed
    /// because the SDK source tree is missing or unreadable. Surfaces
    /// as a real test failure rather than a vacuous pass, so a moved
    /// test file or a broken checkout cannot silently disable boundary
    /// enforcement.
    private struct BoundaryScanError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// Resolve the ComfySwiftSDK `Sources/ComfySwiftSDK` directory on
    /// disk by anchoring off `#filePath` (the compiled-in path of this
    /// test file) and climbing to the package root. In the SDK's own
    /// repo the sources are a fixed sibling of this file, so no
    /// bundle/DerivedData walk is needed.
    ///
    /// Throws `BoundaryScanError` when the directory is missing, so the
    /// sanity test remains a real tripwire rather than a vacuous pass.
    private func locateSDKSources() throws -> URL {
        let sourcesDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ComfySwiftSDKTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // package root
            .appendingPathComponent("Sources/ComfySwiftSDK")

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourcesDir.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw BoundaryScanError(
                message: "SDK source tree not found at \(sourcesDir.path) — boundary scan cannot proceed. Anchored off #filePath (\(#filePath)); expected Sources/ComfySwiftSDK two levels up from Tests/ComfySwiftSDKTests/. If the test file moved, fix the climb in locateSDKSources()."
            )
        }
        return sourcesDir
    }

    /// Walks the ComfySwiftSDK `Sources/ComfySwiftSDK` tree recursively.
    /// Returns a list of `(relative path, file contents)` tuples. The
    /// relative path is rooted at the sources dir (e.g.
    /// `Internal/Transport.swift`) so two files with the same
    /// `lastPathComponent` in different folders produce unambiguous
    /// failure messages.
    ///
    /// Throws `BoundaryScanError` if the SDK source tree is missing or
    /// the file enumerator cannot be constructed. Returning an empty
    /// array on those failure paths would create a vacuous pass.
    private func loadAllSDKSourceFiles() throws -> [(path: String, contents: String)] {
        let sdkSources = try locateSDKSources()

        guard let enumerator = FileManager.default.enumerator(
            at: sdkSources,
            includingPropertiesForKeys: nil
        ) else {
            throw BoundaryScanError(
                message: "FileManager.enumerator failed for \(sdkSources.path) — boundary scan cannot proceed."
            )
        }

        let sourcesPrefix = sdkSources.standardizedFileURL.path + "/"
        var results: [(path: String, contents: String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let contents = try String(contentsOf: url, encoding: .utf8)
            let absolutePath = url.standardizedFileURL.path
            let relativePath: String
            if absolutePath.hasPrefix(sourcesPrefix) {
                relativePath = String(absolutePath.dropFirst(sourcesPrefix.count))
            } else {
                // Defensive fallback — should never hit, but better to
                // surface the absolute path than crash.
                relativePath = url.lastPathComponent
            }
            results.append((path: relativePath, contents: contents))
        }
        return results
    }

    /// Parse a single line of Swift source and, if it is an `import`
    /// statement, return the top-level module name. Returns nil if
    /// the line is not an import. Handles:
    ///   - `import Foundation`
    ///   - `import Foundation;`
    ///   - `@_implementationOnly import SwiftUI`
    ///   - `@_exported import SwiftUI`
    ///   - `@preconcurrency import SwiftUI`
    ///   - `@testable import SwiftUI`
    ///   - `import struct Foundation.Date`
    ///   - `import class Foundation.NSDate`
    ///   - `import func Foundation.someFunction`
    ///
    /// The returned name is always the top-level module — for
    /// `import struct Foundation.Date` the function returns
    /// `"Foundation"`, not `"Date"`. The allowlist and denylist
    /// checks compare module names, so the same allow/deny decision
    /// applies regardless of which scoped form the source uses.
    static func parseImportModuleName(from line: String) -> String? {
        // `.whitespacesAndNewlines` (not `.whitespaces`) so a trailing
        // carriage return on a CRLF-checked-out file is stripped too;
        // otherwise `import Foundation;\r` would keep the `\r` and parse
        // as the module `Foundation;`.
        var working = line.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip a trailing line comment so `import Foo // note` works.
        // (Callers that scan whole files pre-strip comments via
        // `strippedForScanning`; this keeps the parser correct when
        // called on a raw single line too.)
        if let commentRange = working.range(of: "//") {
            working = String(working[..<commentRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Strip leading import attributes (e.g. `@_implementationOnly`,
        // `@_exported`, `@preconcurrency`, `@testable`). Attributes may
        // stack — `@preconcurrency @_exported import SwiftUI` is valid —
        // so loop until no leading `@`-attribute remains, otherwise a
        // stacked-attribute import would slip past the `hasPrefix("import")`
        // guard below and evade both the denylist and allowlist scans.
        while working.hasPrefix("@") {
            // Find the first whitespace after the attribute and skip
            // past it.
            guard let firstSpace = working.firstIndex(where: { $0.isWhitespace }) else {
                return nil
            }
            working = String(working[working.index(after: firstSpace)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard working.hasPrefix("import") else { return nil }
        // Require a word boundary so `importance = 1` is not parsed as
        // an import.
        let afterImport = working.index(working.startIndex, offsetBy: "import".count)
        if afterImport < working.endIndex {
            let next = working[afterImport]
            guard next.isWhitespace else { return nil }
        } else {
            return nil
        }

        var rest = String(working[afterImport...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip a trailing semicolon, if any. (Whole-file callers split
        // statements on `;` first, but a single line handed straight in
        // may still carry one.)
        if rest.hasSuffix(";") {
            rest = String(rest.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Tokenize on whitespace. The first token may be a kind
        // keyword (`struct`/`class`/`func`/`enum`/`protocol`/`var`/
        // `let`/`typealias`); if so, the second token is the
        // qualified module name. Otherwise the first token is the
        // module name itself.
        let kindKeywords: Set<String> = [
            "struct", "class", "func", "enum", "protocol",
            "var", "let", "typealias", "actor"
        ]
        let tokens = rest.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return nil }

        let qualifiedName: String
        if kindKeywords.contains(tokens[0]) {
            guard tokens.count >= 2 else { return nil }
            qualifiedName = tokens[1]
        } else {
            qualifiedName = tokens[0]
        }

        // The qualified name may be `Foundation.Date` or
        // `Foundation.NSDate`; we only care about the top-level module.
        let topLevel = qualifiedName.split(separator: ".").first.map(String.init)
        return topLevel
    }

    /// Return a copy of `source` with every comment and string-literal
    /// *content* replaced by spaces, while preserving every newline so
    /// 1-based line numbers stay aligned with the original file.
    ///
    /// A line-oriented `//`-only strip is not enough: an `import` can
    /// hide inside a block comment or a string literal (a false
    /// positive that would spuriously fail `swift test`), and a real
    /// `import` can share a line with a block comment
    /// (`/* note */ import Foundation` — a false negative). Running the
    /// scan over this lexed copy closes both blind spots. Handles `//`
    /// line comments, nested `/* ... */` block comments (Swift allows
    /// nesting), `"..."` strings (respecting `\` escapes), and
    /// `"""..."""` multiline strings. Raw string literals (`#"..."#`)
    /// are not special-cased — an `import` buried in one is a
    /// pathological form the SDK does not use.
    static func strippedForScanning(_ source: String) -> String {
        enum State { case code, lineComment, blockComment, string, multiString }
        var state: State = .code
        var blockDepth = 0
        let chars = Array(source)
        var output = String()
        output.reserveCapacity(chars.count)
        var i = 0
        func at(_ k: Int) -> Character? { k < chars.count ? chars[k] : nil }

        while i < chars.count {
            let c = chars[i]
            switch state {
            case .code:
                if c == "/", at(i + 1) == "/" {
                    state = .lineComment; output += "  "; i += 2
                } else if c == "/", at(i + 1) == "*" {
                    state = .blockComment; blockDepth = 1; output += "  "; i += 2
                } else if c == "\"", at(i + 1) == "\"", at(i + 2) == "\"" {
                    state = .multiString; output += "   "; i += 3
                } else if c == "\"" {
                    state = .string; output += " "; i += 1
                } else {
                    output.append(c); i += 1
                }
            case .lineComment:
                if c == "\n" { state = .code; output.append("\n") } else { output.append(" ") }
                i += 1
            case .blockComment:
                if c == "/", at(i + 1) == "*" {
                    blockDepth += 1; output += "  "; i += 2
                } else if c == "*", at(i + 1) == "/" {
                    blockDepth -= 1; output += "  "; i += 2
                    if blockDepth == 0 { state = .code }
                } else {
                    output.append(c == "\n" ? "\n" : " "); i += 1
                }
            case .string:
                if c == "\\" {
                    // Escaped char — consume both so a `\"` does not
                    // close the string. Preserve a newline if one
                    // follows, to keep line numbers aligned.
                    output.append(" "); i += 1
                    if i < chars.count { output.append(chars[i] == "\n" ? "\n" : " "); i += 1 }
                } else if c == "\"" {
                    state = .code; output.append(" "); i += 1
                } else if c == "\n" {
                    // Unterminated single-line string — bail back to code
                    // rather than swallowing the rest of the file.
                    state = .code; output.append("\n"); i += 1
                } else {
                    output.append(" "); i += 1
                }
            case .multiString:
                if c == "\\" {
                    output.append(" "); i += 1
                    if i < chars.count { output.append(chars[i] == "\n" ? "\n" : " "); i += 1 }
                } else if c == "\"", at(i + 1) == "\"", at(i + 2) == "\"" {
                    state = .code; output += "   "; i += 3
                } else {
                    output.append(c == "\n" ? "\n" : " "); i += 1
                }
            }
        }
        return output
    }

    /// Every `import` found in `contents`, as `(1-based line, top-level
    /// module name, original line text)`. Comments and string literals
    /// are stripped first (see `strippedForScanning`) so imports inside
    /// them are ignored, and each physical line is split on `;` so a
    /// second statement after a semicolon
    /// (`import struct Foundation.Date; import SwiftUI`) is parsed too
    /// rather than silently dropped. The reported line text is the
    /// original (un-lexed) line so failure messages show the real
    /// source.
    static func importModules(
        in contents: String
    ) -> [(line: Int, module: String, text: String)] {
        let cleanedLines = strippedForScanning(contents)
            .split(separator: "\n", omittingEmptySubsequences: false)
        let originalLines = contents
            .split(separator: "\n", omittingEmptySubsequences: false)
        var result: [(line: Int, module: String, text: String)] = []
        for (index, cleaned) in cleanedLines.enumerated() {
            for statement in cleaned.split(separator: ";", omittingEmptySubsequences: false) {
                if let module = parseImportModuleName(from: String(statement)) {
                    let original = index < originalLines.count
                        ? String(originalLines[index]) : String(cleaned)
                    result.append((line: index + 1, module: module, text: original))
                }
            }
        }
        return result
    }

    /// Scan every line of every SDK source file for an `import` of
    /// `moduleName`. Returns the first matching `(file, line number,
    /// line text)` tuple, or nil if no violation is found. Comparison
    /// is on parsed module names so attributed and scoped forms (like
    /// `@_implementationOnly import SwiftUI` or `import struct
    /// SwiftUI.View`) are caught.
    private func findImport(
        of moduleName: String,
        in files: [(path: String, contents: String)]
    ) -> (file: String, line: Int, text: String)? {
        for file in files {
            for imp in Self.importModules(in: file.contents) where imp.module == moduleName {
                return (file: file.path, line: imp.line, text: imp.text)
            }
        }
        return nil
    }

    @Test func sdk_sources_do_not_import_swiftui() throws {
        let files = try loadAllSDKSourceFiles()
        let violation = findImport(of: "SwiftUI", in: files)
        #expect(
            violation == nil,
            "SDK boundary violation (NFR-M1): \(violation?.file ?? "?") line \(violation?.line ?? 0): '\(violation?.text ?? "?")'"
        )
    }

    @Test func sdk_sources_do_not_import_swiftdata() throws {
        let files = try loadAllSDKSourceFiles()
        let violation = findImport(of: "SwiftData", in: files)
        #expect(
            violation == nil,
            "SDK boundary violation (NFR-M2): \(violation?.file ?? "?") line \(violation?.line ?? 0): '\(violation?.text ?? "?")'"
        )
    }

    @Test func sdk_sources_do_not_import_photos() throws {
        let files = try loadAllSDKSourceFiles()
        let violation = findImport(of: "Photos", in: files)
        #expect(
            violation == nil,
            "SDK boundary violation: \(violation?.file ?? "?") line \(violation?.line ?? 0): '\(violation?.text ?? "?")'"
        )
    }

    @Test func sdk_sources_do_not_import_security() throws {
        let files = try loadAllSDKSourceFiles()
        let violation = findImport(of: "Security", in: files)
        #expect(
            violation == nil,
            "SDK boundary violation: \(violation?.file ?? "?") line \(violation?.line ?? 0): '\(violation?.text ?? "?")'"
        )
    }

    /// Allowlist enforcement: every `import` line in every SDK source
    /// file must resolve (after attribute/kind stripping) to a module
    /// in `allowedSDKImports`. Catches future drift like an accidental
    /// `import Combine`, `import UIKit`, or `import Network` that the
    /// four denylist tests above would miss.
    @Test func sdk_sources_only_import_allowlist() throws {
        let files = try loadAllSDKSourceFiles()
        for file in files {
            for imp in Self.importModules(in: file.contents) {
                #expect(
                    Self.allowedSDKImports.contains(imp.module),
                    "SDK boundary violation (allowlist): \(file.path) line \(imp.line): imports '\(imp.module)' but only \(Self.allowedSDKImports.sorted()) are permitted in SDK sources. Original line: '\(imp.text)'"
                )
            }
        }
    }

    /// Bare-minimum sanity check on the boundary scanner itself: the
    /// scanner must find at least one SDK source file. If this test
    /// fails, the path-climbing in `loadAllSDKSourceFiles()` is broken
    /// and every other test in this file is vacuously passing.
    @Test func boundary_scanner_finds_sdk_sources() throws {
        let files = try loadAllSDKSourceFiles()
        #expect(
            !files.isEmpty,
            "Boundary scanner found zero SDK source files — path-climbing in loadAllSDKSourceFiles() is broken."
        )
    }

    // MARK: - Parser edge cases
    //
    // These lock in the parsing corners that a line-oriented `==`
    // check (or an earlier draft of this parser) would miss. Each is a
    // real evasion or false-positive vector for the boundary scan.

    @Test func parses_plain_and_scoped_and_attributed_imports() {
        #expect(Self.importModules(in: "import Foundation\n").map(\.module) == ["Foundation"])
        #expect(Self.importModules(in: "import struct Foundation.Date\n").map(\.module) == ["Foundation"])
        #expect(Self.importModules(in: "@testable import SwiftUI\n").map(\.module) == ["SwiftUI"])
        #expect(Self.importModules(in: "let importance = 1\n").map(\.module).isEmpty)
    }

    /// Stacked import attributes must not slip past the scan (was a
    /// single-`@`-strip bug: `@preconcurrency @_exported import SwiftUI`
    /// left `@_exported import SwiftUI` and parsed to nil).
    @Test func parses_stacked_import_attributes() {
        let mods = Self.importModules(in: "@preconcurrency @_exported import SwiftUI\n").map(\.module)
        #expect(mods == ["SwiftUI"])
    }

    /// A second statement after `;` must still be parsed, not dropped.
    @Test func parses_second_statement_after_semicolon() {
        let joined = Self.importModules(in: "import struct Foundation.Date; import SwiftUI\n").map(\.module).sorted()
        #expect(joined == ["Foundation", "SwiftUI"])
        let afterCode = Self.importModules(in: "let x = 1; import SwiftUI\n").map(\.module)
        #expect(afterCode == ["SwiftUI"])
    }

    /// An `import` inside a block comment or string literal is not code
    /// and must not trip the scan (false positive); a real `import`
    /// sharing a line with a comment must still be seen (false negative).
    @Test func ignores_imports_in_comments_and_strings() {
        #expect(Self.importModules(in: "/*\nimport SwiftUI\n*/\nimport Foundation\n").map(\.module) == ["Foundation"])
        #expect(Self.importModules(in: "/* note */ import SwiftUI\n").map(\.module) == ["SwiftUI"])
        #expect(Self.importModules(in: "import/*x*/SwiftUI\n").map(\.module) == ["SwiftUI"])
        #expect(Self.importModules(in: "let s = \"import SwiftUI\"\n").map(\.module).isEmpty)
        #expect(Self.importModules(in: "let s = \"\"\"\nimport SwiftUI\n\"\"\"\n").map(\.module).isEmpty)
        // Nested block comment: the inner `*/` must not end the outer.
        #expect(Self.importModules(in: "/* a /* b */ import SwiftUI */\nimport Foundation\n").map(\.module) == ["Foundation"])
    }

    /// CRLF line endings must not leave a `\r` glued to the module name
    /// (was: `import Foundation;\r` parsed as module `Foundation;`).
    @Test func handles_crlf_line_endings() {
        #expect(Self.importModules(in: "import Foundation;\r\n").map(\.module) == ["Foundation"])
    }

    /// Reported line numbers must survive multi-line comment/string
    /// stripping so failure messages point at the real offending line.
    @Test func preserves_line_numbers_across_block_comments() {
        let src = "/*\n multi\n line\n */\nimport SwiftUI\n"
        let imp = Self.importModules(in: src).first
        #expect(imp?.module == "SwiftUI")
        #expect(imp?.line == 5)
    }
}
