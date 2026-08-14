---
type: task
blocked_by: [02, 03, 04, 05, 06]
undermined_by: []
---

# Design the verification strategy

## Question

What automated and manual checks will prove the settled behavior on macOS Big Sur and newer without requiring destructive filesystem operations? Map product rules to unit, integration, UI, geometry, performance, cancellation, and compatibility checks, and define deterministic filesystem fixtures for symlinks, hard links, packages, permissions, and deep trees.

## Done when

Every settled requirement and quality bar maps to at least one practical check, the test fixture strategy is reproducible and read-only, compatibility coverage is explicit, and the local commands or Xcode schemes needed to run verification are named.
