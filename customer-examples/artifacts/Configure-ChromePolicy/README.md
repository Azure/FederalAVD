# Configure-ChromePolicy.ps1

## Overview

This PowerShell script configures Google Chrome browser policies for Azure Virtual Desktop
(AVD) environments using a built-in Registry.pol (PReg format) direct writer - no LGPO.exe
required. It mirrors the pattern used by `Configure-EdgePolicy.ps1` in this repo, adapted for
Chrome's registry root and policy names.

## Purpose

- Configure Google Chrome policies via Local Group Policy
- Enable or disable Developer Tools (F12) for authorized users
- Configure a Safe Browsing allowlist for trusted domains
- Allow popups for specific trusted URLs
- Optionally enforce address-bar search availability and a single default search provider

## Where to get the Chrome Administrative Templates

Google publishes ADMX/ADML templates as a single ZIP (not a CAB like Edge):

- Download page: [Set Chrome browser policies on managed PCs](https://support.google.com/chrome/a/answer/187202)
- Direct download: `https://dl.google.com/dl/edgedl/chrome/policy/policy_templates.zip`
- Full policy reference: [Chrome Enterprise policy list](https://chromeenterprise.google/policies/)

The ZIP contains a `windows/admx/chrome.admx` and `windows/admx/google.admx` (the parent
category Chrome's ADMX depends on) plus per-language `.adml` files under
`windows/admx/<lang>/`. This script looks for the templates in this order:

1. A bundled `*.zip` file next to this script in the artifact folder (staged automatically
   via the `ChromeEnterpriseAdministrativeTemplates` entry in
   [downloads.json](../../parameters/imageManagement/downloads.json) - copy that file to
   `customer/parameters/imageManagement/downloads.json` and run `Update-ImageArtifacts.ps1`
   to pre-stage it in blob storage before an image build).
2. An already-installed `chrome.admx` in `PolicyDefinitions`.
3. A direct download from Google at run time.

If none of the three are available, the script falls back to writing settings directly to
the registry (no ADMX-backed Group Policy, same fallback behavior as `Configure-EdgePolicy.ps1`).
To pin a specific version instead of always pulling latest, download the ZIP yourself and
place it alongside this script in the artifact folder - the script always prefers a bundled
`*.zip` over PolicyDefinitions or downloading.

> **Air-gapped clouds (Azure Government Secret / Top Secret):** `dl.google.com` is not
> reachable from these networks. Download `policy_templates.zip` from
> `https://dl.google.com/dl/edgedl/chrome/policy/policy_templates.zip` on an
> internet-connected system, transfer it to the air-gapped network, and place it in
> `customer/artifacts/Configure-ChromePolicy/` before running
> `Update-ImageArtifacts.ps1 -SkipDownloadingNewSources`. See
> [Air-Gapped Cloud Guide](../../../docs/air-gapped-clouds.md) for the general pre-staging
> pattern. If you skip pre-staging, the script does not fail - it silently takes the
> [Registry-Write Fallback](#4-registry-write-fallback-no-admx-available) instead, which
> applies the same settings without ADMX-backed Group Policy.

## Parameters

### `AllowDeveloperTools`

- **Type:** Bool
- **Default:** `$true`
- **Description:** Enables or disables the Developer Tools (F12) in Chrome
- **Policy Reference:** [DeveloperToolsAvailability](https://chromeenterprise.google/policies/?policy=DeveloperToolsAvailability)

### `SafeBrowsingAllowlistDomains`

- **Type:** String array
- **Default:** `@('portal.azure.com','core.windows.net','portal.azure.us','usgovcloudapi.net')`
- **Description:** Domains exempted from Google Safe Browsing warnings. This is Chrome's
  equivalent to Edge's `SmartScreenAllowListDomains` - Chrome has no SmartScreen integration.
- **Policy Reference:** [SafeBrowsingAllowlistDomains](https://chromeenterprise.google/policies/?policy=SafeBrowsingAllowlistDomains)

### `PopupsAllowedForUrls`

- **Type:** String array
- **Default:** `@('[*.]mil','[*.]gov','[*.]portal.azure.us','[*.]usgovcloudapi.net','[*.]azure.com','[*.]azure.net')`
- **Description:** URL patterns allowed to display popup windows
- **Policy Reference:** [PopupsAllowedForUrls](https://chromeenterprise.google/policies/?policy=PopupsAllowedForUrls)

### `DefaultSearchProviderEnabled`

- **Type:** Nullable bool
- **Default:** `$null` (policy left unconfigured - not written to the registry at all)
- **Description:** Explicitly enables or disables address-bar search. Pass `$true` to force it on (locking out any future override) or `$false` to disable address-bar search entirely. Leave unset to skip this policy - Chrome's normal unmanaged behavior already allows address-bar search.
- **Policy Reference:** [DefaultSearchProviderEnabled](https://chromeenterprise.google/policies/?policy=DefaultSearchProviderEnabled)

### `DefaultSearchProviderName`, `DefaultSearchProviderKeyword`, `DefaultSearchProviderSearchURL`, `DefaultSearchProviderSuggestURL`

- **Type:** String, optional
- **Default:** `''` (not applied)
- **Description:** Enforces a single default search provider. Chrome has no multi-engine
  equivalent to Edge's `ManagedSearchEngines` - only one enforced provider is supported.
  These are only written when `DefaultSearchProviderSearchURL` is non-empty.
- **Policy Reference:** [DefaultSearchProviderSearchURL](https://chromeenterprise.google/policies/?policy=DefaultSearchProviderSearchURL)

## Usage Examples

### Basic Usage (Default Settings)

```powershell
.\Configure-ChromePolicy.ps1
```

### Disable Developer Tools

```powershell
.\Configure-ChromePolicy.ps1 -AllowDeveloperTools $false
```

### Custom Safe Browsing Allowlist

```powershell
.\Configure-ChromePolicy.ps1 -SafeBrowsingAllowlistDomains @('portal.azure.com', 'portal.azure.us', 'contoso.com')
```

### Enforce a Single Default Search Provider

```powershell
.\Configure-ChromePolicy.ps1 `
    -DefaultSearchProviderName 'Bing' `
    -DefaultSearchProviderKeyword 'bing.com' `
    -DefaultSearchProviderSearchURL 'https://www.bing.com/search?q={searchTerms}' `
    -DefaultSearchProviderSuggestURL 'https://www.bing.com/osjson.aspx?query={searchTerms}'
```

### Disable Address Bar Search

```powershell
.\Configure-ChromePolicy.ps1 -DefaultSearchProviderEnabled $false
```

## What the Script Does

### 1. Locates or Downloads Chrome ADMX/ADML Templates

Checks for a bundled `*.zip` next to the script first, then an already-installed
`chrome.admx` in `PolicyDefinitions`, and finally downloads the official templates ZIP from
Google if neither is found.

### 2. Applies Policy Settings

Writes settings directly to `Registry.pol` in MS-GPREG (PReg) binary format - no LGPO.exe or
internet access required at apply time if templates are already present.

### 3. Updates gpt.ini

Updates `gpt.ini` so the Group Policy client on deployed session hosts knows to process the
Registry CSE. `gpupdate` is intentionally not called during image build; the GP client
processes `Registry.pol` automatically at startup/logon on deployed machines.

### 4. Registry-Write Fallback (No ADMX Available)

This is the path taken whenever no ADMX can be located - most commonly in **offline or
air-gapped builds** where `customer/artifacts/Configure-ChromePolicy/` has no pre-staged
`*.zip` and `dl.google.com` is unreachable, but also whenever a bundled ZIP is simply missing
and `chrome.admx` isn't already installed. If no `chrome.admx` can be found or obtained (see
[Where to get the Chrome Administrative
Templates](#where-to-get-the-chrome-administrative-templates)), the script skips
`Registry.pol` entirely and writes every setting with `Set-ItemProperty` directly to
`HKLM:\SOFTWARE\Policies\Google\Chrome`. This path behaves differently from the ADMX path:

- **Takes effect immediately** — no `gpupdate`, logon, or reboot needed. Chrome reads its
  policy values straight from that registry key on every launch, whether they got there via
  the GP client processing `Registry.pol` or via a direct write.
- **Not visible as a "Group Policy"** — `gpedit.msc`, `rsop.msc`, and `gpresult` won't show
  these as configured policies, since `gpt.ini`/`Registry.pol` were never touched. The settings
  are still enforced by Chrome, just not through the GP client.
- **No automatic cleanup** — if you later manage Chrome with a real GPO/Chrome Browser Cloud
  Management policy targeting the same values, the next refresh overwrites these registry
  values (no conflict). But if that management is later removed, these directly-written values
  are **not** cleared automatically the way GP-tattooed values would be, since they were never
  GP-managed to begin with.

## Registry Locations

All Chrome policies live under:

```text
HKLM:\SOFTWARE\Policies\Google\Chrome
```

### Developer Tools

```text
HKLM:\SOFTWARE\Policies\Google\Chrome
  DeveloperToolsAvailability: 1 (Allowed)
```

### Safe Browsing Allowlist

```text
HKLM:\SOFTWARE\Policies\Google\Chrome\SafeBrowsingAllowlistDomains
  1: portal.azure.com
  2: core.windows.net
  ...
```

### Popup Allowlist

```text
HKLM:\SOFTWARE\Policies\Google\Chrome\PopupsAllowedForUrls
  1: [*.]mil
  2: [*.]gov
  ...
```

### Search Provider

```text
HKLM:\SOFTWARE\Policies\Google\Chrome
  DefaultSearchProviderEnabled: only written when the parameter is explicitly set to $true or $false; 1 (Enabled) or 0 (Disabled)
  DefaultSearchProviderSearchURL, DefaultSearchProviderName, DefaultSearchProviderKeyword,
  DefaultSearchProviderSuggestURL: only written when DefaultSearchProviderSearchURL is set
```

## Chrome vs. Edge Policy Differences

Chrome and Edge are both Chromium-based, but they diverge in a few relevant places:

| Concept | Edge | Chrome |
| --- | --- | --- |
| Managed search engine list | `ManagedSearchEngines` (up to 100 engines) | Not available - only a single `DefaultSearchProvider*` provider |
| Trusted-domain warning bypass | `SmartScreenAllowListDomains` | `SafeBrowsingAllowlistDomains` |
| ADMX source | `edgeupdates.microsoft.com` API returns a CAB containing a ZIP | Direct ZIP from `dl.google.com` |
| Registry root | `HKLM:\SOFTWARE\Policies\Microsoft\Edge` | `HKLM:\SOFTWARE\Policies\Google\Chrome` |

## Requirements

- **OS:** Windows 10 or Windows 11
- **Permissions:** Administrator / SYSTEM
- **PowerShell:** 5.1 or higher
- **Google Chrome:** Must be installed for policies to take effect (see the
  `Google-Chrome-Enterprise` example artifact for an install script)
- **Network Access:** Required only if no `chrome.admx` or bundled ZIP is already present

## Offline Usage

Place a copy of `policy_templates.zip` alongside this script in the artifact folder to avoid
any network dependency during image build - the script prefers a bundled ZIP over downloading.
If you don't stage a copy and there's no network access to `dl.google.com` (the normal state
in an air-gapped cloud without pre-staging), the script does not fail - it automatically takes
the [Registry-Write Fallback](#4-registry-write-fallback-no-admx-available) and writes the
same settings straight to the registry instead. See [Where to get the Chrome Administrative
Templates](#where-to-get-the-chrome-administrative-templates) for the air-gapped pre-staging
steps if you want the ADMX-backed path instead of the fallback.
