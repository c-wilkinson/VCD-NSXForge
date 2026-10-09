# Architectural decision records — Phase 1

## ADR-001: PowerShell 5.1 is the baseline

Use Windows PowerShell 5.1 and installed .NET Framework WinForms. Do not require PowerShell 7, PowerCLI, third-party modules, Pester or VS components. The WinForms UI must run in an STA process; worker pool runspaces are MTA.

## ADR-002: GUI and business logic are separate

Presentation modules do not contain VCD HTTP requests, desired-state parsing or network planning algorithms. The runtime exposes an operation dispatcher. Application command handlers in subsequent phases receive injected adapters and ordinary data. They can run headless in Azure DevOps later.

## ADR-003: All potentially blocking work runs off the GUI thread

Only the UI thread may touch controls. A 100 ms WinForms timer receives status from a concurrent event queue. Use `PowerShell.BeginInvoke()` for asynchronous work and call `EndInvoke()` only for completed tasks. Use per-operation cancellation tokens and correlation IDs. A form shutdown with running work cancels first, then finishes after tasks exit.

## ADR-004: Dedicated log consumer

All producers enqueue structured data. One separate logger runspace serialises all filesystem activity. Rotated logs are individually limited to 5 MB; archives are pruned after 30 days. The active log is never deleted by the retention process. No external logging libraries. Rotation uses collision-safe timestamp + sequence filenames.

## ADR-005: No live API in Phase 1

A deliberate stub/demo operation drives identical dispatcher and logger code paths without VCD or NSX connectivity. The installer needs no credentials. The read-only VCD 10.6 resource contract is now implemented behind a mandatory injected `RequestSender`, and all its operations are exercised against fail-closed mocks. There is no live request sender in Phase 1; this is deliberate. Authentication and actual HTTP transport are deferred until live read-only integration.

## ADR-006: Future API version and ownership boundaries

VMware Cloud Director 10.6 / NSX-T is fixed as the initial target. Request and negotiate supported API versions from the real instance. The API compatibility layer must separate Edge Gateway firewall APIs from DC Group DFW APIs and implement optimistic concurrency / version checks. VCD-managed objects should be changed through VCD APIs, not NSX Manager.

## ADR-007: Plan before apply

No future UI operation may directly apply network changes. A deterministic planner creates a JSON plan plus HTML report from validated offline desired state and fresh observed state. Ownership policies must restrict deletion of external resources. ADO must replan and compare with the approved change before apply.

## ADR-008: Tests require no third-party modules

A small built-in test harness offers pass/fail output, a non-zero error exit code and NUnit 3 XML. Test pure/domain modules offline with fixture inputs and mock transports; integration tests can launch real runspaces while remaining VCD-independent. Live environment read-only tests are opt-in and belong in later phases.

## ADR-009: Pure UI state and fail-closed API fixtures

The UI event-to-state transition code is headless so unit tests verify stale completion/progress handling and cancellation without starting WinForms. The only VCD API path is an injected scriptblock; the fake rejects unknown paths and non-GET methods. Tests for later write actions are required before they are added to the public contract.
