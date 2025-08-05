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
    #First try to find search string in actual link href
    $Links = $HTML.Links
    $LinkHref = $HTML
    $LinkHref = $HTML.Links.Href | Get-Unique | Where-Object { $_ -like $SearchString }
    If ($LinkHref) {
        if ($LinkHref.Contains('http://') -or $LinkHref.Contains('https://')) {
            Return $LinkHref
        }
        Else {
            $LinkHref = $WebSiteUrl.AbsoluteUri + $LinkHref
            Return $LinkHref
        }
        Return $LinkHref
    }
    #If not found, try to find search string in the outer html
    $LinkHref = $Links | Where-Object { $_.OuterHTML -like $SearchString }
    If ($LinkHref) {
        Return $LinkHref.href
    }
    # Escape user input for regex and convert * to regex wildcard
    $escapedPattern = [Regex]::Escape($SearchString) -replace '\\\*', '[^""''\s>]*'
    # Match http or https URLs ending in the desired filename pattern
    $regex = "https?://[^""'\s>]*$escapedPattern"
    Return ([regex]::Matches($html.Content, $regex)).Value
}