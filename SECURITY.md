# Security Policy

## Reporting a vulnerability

Report vulnerabilities through GitHub's private vulnerability reporting on this
repository (Security → Report a vulnerability). Please do not open a public
issue for a security report.

Include what you did, what happened, and the macOS and Voice versions. A proof
of concept helps but is not required.

## Scope

Voice runs entirely on the local machine. It holds three capabilities that are
worth attention:

- **Accessibility and Input Monitoring.** Voice watches for its dictation
  hotkey and inserts text into the frontmost application. Anything that lets
  another process drive that insertion, or that causes text to be inserted into
  an application the user did not intend, is in scope.
- **Microphone.** Voice records while the dictation key is held. Audio that is
  captured outside that window, or that is written somewhere unexpected, is in
  scope.
- **Model downloads.** Checkpoints are fetched from Hugging Face on first use
  and pinned by revision. Anything that causes a different artifact to load, or
  that escapes the model store directory, is in scope.

Speech, audio, and transcripts stay on the machine; see `docs/privacy.md`.

Out of scope: the behavior of the third-party model checkpoints themselves,
findings that require the attacker to already have code execution as the user,
and issues in dependencies that should be reported upstream.

## Supported versions

This project is pre-1.0 and tracks macOS betas. Fixes land on `main`; there are
no maintained release branches.
