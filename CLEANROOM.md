# CLEANROOM DECLARATION

## Sources Consulted
- PAR2 “Parity Volume Set Specification 2.0” (Parchive, 2003‑05‑11) — primary format/spec reference.
- Parchive project site (context/metadata).
- Library of Congress format description (format context).
- Bitrot Guard heuristic script for block-size heuristics: `/Users/pmarreck/Documents-CloudManaged/bitrot_guard/bitrot_guard.bash`.
- Empirical black‑box behavior checks against `par2cmdline-turbo` via CLI tests (no source inspection).

## Sources Explicitly Not Consulted
- Any PAR2 implementation source code (including par2cmdline, par2cmdline‑turbo, libpar2, MultiPar, etc.).
- Any reverse‑engineered decompilations or disassemblies.
- Any proprietary/vendor/internal documentation not publicly available.

## Independent Implementation Statement
All code in this repository was produced from publicly available specifications, documentation, and black‑box interoperability tests. No implementation source code from other PAR2 tools was read, copied, or referenced. Behavior inferred from other tools was derived solely by executing them and comparing outputs, without inspecting their source.

## Training Data Note (Process-Based Statement)
This implementation was authored during this project using only the sources listed above. No third‑party PAR2 implementation source code was consulted during development. The record of work (CLEANROOM.md + logs) is intended to document the cleanroom process used here.

## Implementation Date Range
Initial cleanroom specification and scaffolding: 2025‑12‑24.  
Active implementation and verification: 2025‑12‑24 through 2025‑12‑30.

## Optional Receipts
Full conversation logs are not embedded here. If required, provide a complete chat export separately (subject to platform availability and context retention).
