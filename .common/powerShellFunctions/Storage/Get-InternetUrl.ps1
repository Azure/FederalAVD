<#
.SYNOPSIS
Extract the download URL from a website based on a search string. Uses a matching search string by prepending and appending a wildcard character to the string.

.DESCRIPTION


.PARAMETER Url
Specifies the URI to search for a link.

.PARAMETER SearchString
Specifies the search string that is used to find a matching hyperlink. You can include a '*' for a wildcard in the search string.

.EXAMPLE
Get-InternetUrl -WebSiteUrl "http://www.microsoft.com/software/wvd" -SearchString "FSLogix"

Searches the provided website url for a hyperlink with the searchstring "FSLogix" contained in it and returns the url. 
#>

Function Get-InternetUrl {
    [CmdletBinding()]
    Param (
        [Parameter(
            Mandatory,
            HelpMessage = "Specifies the website that contains a link to the desired download."
        )]
        [uri]$WebSiteUrl,

        [Parameter(
            Mandatory,
            HelpMessage = "Specifies the search string. Wildcard '*' can be used."    
        )]
        [string]$SearchString
    )

    $HTML = Invoke-WebRequest -Uri $WebSiteUrl -UseBasicParsing
    $Links = $HTML.Links
    #First try to find search string in actual link href
    $LinkHref = $HTML.Links.Href | Get-Unique | Where-Object { $_ -like "*$SearchString*" }
    If ($LinkHref) {
        Return $LinkHref
    }
    #If not found, try to find search string in the outer html
    $LinkHrefs = $Links | Where-Object { $_.OuterHTML -like "*$SearchString*" }
    If ($LinkHrefs) {
        Return $LinkHrefs.href
    }
    Else {
        $Pattern = '"url":\s*"(https://[^"]*?' + $SearchString.Replace('.', '\.').Replace('*', '.*').Replace('+', '\+') + ')"' 
        If ($HTML.Content -match $Pattern) {
            If ($matches[1].Contains('"')) {
                Return $matches[1].Substring(0, $matches[1].IndexOf('"'))
            }
            Else {
                Return $matches[1]
            }

        }
        else {
            Write-Warning "No download URL found using search term."
            Return $null
        }
    }

}