# Security Policy

## Reporting a Vulnerability

We take the security of ComfySwiftSDK seriously. If you believe you have found a
security vulnerability, please report it **privately** — do not open a public
issue, pull request, or discussion.

Use GitHub's [private vulnerability reporting](https://github.com/Comfy-Org/comfy-swift-sdk/security/advisories/new)
("Report a vulnerability" under the repository's **Security** tab). This routes
the report directly to the maintainers and keeps the details confidential until
a fix is available.

Please include where possible:

- A description of the vulnerability and its impact
- Steps to reproduce, ideally a minimal proof of concept
- The affected version, tag, or commit

## Scope

ComfySwiftSDK is a thin client library for the Comfy Cloud API. The issues most
relevant to this repository include:

- Credential handling — leakage of API keys or OAuth tokens through logs, error
  messages, or memory
- Transport security — improper TLS handling or certificate validation
- OAuth / PKCE flow weaknesses

The Comfy Cloud backend itself is out of scope for this repository. If you are
unsure where an issue belongs, report it through the channel above and we will
route it.

## Supported Versions

ComfySwiftSDK is pre-1.0. Until a 1.0 release, security fixes land on the latest
`main` and in the most recent tagged release. Pin to a tag or commit if you need
a stable surface today.

## Disclosure

We aim to acknowledge reports within a few business days and to coordinate a
disclosure timeline with you once a fix is available. We are grateful to
researchers who report responsibly.
