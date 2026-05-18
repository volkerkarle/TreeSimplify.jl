# TreeSimplify.jl (bootstrap folder)

This folder is a staging area for a future standalone package/repository named `TreeSimplify.jl`.

## Purpose

Build a general tool to simplify very large symbolic expressions using guided search (tree search / beam search / optional MCTS), with strong correctness checks.

This is intentionally domain-agnostic. The first benchmark inputs come from a non-RWA 3-level SW calculation, but the package itself should not depend on operator algebra or a specific physics model.

## Included seed inputs

- `expressions/sw_nonrwa_order4_coeffs.txt`
- `expressions/extracted_sw_nonrwa_coefficients_output.txt`

These are initial stress-test expressions and reference simplifications.

## Files in this folder

- `SCOPE.md`: scope, goals, optional goals, and non-goals
- `AGENTS.md`: instructions for coding/research agents working in this project
- `expressions/`: seed expression files
