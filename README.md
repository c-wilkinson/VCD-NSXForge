# VCD-NSXForge

**Experimental PowerShell WinForms tool** for managing NSX firewall rules, IP Sets, and reservations in **VMware Cloud Director (VCD)**.

> ⚠️ **Experimental** – Built from VCD / NSX API documentation. No guarantees it will work out of the box in every environment. Use at your own risk.

## Features

- Manage NSX **firewall rules**, **IP Sets**, and **reservations**
- **Offline JSON state** – work without a live connection and persist configuration
- **Terraform-style change previews** – review planned changes before applying
- Responsive **WinForms UI**
- Rolling logs for visibility into operations
- Unit tests
- Built-in **simulator** for development and testing without a live VCD environment

## Requirements

- Windows (WinForms)
- PowerShell 5.1
- Access to a VMware Cloud Director instance with NSX networking (for live use)

## Getting Started

1. Clone the repository:

   ```powershell
   git clone https://github.com/c-wilkinson/VCD-NSXForge.git
   cd VCD-NSXForge
   ```

2. Review / edit configuration:

   - `config/application.json` – main application settings
   - `config/simulator-settings.example.json` – example simulator settings (copy and rename as needed)

3. Launch the application:

   ```powershell
   .\Start-VcdNetworkManager.ps1
   ```

## Configuration

Application settings live in `config/application.json`.  
Simulator settings can be based on the provided example file.

State is stored as JSON under the `state/` directory, enabling offline work and change previews.

## Development & Testing

- Unit tests are located in the `tests/` directory.
- A simulator is included so you can develop and test without a live VCD / NSX environment.
- Demo state is available under `examples/demo-state/`.

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

This is an experimental tool created based on API documentation. It is provided **as-is** with no warranty. Always test thoroughly in a non-production environment before using against live infrastructure.