# Phase 1 verification and mock contracts

The application targets **Windows PowerShell 5.1** and **VCD 10.6 / NSX-T**.
It requires no Pester, PowerCLI, NuGet package, or other external PowerShell module.

## Running the tests

```powershell
# Run headless unit, mock-contract and real runspace/logger integration tests.
powershell.exe -NoProfile -STA -File .\tools\Invoke-Tests.ps1 -NUnitPath .\test-results\phase1.xml

# On an interactive Windows session, additionally exercise real WinForms controls.
powershell.exe -NoProfile -STA -File .\tools\Invoke-Tests.ps1 -IncludeUi -NUnitPath .\test-results\phase1-with-ui.xml
```

The harness exits with code **1** if any test fails and **0** otherwise; NUnit 3 XML
includes separate passed/failed/skipped counts. When `-IncludeUi` is not provided, the
WinForms smoke test is explicitly marked **skipped**, not passed.

## External interface / mock policy

- **Phase 1 contains no live VMware HTTP sender.** `VcdApi.psm1` requires an injected
  `RequestSender` scriptblock. Without it, even construction fails. There is no
  default transport that could accidentally contact a real VCD host.
- `tests/Mocks/FakeVcd.ps1` rejects unknown requests and all mutations. It only
  handles the currently implemented read-only contract: `GET /api/versions`,
  `GET /cloudapi/2.0.0/edgeGateways/{id}/firewall/rules`,
  `GET /cloudapi/1.0.0/firewallGroups/summaries`, and
  `GET /cloudapi/1.0.0/manualIpReservations`.
- Fixture JSON lives under `tests/Fixtures/`. Tests assert VCD 39.0 headers,
  GET-only behaviour, correct gateway/network filters, pagination, response
  handling, invalid input, and injected network failures.
- No API operations not actually implemented in Phase 1 are claimed as tested.
  Create/update/delete, authentication, token refresh, asynchronous task
  monitoring, drift, and deployment will need their own mocks and tests as those
  operations are introduced. The fake's default rejection enforces this.

## Test map

| Source area | Tests |
| --- | --- |
| Configuration | Valid defaults, unsupported VCD/NSX/PowerShell versions, paths, bounds, missing file |
| Worker dispatcher & operation script | Real MTA workers, parallel jobs, progress, cancellation, errors, lifecycle |
| Logging writer & file rotation | Real writer, concurrent producers, severity filter, 5 MB, UTC rollover, 30-day retention, overlong records |
| WinForms controller state | Idle/running/cancelling/terminal states, stale events, bounded progress |
| WinForms controls | Interactive STA smoke test: start, progress, success, failure, cancellation |
| VCD API request abstraction | Mock-only GET calls, versions XML, firewall read, paged IP Set and IP reservation reads |
| Bootstrap/startup script | PowerShell parser check; **not yet a separate process-level smoke test** |
| Test harness | Assertion failures, valid NUnit 3 output, test exit status via runner |
| Repository architecture | Parser check for all source PowerShell files, no HTTP in UI/runtime, test-module inventory |

### Meaning of coverage

The source/module inventory is a **test-presence audit**, not a PowerShell
statement-coverage metric. Tests cover the listed behaviours, including failure
branches; this release does **not** claim 100% line or branch coverage.

A full dynamic coverage figure would require instrumentation of the real Windows
PowerShell 5.1 runspaces and the UI execution path, which is not available in the
build environment used to package this archive. Likewise, the Windows-only tests
are provided but have **not been executed here**.

## Acceptance gate before Phase 2

1. All headless tests pass under the actual **Windows PowerShell 5.1** runtime.
2. WinForms smoke test passes in an interactive Windows desktop (`-IncludeUi`).
3. No test causes a network request to a real VCD instance.
4. Generated NUnit 3 report has `failed="0"` and (with `-IncludeUi`) `skipped="0"`.
5. A reviewer inspects any module without branch-level tests before it gains VCD write functionality.

## VCD 10.6 API assumptions

VCD 10.6 uses API version **39.0** as the supported default. The future live
transport will first negotiate against `/api/versions` instead of assuming that
value. CloudAPI 2.0.0 is used for Edge Gateway firewall rules; this differs from
DC Group distributed firewall policy endpoints and Provider Gateway rules.

References:
- https://knowledge.broadcom.com/external/article/429376/
- https://knowledge.broadcom.com/external/article/401636/
- https://developer.broadcom.com/xapis/vmware-cloud-director-openapi/latest/cloudapi/1.0.0/manualIpReservations/get/
- https://developer.broadcom.com/xapis/vmware-cloud-director-openapi/latest/cloudapi/1.0.0/firewallGroups/summaries/get/

## NUnit 3 acceptance checks

The reporter test verifies the `test-run` root element via `LocalName`
(not `Name`, which PowerShell XML adapters may resolve to the `name` XML
attribute), assembly suite, NUnit
`test-case` elements, results counts, and pass/fail/skip records. Another test
checks that failure text containing XML-special characters round-trips safely,
and that failure stack traces and skip reasons survive serialization.

Use `-NUnitPath` for new pipeline commands. `-JunitPath` is a deprecated
compatibility alias and also writes **NUnit 3** XML. The former JUnit test
assertion (`testsuite` root) must not be used with this reporter.

See `docs/CI.md` for sample Azure DevOps / GitHub Actions integration.


### UI startup regression (Windows only)

The `-IncludeUi` test starts a real WinForms form, clicks Run, waits for a real
background operation to complete, and then exercises failure and cancellation.
The test now includes the event textbox contents in any assertion failure.
The UI must capture `CommandInfo` for module functions before using `GetNewClosure`;
functions imported into the MainForm module are otherwise not reliably visible
inside dynamic event-handler modules.

The source-architecture suite also checks function verbs using `Get-Verb`.
No module warnings should be suppressed to hide unapproved verbs.

## Phase 2 additions

- `StateModel.Tests.ps1`: schemas, v1 migration, IP/CIDR and firewall validation,
  canonical comparison semantics.
- `StateRepository.Tests.ps1`: safe paths, view completeness, atomic per-file
  writes and SHA-256 compare-and-swap, no implicit observed/applied creation.
- `Planning.Tests.ps1`: deterministic 3-way changes, drift, unmanaged key
  collisions, references, dependencies, rule moves and escaped HTML.
- `OfflineWorker.Tests.ps1`: real asynchronous worker produces HTML/JSON from
  an offline synthetic state; VCD HTTP remains unimplemented.
- Windows UI smoke now also presses **Generate offline plan** and checks that
  the report path reaches the event log without freezing the form.

The same NUnit 3 runner is used. No percentage of statement or branch coverage
is claimed until the project runs on Windows with instrumentation.
