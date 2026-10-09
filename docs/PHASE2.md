# Phase 2: Offline state and planning

## Scope and safety

VCD 10.6 / NSX-T; Windows PowerShell 5.1; native .NET only.
**No live API transport, deploy/apply, Git integration, or editable firewall WinForms controls.**
Phase 1's injected, mock-only VCD read contract remains unchanged. Existing Phase 1
tests (including opt-in WinForms tests) still run.

The UI's new **Generate offline plan** button runs the *committed demo fixture*
in an MTA worker and writes HTML + JSON to `reports/`. It never targets production.
The real `state/` directory is separate and begins empty.

## Views and directory layout

```text
state/<environment>/<scope>/
    desired/
        ip-sets.json
        firewall-rules.json
        ip-reservations.json
    observed/               # optional read-only snapshot, not Git-tracked
        ...same names...
    applied/                # optional last applied baseline, not Git-tracked
        ...same names...
```

Each file is an independent document:

```json
{
  "schemaVersion": 2,
  "resourceKind": "ipSets",
  "items": [
    { "key": "web", "name": "Web Servers", "addresses": ["10.10.1.10", "10.10.1.11"] }
  ]
}
```

- `desired`: managed configuration editable offline and committed in Git.
- `observed`: last read from VCD, complete snapshot of the selected scope. **A snapshot is not live verification.**
- `applied`: managed logical keys from the last successful managed deployment.
- `key`: unique stable logical identity independent of the VCD-assigned ID.
- `resourceKind`: `ipSets`, `edgeFirewallRules`, or `manualIpReservations`.
- Phase 2 represents **Edge Gateway firewall rules only**, not distributed firewall rules.
- It deliberately does not equate manual IP reservations with DHCP or IP Space allocations.

The domain schema is a deliberately narrow *internal model*, not a Cloud Director API response. A later, version-aware adapter will normalise VCD resources and preserve actual IDs and ordering.
Unknown fields fail validation; they are never silently discarded.

### File protection

- Every save validates first and writes UTF-8 without BOM to a temporary sibling file.
- New files use rename; existing files use .NET `File.Replace`.
- Existing documents **cannot be overwritten without an expected SHA-256**.
- An exclusive `.lock` file protects the compare-and-replace operation across writers.
- Each resource file is independently atomic; a *multi-file* set is **not a transaction**.
  Planning fails on incomplete views or inconsistent references. A future Git change
  groups files in a single commit and pipeline jobs plan from an immutable commit.
- Schema v1 files (`resources`) can be migrated to v2 (`items`) **in memory**.
  No migration rewrites a file without an explicit save and expected hash.
- No state writes occur when previewing a plan.

## Three-way planning

`Get-OfflineNetworkPlan` loads all 3 views and calls the pure `New-NetworkChangePlan`:

1. **Applied -> desired:** actionable intent (Create/Update/Move/Delete).
2. **Applied -> observed:** detect missing or externally modified managed objects.
3. **Desired vs observed, excluding applied:** identify collisions with unmanaged keys.

Unmanaged resources observed but absent from `applied` are never planned for deletion.
The plan is **blocked** if observed/applied are absent or drift/collisions exist.
The planner does not silently treat missing files as empty infrastructure.

`Move` is a firewall rule order-only change. Comparison normalises object property
order and set-valued arrays to avoid cosmetic diffs. Plans include explicit
`DependsOn` links when firewall rules refer to newly created IP Sets and use a
stable operation ordering. No network execution engine consumes this ordering yet.

**Important limitation:** A previously captured `observed` snapshot may be stale.
An unblocked Phase 2 plan is **only an offline preview**, not authorisation to deploy.
Phase 3+ must refresh observations and check ownership, remote version fields and
idempotence immediately before any change.

## CLI examples

Generate a deterministic plan from sample data and save to `reports/`:

```powershell
powershell.exe -NoProfile -File .\tools\Invoke-Plan.ps1
```

For a new environment/scope (creates *desired only*):

```powershell
.\tools\Initialize-State.ps1 -Environment test -Scope edge01
.\tools\Invoke-Plan.ps1 -Environment test -Scope edge01
```

The second command generates a *blocked* preview because observed/applied
baselines do not exist. This is expected.

For CI gates add `-FailOnBlocked`; exit code 2 means a blocked plan, 1 means
an unexpected error, and 0 means the preview was generated successfully.
Do **not** use an offline Phase 2 plan as a production deployment gate without
fresh read-only API snapshots in a later phase.

For a custom state root:

```powershell
.\tools\Invoke-Plan.ps1 -StateRoot E:\OfflineNetworkState -Environment production -Scope edge01 -FailOnBlocked
```

An HTML plan escapes user-provided names and descriptions. It shows before/after
objects, but **does not yet calculate field-level highlighted changes**; the JSON
plan is the canonical machine-readable output.

## Tests and acceptance

```powershell
powershell.exe -NoProfile -STA -File .\tools\Invoke-Tests.ps1 -NUnitPath .\test-results\phase2.xml
powershell.exe -NoProfile -STA -File .\tools\Invoke-Tests.ps1 -IncludeUi -NUnitPath .\test-results\phase2-with-ui.xml
```

All VCD API responses are still mocked with `tests/Mocks/FakeVcd.ps1`.
New tests cover migration, validation, atomic saves, CAS conflicts, incomplete
views, path traversal, drift, unmanaged collisions, rule order, deterministic
plans, dependencies, HTML encoding and actual background-runspace report generation.
No coverage percentage is claimed. Windows PowerShell 5.1 execution must be
performed locally before the phase is considered validated.

### Deliberately deferred

- Production-grade VCD transport/session management and live snapshot capture.
- Bidirectional resource ID mapping and optimistic concurrency against VCD.
- Distributed firewall, DHCP reservations and IP Space allocations.
- WinForms grid editors and automatic per-edit plan refresh.
- HTML field-level formatting and multi-file Git transaction support.
- Apply/rollback engine, PR creation and ADO pipeline execution.
