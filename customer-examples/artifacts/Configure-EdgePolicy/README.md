# Configure-EdgePolicy.ps1

## Overview

This PowerShell script configures Microsoft Edge browser policies for Azure Virtual Desktop (AVD) environments using a built-in Registry.pol (PReg format) direct writer — no LGPO.exe required. It applies enterprise-grade security and usability settings tailored for government and highly regulated environments.

## Purpose

- Configure Microsoft Edge policies via Local Group Policy
- Enable developer tools for authorized users
- Configure SmartScreen allowlist for trusted domains
- Allow popups for specific trusted URLs
- Optimize Edge for AVD environments

## Where to get the Edge Administrative Templates

Microsoft publishes ADMX/ADML templates as a CAB file discovered through an API, not a static
URL:

- API endpoint: `https://edgeupdates.microsoft.com/api/products?view=enterprise` (the script
  queries this for the latest `Policy` release and downloads the returned CAB)
- Manual download page: [Configure Microsoft Edge policy settings](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies)
- Full policy reference: [Microsoft Edge Browser Policy Documentation](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies)

The API endpoint returns metadata rather than the CAB itself. On an internet-connected
Windows system, open PowerShell in the folder containing this README and
`Configure-EdgePolicy.ps1`, then run:

```powershell
$apiUrl = 'https://edgeupdates.microsoft.com/api/products?view=enterprise'
$products = Invoke-RestMethod -Uri $apiUrl
$stableVersion = ($products | Where-Object Product -eq 'Stable').releases |
  Where-Object { $_.Platform -eq 'Windows' -and $_.Architecture -eq 'x64' } |
  Sort-Object { [version]$_.ProductVersion } |
  Select-Object -Last 1 -ExpandProperty ProductVersion
$policyRelease = ($products | Where-Object Product -eq 'Policy').releases |
  Where-Object ProductVersion -eq $stableVersion |
  Select-Object -First 1
if (-not $policyRelease) {
  $policyRelease = ($products | Where-Object Product -eq 'Policy').releases |
    Sort-Object { [version]$_.ProductVersion } |
    Select-Object -Last 1
}
$downloadUrl = $policyRelease.artifacts[0].Location
Invoke-WebRequest -Uri $downloadUrl -OutFile '.\MicrosoftEdgePolicyTemplates.cab'
```

The `-OutFile` value writes `MicrosoftEdgePolicyTemplates.cab` into the current folder. Keep
that filename and location: the policy script searches its own folder for a `*.cab` file, and
the example `downloads.json` uses the same destination filename.

This script looks for the templates in this order:

1. A bundled `*.cab` file next to this script in the artifact folder (staged automatically via
   the `EdgeEnterpriseAdministrativeTemplates` entry in
   [downloads.json](../../parameters/imageManagement/downloads.json) - copy that file to
   `customer/parameters/imageManagement/downloads.json` and run `Update-ImageArtifacts.ps1` to
   pre-stage it in blob storage before an image build).
2. An already-installed `msedge.admx` in `PolicyDefinitions`.
3. A live query to `edgeupdates.microsoft.com` at run time.

If none of the three are available, the script falls back to writing settings directly to the
registry (no ADMX-backed Group Policy).

> **Air-gapped clouds (Azure Government Secret / Top Secret):** `edgeupdates.microsoft.com` is
> not reachable from these networks. Use the PowerShell example above to download the CAB on
> an internet-connected system, transfer `MicrosoftEdgePolicyTemplates.cab` to the air-gapped
> network, and place it in `customer/artifacts/Configure-EdgePolicy/` before running
> `Update-ImageArtifacts.ps1 -SkipDownloadingNewSources`. See
> [Air-Gapped Cloud Guide](../../../docs/air-gapped-clouds.md) for the general pre-staging
> pattern. If you skip pre-staging, the script does not fail - it silently takes the
> [Registry-Write Fallback](#3-registry-write-fallback-no-admx-available) instead, which
> applies the same settings without ADMX-backed Group Policy.

## Parameters

### `AllowDeveloperTools`

- **Type:** Bool
- **Default:** `$true`
- **Description:** Enables or disables the Developer Tools (F12) in Microsoft Edge

### `SmartScreenAllowListDomains`

- **Type:** String (JSON array)
- **Default:** `'["portal.azure.com", "core.windows.net", "portal.azure.us", "usgovcloudapi.net"]'`
- **Description:** Domains exempted from Microsoft Defender SmartScreen warnings
- **Policy Reference:** [SmartScreenAllowListDomains](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies#smartscreenallowlistdomains)

### `PopupsAllowedForUrls`

- **Type:** String (JSON array)
- **Default:** `'["[*.]mil","[*.]gov","[*.]portal.azure.us","[*.]usgovcloudapi.net","[*.]azure.com","[*.]azure.net"]'`
- **Description:** URL patterns allowed to display popup windows
- **Policy Reference:** [PopupsAllowedForUrls](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies#popupsallowedforurls)

### `DefaultSearchProviderEnabled`

- **Type:** Nullable bool
- **Default:** `$null` (policy left unconfigured - not written to the registry at all)
- **Description:** Explicitly enables or disables address-bar search. Pass `$true` to force it on (locking out any future override) or `$false` to disable address-bar search entirely. Leave unset to skip this policy - Edge's normal unmanaged behavior already allows address-bar search.
- **Policy Reference:** [DefaultSearchProviderEnabled](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/defaultsearchproviderenabled)

### `ManagedSearchEngines`

- **Type:** String (JSON array), optional
- **Default:** `''` (not applied)
- **Description:** A JSON array of up to 100 search engine objects, one marked `"is_default": true`. When set as a mandatory policy, users cannot add, remove, or edit entries but can pick which listed engine is the default. Each engine can also carry its own `keyword` - typing that keyword followed by a space in the address bar searches with that engine directly, without changing the default.
- **Policy Reference:** [ManagedSearchEngines](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/managedsearchengines)
- **Important:** This is the more capable of the two search-provider options (up to 100 engines, per-engine keywords). Use the simpler `DefaultSearchProviderName`/`DefaultSearchProviderSearchURL`/etc. parameters below instead if you only need to enforce a single provider. If `DefaultSearchProviderSearchURL` is set, this script applies the legacy fields and skips `ManagedSearchEngines` entirely - Edge ignores `ManagedSearchEngines` whenever the legacy policy is also present.

### `DefaultSearchProviderName`, `DefaultSearchProviderKeyword`, `DefaultSearchProviderSearchURL`, `DefaultSearchProviderSuggestURL`

- **Type:** String, optional
- **Default:** `''` (not applied)
- **Description:** Simpler alternative to `ManagedSearchEngines` - enforces a single default search provider. Only written when `DefaultSearchProviderSearchURL` is non-empty. Do not set both this group and `ManagedSearchEngines` - see the note above.
- **Policy Reference:** [DefaultSearchProviderSearchURL](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/defaultsearchprovidersearchurl), [DefaultSearchProviderName](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/defaultsearchprovidername), [DefaultSearchProviderKeyword](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/defaultsearchproviderkeyword), [DefaultSearchProviderSuggestURL](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/defaultsearchprovidersuggesturl)

## Usage Examples

### Basic Usage (Default Settings)

```powershell
.\Configure-EdgePolicy.ps1
```

### Disable Developer Tools

```powershell
.\Configure-EdgePolicy.ps1 -AllowDeveloperTools $false
```

### Custom SmartScreen Allowlist

```powershell
$domains = '["portal.azure.com", "portal.azure.us", "contoso.com"]'
.\Configure-EdgePolicy.ps1 -SmartScreenAllowListDomains $domains
```

### Custom Popup Allowlist

```powershell
$popups = '["[*.]mil", "[*.]gov", "[*.]contoso.com"]'
.\Configure-EdgePolicy.ps1 -PopupsAllowedForUrls $popups
```

### Complete Custom Configuration

```powershell
.\Configure-EdgePolicy.ps1 `
    -AllowDeveloperTools $false `
    -SmartScreenAllowListDomains '["portal.azure.us", "contoso.gov"]' `
    -PopupsAllowedForUrls '["[*.]mil", "[*.]gov"]'
```

### Enforce a Single Managed Search Engine

```powershell
$searchEngines = '[{"is_default": true, "keyword": "bing.com", "name": "Bing", "search_url": "https://www.bing.com/search?q={searchTerms}", "suggest_url": "https://www.bing.com/osjson.aspx?query={searchTerms}"}]'

.\Configure-EdgePolicy.ps1 -ManagedSearchEngines $searchEngines
```

### Enforce a Single Default Search Provider (Legacy, Simpler Alternative)

Use this instead of `ManagedSearchEngines` when you only need to enforce one provider:

```powershell
.\Configure-EdgePolicy.ps1 `
    -DefaultSearchProviderName 'Bing' `
    -DefaultSearchProviderKeyword 'bing.com' `
    -DefaultSearchProviderSearchURL 'https://www.bing.com/search?q={searchTerms}' `
    -DefaultSearchProviderSuggestURL 'https://www.bing.com/osjson.aspx?query={searchTerms}'
```

### Air-Gapped Environment: Default Engine Plus a Keyword-Triggered Secondary Engine

A customer in an air-gapped network needs an internal search portal as the default, plus a
quick "go" keyword shortcut to jump straight to an internal knowledge base without changing
the default. Typing `go <query>` (keyword, then space, then search terms) in the address bar
searches with that specific engine, bypassing the default:

```powershell
$searchEngines = @'
[
  {
    "is_default": true,
    "keyword": "search.contoso.mil",
    "name": "Contoso Enterprise Search",
    "search_url": "https://search.contoso.mil/search?q={searchTerms}",
    "suggest_url": "https://search.contoso.mil/suggest?q={searchTerms}"
  },
  {
    "keyword": "go",
    "name": "Contoso Quick Search",
    "search_url": "https://go.contoso.mil/search?q={searchTerms}"
  }
]
'@

.\Configure-EdgePolicy.ps1 -ManagedSearchEngines $searchEngines
```

**Note:** JSON whitespace (including newlines) between tokens is valid and does not need to
be collapsed - the multi-line here-string above can be passed directly.

### Disable Address Bar Search

```powershell
.\Configure-EdgePolicy.ps1 -DefaultSearchProviderEnabled $false
```

## What the Script Does

### 1. Policy Configuration

#### Developer Tools

- Enables/disables F12 Developer Tools access
- Useful for restricting advanced browser features in production

#### SmartScreen Allowlist

- Adds trusted domains to bypass SmartScreen warnings
- Essential for internal applications and Azure portals
- Prevents false positives on known-safe domains

#### Popup Management

- Allows popups from specified URL patterns
- Critical for Azure portals and government websites
- Uses wildcard patterns for domain matching

### 2. Policy Application

- Writes settings directly to `Registry.pol` in MS-GPREG (PReg) binary format — no LGPO.exe or internet access required
- Updates `gpt.ini` so the Group Policy client on deployed session hosts knows to process the Registry CSE
- `gpupdate` is intentionally not called during image build; the GP client processes `Registry.pol` automatically at startup/logon on deployed machines

### 3. Registry-Write Fallback (No ADMX Available)

This is the path taken whenever no ADMX can be located - most commonly in **offline or
air-gapped builds** where `customer/artifacts/Configure-EdgePolicy/` has no pre-staged `*.cab`
and `edgeupdates.microsoft.com` is unreachable, but also whenever a bundled CAB is simply
missing and `msedge.admx` isn't already installed. If no `msedge.admx` can be found or
obtained (see [Where to get the Edge Administrative
Templates](#where-to-get-the-edge-administrative-templates)), the script skips
`Registry.pol` entirely and writes every setting with `Set-ItemProperty` directly to
`HKLM:\SOFTWARE\Policies\Microsoft\Edge`. This path behaves differently from the ADMX path:

- **Takes effect immediately** — no `gpupdate`, logon, or reboot needed. Edge reads its policy
  values straight from that registry key on every launch, whether they got there via the GP
  client processing `Registry.pol` or via a direct write.
- **Not visible as a "Group Policy"** — `gpedit.msc`, `rsop.msc`, and `gpresult` won't show
  these as configured policies, since `gpt.ini`/`Registry.pol` were never touched. The settings
  are still enforced by Edge, just not through the GP client.
- **No automatic cleanup** — if you later manage Edge with a real GPO/Intune policy targeting
  the same values, the GPO's next refresh overwrites these registry values (no conflict). But
  if that GPO/Intune policy is later removed, these directly-written values are **not** cleared
  automatically the way GP-tattooed values would be, since they were never GP-managed to begin with.

## Policy Settings Applied

```text
Computer Configuration
└── Administrative Templates
    └── Microsoft Edge
        ├── Allow Developer Tools: [Configured]
        ├── Configure the list of domains for which SmartScreen won't trigger warnings: [Enabled]
        │   └── Domains: [portal.azure.com, core.windows.net, ...]
        └── Allow pop-ups on specific sites: [Enabled]
            └── URL patterns: [[*.]mil, [*.]gov, ...]
```

## Registry Locations

### Developer Tools

```text
HKLM:\SOFTWARE\Policies\Microsoft\Edge
  DeveloperToolsAvailability: 1 (Allowed) or 2 (Disallowed)
```

### SmartScreen Allowlist

```text
HKLM:\SOFTWARE\Policies\Microsoft\Edge\SmartScreenAllowListDomains
  1: portal.azure.com
  2: core.windows.net
  ...
```

### Popup Allowlist

```text
HKLM:\SOFTWARE\Policies\Microsoft\Edge\PopupsAllowedForUrls
  1: [*.]mil
  2: [*.]gov
  ...
```

### Search Provider

```text
HKLM:\SOFTWARE\Policies\Microsoft\Edge
  DefaultSearchProviderEnabled: only written when the parameter is explicitly set to $true or $false; 1 (Enabled) or 0 (Disabled)

  # Legacy single-provider fields - written only when DefaultSearchProviderSearchURL is set;
  # takes priority over ManagedSearchEngines when both parameters are supplied.
  DefaultSearchProviderSearchURL, DefaultSearchProviderName, DefaultSearchProviderKeyword,
  DefaultSearchProviderSuggestURL

  # Multi-engine JSON list - written only when ManagedSearchEngines is non-empty AND
  # DefaultSearchProviderSearchURL is not set.
  ManagedSearchEngines: <JSON array string>
```

## Domain Pattern Matching

### Wildcard Patterns

The `PopupsAllowedForUrls` policy supports wildcard patterns:

| Pattern | Matches |
| --- | --- |
| `[*.]mil` | All `.mil` domains and subdomains |
| `[*.]gov` | All `.gov` domains and subdomains |
| `portal.azure.us` | Exact domain match only |
| `[*.]contoso.com` | All Contoso subdomains |

### Examples

- `[*.]mil` matches: `defense.mil`, `portal.defense.mil`, `subdomain.example.mil`
- `portal.azure.us` matches: `portal.azure.us` (exact match only)

## Logging

Logs are created in:

```text
C:\Windows\Logs\Configuration\Configure-EdgePolicy-<timestamp>.log
```

Log entries include:

- Policy application details
- Registry value creation
- gpupdate execution results

## Functions

| Function | Description |
| --- | --- |
| `Get-InternetFile` | Downloads files from URLs with progress tracking |
| `New-Log` | Initializes logging infrastructure |
| `Remove-RegistryKey` | Removes a registry key |
| `Remove-RegistryValue` | Removes a registry value |
| `Set-PolicyRegistryValue` | Queues a registry value for writing to Registry.pol |
| `Remove-PolicyRegistryValue` | Queues a registry value deletion in Registry.pol |
| `Clear-PolicyRegistryKeyValues` | Queues removal of all values under a registry key in Registry.pol |
| `Invoke-PolicyUpdate` | Flushes the queue to Registry.pol and updates gpt.ini |
| `Set-RegistryValue` | Creates or updates registry values outside Group Policy |
| `Write-Log` | Writes formatted log entries |

## Requirements

- **OS:** Windows 10 or Windows 11
- **Permissions:** Administrator / SYSTEM
- **PowerShell:** 5.1 or higher
- **Microsoft Edge:** Chromium-based Edge (pre-installed on Windows 10/11)
- **Network Access:** Not required — policies are written directly to Registry.pol

## Offline Usage

Once `msedge.admx`/`.adml` are present in `PolicyDefinitions` (or a bundled `*.cab` is staged
next to this script), the script needs no network access at all - it writes directly to
`Registry.pol`. If neither is present and there's no network access to
`edgeupdates.microsoft.com` (the normal state in an air-gapped cloud without pre-staging),
the script does not fail - it automatically takes the [Registry-Write
Fallback](#3-registry-write-fallback-no-admx-available) and writes the same settings straight
to the registry instead. See [Where to get the Edge Administrative
Templates](#where-to-get-the-edge-administrative-templates) for the air-gapped pre-staging
steps if you want the ADMX-backed path instead of the fallback.

```powershell
.\Configure-EdgePolicy.ps1
```

## Default Configuration (Government Cloud)

The default settings are optimized for Azure Government Cloud environments:

### SmartScreen Allowlist

- `portal.azure.com` - Azure Commercial Portal
- `core.windows.net` - Azure Storage (Commercial)
- `portal.azure.us` - Azure Government Portal
- `usgovcloudapi.net` - Azure Government APIs

### Popup Allowlist

- `[*.]mil` - All U.S. military domains
- `[*.]gov` - All U.S. government domains
- `[*.]portal.azure.us` - Azure Government portal subdomains
- `[*.]usgovcloudapi.net` - Azure Government API subdomains
- `[*.]azure.com` - Azure commercial domains
- `[*.]azure.net` - Azure infrastructure domains

## Troubleshooting

### Common Issues

**Issue:** Edge policies not applied

- **Solution:** Run `gpupdate /force`; verify registry values were created

**Issue:** Popups still blocked on allowlisted sites

- **Solution:** Verify URL pattern syntax; restart Edge browser

**Issue:** SmartScreen still warns on allowlisted domains

- **Solution:** Check domain spelling; ensure SmartScreen is enabled in Edge

### Verification

Check if policies were applied:

```powershell
# Check Developer Tools setting
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Edge" -Name DeveloperToolsAvailability

# Check SmartScreen allowlist
Get-ChildItem "HKLM:\SOFTWARE\Policies\Microsoft\Edge\SmartScreenAllowListDomains"

# Check popup allowlist
Get-ChildItem "HKLM:\SOFTWARE\Policies\Microsoft\Edge\PopupsAllowedForUrls"

# Generate Group Policy report
gpresult /h C:\Temp\gpresult.html
```

## Best Practices

1. **Customize for Environment:** Adjust domain lists for your specific requirements
2. **Security First:** Only allowlist domains you trust
3. **Test Thoroughly:** Verify popup and SmartScreen behavior after deployment
4. **Document Changes:** Keep track of custom domain additions
5. **Regular Updates:** Review and update allowlists periodically

## References

- [Microsoft Edge Enterprise Policies](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies)
- [SmartScreenAllowListDomains Policy](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies#smartscreenallowlistdomains)
- [PopupsAllowedForUrls Policy](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies#popupsallowedforurls)

## Support

For issues or questions related to this script, refer to the main repository documentation or contact your IT support team.
