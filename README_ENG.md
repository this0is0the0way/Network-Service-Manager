# Network Service Manager v2.5.3

## Project and interface names

The public project and repository name is **Network Service Manager**.

The console interface deliberately retains the name **BESKAR**. Therefore,
`NetworkManager.ps1`, the console title, built-in help, and internal file names
such as `BESKAR_YYYY-MM.log` may still display `BESKAR`. This is part of the
interface and does not change the GitHub project name.

---

## Purpose

Network Service Manager is an engineering utility for quickly switching network
settings on Windows PCs during commissioning, service work, and field operations.

It supports:

- VLAN and static IPv4 profiles;
- static IPv4 profiles without VLAN;
- multiple temporary IPv4 addresses on one adapter;
- temporary routes;
- Mixed profiles;
- restoring DHCP and DNS settings;
- restoring the original network state;
- automatic adaptation to different USB Ethernet drivers;
- console themes;
- adding and editing IP profiles through the interface;
- manual connectivity checks with `ping`;
- automatic `PingTarget` checks;
- controlling `DeviceName` display;
- operation logging.

---

## Requirements

- Windows 10 or Windows 11;
- Windows PowerShell 5.1 or newer;
- administrator privileges to change network settings.

---

## Running the program

The recommended option is a PowerShell shortcut configured to run as an
administrator. You may also run `Start.bat`.

### Creating a shortcut

On the desktop, choose **New → Shortcut**. In the location field, enter:

```text
C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "D:\PATH\TO\Network-Service-Manager\NetworkManager.ps1"
```

Set the shortcut's working directory to the Network Service Manager folder.
Then enable **Run as administrator** in **Properties → Advanced**.

Administrator privileges are required to change VLAN, IPv4, DHCP, routes, and
advanced network adapter properties.

---

## Main menu

The top of the menu displays the state of the selected adapter:

```text
Adapter : Ethernet
Status  : Up
VLAN    : 217
IPv4    : 192.168.218.208/26
DHCP    : Disabled
Gateway : 192.168.218.193
Speed   : 1 Gbps
VLAN drv: VLAN_ID
```

Profiles are displayed with aligned names:

```text
 1. TP               [VLAN 217; 192.168.218.208]
 2. RP               [VLAN 212; 192.168.221.105]
 3. MFMT             [no VLAN; 192.168.0.204]
 4. Object 1         [no VLAN; 11 IP addresses; 2 route(s)]
```

`MFMT` means a multifunction measuring instrument. Profile names,
object names, IP addresses, and VLAN IDs in this document are examples.

---

## Commands

Enter either a profile number or a command in the main menu.

### `ping`

Run a manual reachability check:

```text
ping
```

The program asks for an IP address or host name. You can also provide it
immediately:

```text
ping 192.168.218.2
```

The manual ping settings are:

```powershell
$PingCount = 2
$PingTimeout = 500
```

Network Service Manager uses standard Windows `ping.exe`.

### `pingtarget`

Controls the automatic check of the profile's `PingTarget` after a profile is
applied:

```text
pingtarget
```

`PingTarget` belongs to an individual network profile. The command is listed in
`help`, but not in the main menu's quick command line because it is not used
continuously.

### Automatic PingTarget check

After a profile is applied, the program waits for the network to recover and
then tries the target address. It stops as soon as the first successful reply is
received.

```text
Apply profile
      ↓
Wait for network recovery
      ↓
Attempt 1 of 5
      ↓
Reply received → check complete
      ↓
No reply → next attempt
```

The related settings are:

```powershell
$PingDelayAfterApply = 5000
$PingRetryCount = 5
$PingRetryDelay = 1000
```

`ping.exe` is used for compatibility with Windows PowerShell 5.1, where
`Test-Connection` may not support `-TimeoutSeconds`.

A failed PingTarget check does not necessarily mean the profile was applied
incorrectly. The target device may be powered off or unreachable for another
reason.

### `devicename`

Controls the display of the optional `DeviceName` field while a profile is
applied:

```text
devicename
```

The command changes display only. `DeviceName` itself is edited through `edit`.
Like `pingtarget`, it is available through `help` but is not shown in the main
menu quick command line.

### `edit`

Edit a profile in the current object:

```text
edit
```

Or open a profile directly:

```text
edit 3
```

For `Mode=Network` profiles, you can change the name, category, VLAN, IP,
subnet mask, gateway, `DeviceName`, and `PingTarget`. The program shows a
before-and-after summary before saving.

### Other commands

- `add ip` — create a standard Network profile;
- `theme` — change console appearance;
- `objects` — return to object selection;
- `adapter` — select another network adapter;
- `dhcp` — remove VLAN and static settings, then enable DHCP;
- `state` — refresh the displayed state;
- `reboot` — restart the application completely;
- `help` — show built-in help;
- `exit` or `quit` — exit the application.

### Service numbers

- `90` — refresh the adapter state;
- `91` — select another adapter;
- `97` — restore the original network state;
- `99` — set VLAN to absent and restore DHCP;
- `0` — return to object selection from the profile menu.

---

## Objects and profiles

Since version 2.4.0, profiles are grouped by object:

```text
Network-Service-Manager
│
├── NetworkManager.ps1
├── Theme.json
├── AdapterProfiles.json
│
└── Profiles
    ├── Object 1.json
    ├── Object 2.json
    └── Object 3.json
```

Every JSON file in `Profiles` is an object. Its file name without `.json` is
shown in the object menu. Use `0` within an object to return to object selection.

You can create an object in the object menu or while using `add ip`. When an
object is changed, a backup is created:

```text
Profiles\<Object>.json.bak
```

---

## Adding an IP profile

Enter:

```text
add ip
```

The wizard asks for:

1. profile name;
2. category;
3. VLAN;
4. IP address;
5. subnet mask;
6. gateway;
7. optional fields.

Pressing Enter for VLAN means no VLAN. `"VLAN": null` and an omitted `VLAN`
field mean the same thing: any previously configured VLAN must be removed.

At any step, enter `exit` or `cancel` to leave the wizard without saving.

Optional fields example:

```json
"DeviceName": "MFMT + SCADA",
"PingTarget": "192.168.218.2"
```

`Category` groups profiles within an object. It does not affect network
configuration. Press Enter to use the default category, `Network profiles`.

---

## Profile modes

### Network: VLAN and one IPv4 address

```json
{
  "Name": "RP",
  "Category": "Network profiles",
  "Mode": "Network",
  "VLAN": 212,
  "IP": "192.168.120.250",
  "Mask": "255.255.255.0",
  "Gateway": ""
}
```

### Network: IPv4 without VLAN

```json
{
  "Name": "Controller default address",
  "Mode": "Network",
  "VLAN": null,
  "IP": "192.168.0.250",
  "Mask": "255.255.255.0",
  "Gateway": ""
}
```

### MultiAddress

```json
{
  "Name": "Multiple subnets",
  "Mode": "MultiAddress",
  "VLAN": null,
  "Addresses": [
    {"IP": "192.168.26.115", "Mask": "255.255.255.0"},
    {"IP": "192.168.27.115", "Mask": "255.255.255.0"}
  ]
}
```

The first address replaces the current address for the active Windows session;
the remaining addresses are added temporarily. Avoid several default gateways
unless they are required.

### Routes

```json
{
  "Name": "Object routes",
  "Mode": "Routes",
  "Routes": [
    {
      "Destination": "192.168.27.0",
      "Mask": "255.255.255.0",
      "Gateway": "192.168.27.1"
    }
  ],
  "Persistent": false
}
```

Set `"Persistent": true` only when routes must survive a restart. Existing
profile routes are not automatically removed when you switch profiles.

### Mixed

```json
{
  "Name": "Object 1",
  "Category": "Special profiles",
  "Mode": "Mixed",
  "VLAN": null,
  "Addresses": [],
  "Routes": [],
  "Persistent": false
}
```

Mixed applies the MultiAddress part first and then the Routes part.

The interactive `edit` command currently supports only `Mode=Network`.
Edit `MultiAddress`, `Routes`, and `Mixed` profiles directly in their JSON file.

---

## VLAN detection and configuration

The list of physical adapters and properties of the selected driver are refreshed
every time the application returns to the main menu and before a profile is
applied, DHCP is restored, or a snapshot is restored. There is no background
scan while the console waits for input.

If the selected adapter is disconnected, renamed, or replaced, select it again.
Replacement is detected by `InterfaceGuid`, not only by adapter name.

`AdapterProfiles.json` stores detection results. Its saved values never replace
the current driver read, including an earlier `SupportsVlan: true` or
`DisableMethod: Unknown` value.

The program searches for numeric VLAN ID properties, including:

```text
VLAN_ID
RegVlanID
VlanID
VLANID
*VlanID
```

For example, one adapter can expose `VLAN_ID` while another exposes `RegVlanID`.
Both are handled automatically when their driver properties confirm support.

`Packet Priority & VLAN` / `*PriorityVLANTag` enables tagged-frame handling. It
is not a VLAN number. A hidden property such as `IntelANSVlanID`, without a
displayed VLAN ID field, does not by itself prove that direct VLAN configuration
is available.

`SupportsVlan: false` means this direct configuration method is not confirmed;
it is not an assessment of the hardware controller's general VLAN capabilities.
An empty VLAN value needs no reset. If a non-empty value cannot be disabled by a
method confirmed by the driver, the operation stops. A driver read error also
stops the operation instead of being treated as proof that VLAN is absent.

### Switching from VLAN to no VLAN

When switching from a VLAN profile to a non-VLAN profile, the application first
removes VLAN and verifies the result. Only after successful verification are the
new IPv4 settings applied. If VLAN cannot be removed, the IP part of the profile
is not applied.

Intel PROSet/ANS VLAN is not supported by Intel on Windows 11. See Intel's
[support statement](https://www.intel.com/content/www/us/en/support/articles/000087483/ethernet-products.html).

---

## APIPA addresses

Windows may automatically assign an APIPA address such as:

```text
169.254.x.x/16
```

Network Service Manager does not remove it or change the Windows network stack.
It only hides APIPA addresses in the BESKAR IPv4 status line.

---

## DHCP and original state

The `dhcp` command and service number `99` remove VLAN and static IPv4 settings,
restore DHCP and DNS, restart the adapter, and request a DHCP lease. The request
has a configured timeout, but the lease can continue to be obtained in the
background.

At the first selection of an adapter, the program creates
`OriginalNetworkState.json` if it does not already exist. Service number `97`
uses this snapshot to restore the selected adapter's saved VLAN, IPv4, DHCP, and
DNS state.

The snapshot is machine-specific and is not part of the clean distribution. It
does not save default gateways or user-created routes. The application does not
automatically roll back partly completed operations after an error.

---

## Themes, console size, and startup animation

Use:

```text
theme
```

to change console colors without editing the script. The selected values are
stored in `Theme.json`. If the file does not exist, the built-in theme is used.

The console size is configured near the start of `NetworkManager.ps1`:

```powershell
$ConsoleWindowWidth  = 140
$ConsoleWindowHeight = 50
$ConsoleBufferHeight = 3000
```

The values are measured in characters and rows. Some console hosts may ignore
these settings.

Startup animation is controlled by:

```powershell
$EnableStartupAnimation = $true
```

Set it to `$false` to disable the animation.

---

## Files created during operation

- `Profiles\` — object JSON files and their backups;
- `AdapterProfiles.json` — adapter capability cache;
- `OriginalNetworkState.json` — original state snapshot for one computer;
- `Theme.json` — user theme;
- `Logs\BESKAR_YYYY-MM.log` — operation log;
- `StartupError.log` — created after a critical startup error.

The following legacy files are not used by the current version:

```text
NetworkProfiles.legacy.json
NetworkProfiles_резерв.json
```

---

## Recommendations

- Keep a copy of the previous version before trying a new release.
- Test an unfamiliar VLAN driver with one profile first.
- If adapter detection behaves unexpectedly, delete `AdapterProfiles.json` or
  replace its contents with `[]` to force a clean analysis.
- Do not close the application while it is changing VLAN settings.
- Check adapter state and PingTarget after applying a VLAN profile.
- A profile is still applied when PingTarget checking is disabled.

---

## Clean distribution v2.5.3

The clean distribution contains only program files, documentation, and licensing
information. User profiles and machine-specific files are intentionally excluded.

```text
Network-Service-Manager_v2.5.3
├── NetworkManager.ps1
├── Start.bat
├── README.md
├── README_RU.md
├── README_ENG.md
├── CHANGELOG.txt
├── LICENSE
└── RELEASE_MANIFEST.txt
```

For future development, treat the current `NetworkManager.ps1` as the single
source of truth. Do not use older BESKAR versions or old patch files as a source
code base.

---

## License

This project is distributed under the **MIT License**.

```text
Copyright (c) 2026 Zimin D.A., tg:@bes_car
```

See `LICENSE` for the full license text.
