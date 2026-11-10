# import-platforms

Create many variants of one CyberArk platform — `UnixSSH-PROD`, `UnixSSH-TEST`, `UnixSSH-DMZ` … —
from a single platform ZIP and a list of differences, with a GUI or from the command line.

For every variant the tool:

1. creates a copy of the source platform under a new platform ID and name (PVWA *side-by-side import*),
2. applies setting changes (for example a different verification interval),
3. sets the PSM server and connection components,
4. activates or deactivates the platform.

## Requirements

| What | Version | Needed for |
|---|---|---|
| Windows PowerShell | 5.1 (or PowerShell 7 on Windows) | everything |
| [psPAS](https://pspas.pspete.dev) | 8.0 or later | `Install-Module psPAS -Scope CurrentUser` |
| PVWA (self-hosted) | 14.6 or later | creating variants, PSM, activate/deactivate |
| PVWA (self-hosted) | 15.2 or later | setting changes |
| Vault user | member of *Vault Admins* | importing platforms |

The tool checks the PVWA version right after logging on and stops **before** creating anything
if the configuration asks for something that PVWA cannot do.

## GUI

Double-click `Start-PlatformImportGui.cmd`, or run:

```powershell
.\Start-PlatformImportGui.ps1
```

**Import tab** — work through the four cards on the left:

1. *PVWA connection*: address, authentication type (CyberArk, LDAP, RADIUS, Windows), user name, password.
   **Test connection** logs on, shows the PVWA version and logs off again.
2. *Source platform*: the platform ZIP. The platform ID is read from the ZIP.
3. *Variants to create*: the JSON configuration. **Open in editor** takes you to the editor tab.
4. *Run*: where reports go, **Dry run** and **Continue after a failure**.

**Validate** checks the ZIP and the configuration without logging on.
**Run import** asks for confirmation, then shows one line per platform plus a live log.
**Cancel** stops before the next platform (the one in progress is finished first).
Every run writes a CSV report and a log file to the report folder.

**Platform editor tab** — build the JSON without writing JSON:

- add, duplicate, reorder and remove variants in the list on the left;
- fill in ID, name, description and what happens after import;
- add setting changes in the grid — the path column offers the common setting paths and accepts any other;
- switch on PSM and list the connection components;
- *Checks* shows every problem as you type (double-click one to jump to it), *JSON preview* shows what will be saved.

Fields the editor does not know (your own `Comment`, `Owner`, …) are kept when a file is opened and saved.

### What is remembered

Everything you enter on the Import tab — PVWA address, authentication type, user name, file
locations, options — plus the window size and the last file open in the editor is saved to

```
%APPDATA%\ImportPlatforms\settings.json
```

as soon as you leave a field. **The password and the one-time code are never saved.**
Delete the file to start from scratch.

## Command line

```powershell
# What would happen? Logs on, changes nothing.
.\Import-PlatformVariants.ps1 -PVWAURL https://pvwa.company.com -Type LDAP `
    -SourcePlatformZip .\UnixSSH.zip -ConfigurationFile .\platforms.json -WhatIf

# Do it, carry on past failures, and remember these settings
.\Import-PlatformVariants.ps1 -PVWAURL https://pvwa.company.com -Type LDAP `
    -SourcePlatformZip .\UnixSSH.zip -ConfigurationFile .\platforms.json -ContinueOnError -SaveSettings

# Next time: uses the saved address, user name and files, asks only for the password
.\Import-PlatformVariants.ps1

# Check the files only (no logon)
.\Import-PlatformVariants.ps1 -SourcePlatformZip .\UnixSSH.zip -ConfigurationFile .\platforms.json -ValidateOnly
```

When you leave out the PVWA address, authentication type, ZIP, configuration file or report
location, the command line uses what the GUI (or `-SaveSettings`) saved, and offers the saved
user name in the credential prompt. Switches such as `-SkipCertificateCheck`, `-ContinueOnError`
and `-WhatIf` are never taken from saved settings: they apply only when you pass them.
The script ends with an error (non-zero exit code) when any platform failed.
`Get-Help .\Import-PlatformVariants.ps1 -Full` lists every parameter.

## Configuration file

See [platforms.example.json](platforms.example.json).

```json
{
  "Platforms": [
    {
      "PlatformId": "UnixSSH-PROD",
      "PlatformName": "Unix via SSH - Production",
      "Description": "Production Linux servers",
      "State": "Active",
      "ApplyChangesIfPlatformExists": false,
      "Settings": [
        { "Operation": "replace", "Path": "Policy/General/interval", "Value": "1440" },
        { "Operation": "remove",  "Path": "Policy/additionalPolicySettings/debug" }
      ],
      "PSM": {
        "PSMServerID": "PSMServer_PROD",
        "Connectors": [ { "PSMConnectorID": "PSM-SSH", "Enabled": true } ]
      }
    }
  ]
}
```

| Field | Required | Meaning |
|---|---|---|
| `PlatformId` | yes | ID of the new platform. Unique, no spaces, not the source platform's ID. |
| `PlatformName` | yes | Display name in PVWA. |
| `Description` | no | Description of the new platform. |
| `State` | no | `Active`, `Inactive` or `Unchanged` (default: leave it as PVWA creates it). |
| `ApplyChangesIfPlatformExists` | no | `false` (default): an existing platform is skipped untouched. `true`: settings, PSM and state are applied to it. |
| `Settings` | no | Changes sent to PVWA's *Update target platform settings* API. `Operation` is `replace` (default) or `remove`; `Value` is required for `replace`. |
| `PSM.PSMServerID` | no | PSM server for the platform. Omit to keep the current one. |
| `PSM.Connectors` | no | Connection components to set. Omit to keep the ones the platform has. `Enabled` defaults to `true`. |

Setting paths are passed to PVWA as written. The editor's suggestions are the paths psPAS knows;
which ones a platform accepts depends on the PVWA version and the platform. On PVWA 15.2+
`Get-PASPlatform -ID <numeric id>` shows the settings a platform really has.

Older files with `"Enable": true` still work (it means `"State": "Active"`).

## How the side-by-side import works

PVWA only offers a side-by-side import for a package it is *holding in memory*, and it only holds
a package after an upload that collided with an existing platform (for up to five minutes).
So for each new variant the tool:

1. makes sure the source platform exists — if not, the ZIP is imported normally first;
2. uploads the ZIP again when PVWA is not holding it, which collides with the source platform on purpose;
3. imports the held package under the variant's ID and name;
4. waits until PVWA returns the new platform, then applies settings, PSM and state.

The package left in PVWA's memory is removed at the end of the run.

## Tests

```powershell
powershell -NoProfile -File .\tests\Invoke-Tests.ps1                 # engine + command line
powershell -NoProfile -STA -File .\tests\Invoke-Tests.ps1 -IncludeGui # also drives the window (off screen)
```

No Pester and no Vault are needed: `tests\MockPsPAS` is a stand-in for psPAS with a fake Vault in
memory. It is only ever loaded by the test script.

## Files

| File | Purpose |
|---|---|
| `Start-PlatformImportGui.cmd` / `.ps1` | The GUI |
| `Import-PlatformVariants.ps1` | The command line |
| `lib\PlatformVariants.psm1` | The engine both of them use |
| `lib\MainWindow.xaml` | Window layout |
| `platforms.example.json` | Sample configuration |
| `tests\` | Automated tests and the psPAS stand-in |
