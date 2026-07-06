# Security Policy

Emfy parses **untrusted input by design**: Quick Look renders `.emf` files the
moment Finder shows a folder, with no user action. Robustness against hostile
or malformed files is a core goal of the project, so security reports are very
welcome.

## Supported versions

Only the latest release receives security fixes.

| Version | Supported |
|---------|-----------|
| 1.1.x   | ✅        |
| < 1.1   | ❌        |

## Reporting a vulnerability

Please report suspected vulnerabilities **privately** — do not open a public
issue for anything exploitable.

- **Preferred:** GitHub private vulnerability reporting — the *Report a
  vulnerability* button under this repository's **Security** tab.
- **Or email:** hello@neetsingh.com with the subject `Emfy - Security`.

Please include the affected version, a description of the problem, and — if you
can — a sample `.emf` file that reproduces it. A crashing or hanging sample is
the single most useful thing you can send.

## Scope

In scope (the parser and renderer treat every byte as hostile):

- Memory-safety issues, crashes, or hangs triggered by a crafted `.emf` file.
- Unbounded memory or CPU use (denial of service) from a crafted file.
- Anything that lets a file escape the read-only, sandboxed, no-network
  execution the app and its Quick Look extensions run under.

Out of scope:

- Rendering inaccuracies or unsupported records that do not affect safety.
  A file that renders wrongly is a bug, not a vulnerability — please open a
  normal issue for it (a sample file is still hugely appreciated).

## What to expect

Emfy is a solo, volunteer-maintained project, so please allow reasonable time
for a response. Confirmed issues are fixed in the next release, with credit if
you would like it.
