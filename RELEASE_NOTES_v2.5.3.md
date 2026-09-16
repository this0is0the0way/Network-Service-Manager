# Network Service Manager v2.5.3

This documentation release removes project-specific names and network examples
from the public documentation and expands the English README into a complete
reference equivalent to the Russian document.

## Changes

- Anonymised object names, profile names, device names, VLAN IDs, and network
  examples in `README_RU.md` and `README_ENG.md`.
- Reworked `README_ENG.md` with complete menu, command, profile JSON, VLAN,
  DHCP, original-state, APIPA, theme, console, and operation guidance.
- Updated all public version labels to v2.5.3.

## Installation

Download **Network_Service_Manager_v2.5.3.zip**, extract it to a separate folder,
and run `Start.bat`. Administrator privileges are required to change network
settings.

The ZIP includes only application files, documentation, changelog, and license.
Profiles, logs, adapter cache, network snapshots, user theme, and development
tests are excluded.

## Validation

- Complete JSON examples in both README files were validated with Windows
  PowerShell `ConvertFrom-Json`.
- The clean archive was checked to contain only the intended distribution files.

No network-management logic changed in this release.
