# VCD-NSXForge

**Experimental PowerShell 5.1 + WinForms tool** for managing NSX firewall rules, IP Sets, and manual IP reservations in **VMware Cloud Director (VCD)**.

Designed for **tightly locked-down Windows environments** where external modules, PowerShell 7, and compiled helpers are not permitted.

> ⚠️ **Experimental**  
> Built from VCD / NSX API documentation. No guarantees it will work out of the box in every environment.  
> **Use at your own risk.** Always test thoroughly in a non-production environment.

## Why this exists

Many enterprise VCD environments restrict what can be installed or executed. This project deliberately stays inside those boundaries:

- **Windows PowerShell 5.1 only** (Desktop edition)
- **No external modules**
- Native **WinForms** UI
- Pure `.ps1` / `.psm1` source that can be copied as files

The goal is a practical, auditable tool for network and security engineers who need better visibility and safer change workflows than the VCD UI alone provides.

## Requirements

- Windows
- **Windows PowerShell 5.1** (powershell.exe) — *not* PowerShell 7 (pwsh)
- STA apartment state (required by WinForms)
- Access to a VMware Cloud Director instance with NSX networking (for live read operations)

## Getting Started

1. Clone the repository:

   ```powershell
   git clone https://github.com/c-wilkinson/VCD-NSXForge.git
   cd VCD-NSXForge
   ```

2. Review configuration:

   - `config/application.json` – main application settings
   - `config/simulator-settings.example.json` – example simulator settings (copy and adapt as needed)

3. Launch with Windows PowerShell 5.1 in STA mode:

   ```powershell
   powershell.exe -NoProfile -STA -File .\Start-VcdNetworkManager.ps1
   ```

   The launcher will refuse to start under PowerShell 7 or without STA.

## Configuration & State

- Application settings live in `config/application.json`.
- State is stored as versioned JSON under the `state/` directory.
- Demo state is available under `examples/demo-state/`.
- The built-in simulator allows full offline development and testing.

## Architecture (high level)

```
src/
├── Domain/          # Pure state model, validation, planning (no I/O)
├── Application/     # Use cases / orchestration
├── Infrastructure/  # VCD API client, simulator, logging, state persistence
├── Presentation/    # WinForms UI
└── Runtime/         # Runspace-based worker dispatcher
```

The domain layer is deliberately free of filesystem, network, and UI dependencies so it can be tested in isolation.

## Roadmap

Work is organised into five milestones (see GitHub Issues & Milestones for full detail):

| Milestone | Focus |
|-----------|--------|
| **M1** – Foundation & Live Discovery | Restricted-runtime validation (CLM/AppLocker/WDAC), secure auth & token handling, typed errors, resource ownership, schema versioning, live discovery |
| **M2** – Read-Only Operations & Change Intelligence | Draft workspace, production-safe dry-run, security guardrails, multi-environment isolation, package import/export, operator UX |
| **M3** – Traffic Diagnostics & Topology | Log correlation, connectivity explanation, NAT/DFW modelling, application dependencies, scheduled drift checks |
| **M4** – Controlled Production Changes | Gated apply engine, state locking, explicit approval + tamper-evident audit, pre-change backup & recovery |
| **M5** – Enterprise Release & Operations | Signed packaging, operational runbooks, scalability & resilience benchmarks |

Safety and auditability are prioritised over feature velocity. Live writes remain disabled until the M4 controls are in place.

## Development & Testing

- Unit and contract tests live under `tests/`.
- Run the native test harness via `tools/Invoke-Tests.ps1` (PowerShell 5.1).
- CI runs on Windows with PowerShell 5.1 and publishes NUnit 3 results.
- A simulator is included so most development can happen without a live VCD instance.

## License

This project is released into the **public domain** under the [Unlicense](https://unlicense.org).

```
This is free and unencumbered software released into the public domain.

Anyone is free to copy, modify, publish, use, compile, sell, or
distribute this software, either in source code form or as a compiled
binary, for any purpose, commercial or non-commercial, and by any means.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND...
```

See the full `LICENSE` file for details.

## Disclaimer

This is an experimental tool created from public API documentation. It is provided **as-is** with no warranty of any kind.

- It may contain defects.
- It may not match every VCD / NSX deployment.
- It must not be used against production infrastructure until you have thoroughly validated it in a non-production environment and accept full responsibility for the outcome.
