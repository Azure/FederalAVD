param(
    [securestring]
    [Parameter(Mandatory = $true)]
    [string] $ScriptB64,

    [securestring]
    [Parameter()]
    [string] $SecureParameter, # JSON string containing secure parameter object with Name and Value properties

    [Parameter()]
    [string] $Parameters # JSON string containing regular parameter array
)

$ErrorActionPreference = 'Stop'

# Decode the base64-encoded script
$bytes = [Convert]::FromBase64String($ScriptB64)
$script = [Text.Encoding]::UTF8.GetString($bytes)

# Normalize line endings (optional but safe)
$script = $script -replace "`r`n", "`n" -replace "`r", "`n"

# Initialize parameter collections
$params = @{}

# Parse parameters - JSON array of objects with 'name' and 'value' properties
if ($Parameters -and $Parameters.Trim() -ne '[]') {
    try {
        $paramArray = ConvertFrom-Json $Parameters -ErrorAction Stop
        
        # Ensure we have an array (even if single object)
        if ($paramArray -isnot [array]) {
            $paramArray = @($paramArray)
        }
        
        foreach ($param in $paramArray) {
            # Handle switch parameters - if only 'name' property exists, it's a switch parameter set to $true
            if ($param.PSObject.Properties.Name -contains 'name' -and $param.PSObject.Properties.Name -notcontains 'value') {
                $params[$param.name] = $true
                Write-Host "Added switch parameter: $($param.name) = True"
            }
            # Handle parameters with values
            elseif ($param.PSObject.Properties.Name -contains 'name' -and $param.PSObject.Properties.Name -contains 'value') {
                $value = $param.value
                
                # All values come in as strings from run commands, so we need to parse them appropriately
                # Check if string represents a boolean
                if ($value.ToLower() -eq 'true') {
                    $value = $true
                    Write-Host "Added boolean parameter: $($param.name) = $value"
                }
                elseif ($value.ToLower() -eq 'false') {
                    $value = $false
                    Write-Host "Added boolean parameter: $($param.name) = $value"
                }
                # Check if string represents an integer
                elseif ($value -match '^\d+$') {
                    $value = [int]$value
                    Write-Host "Added integer parameter: $($param.name) = $value"
                }
                # Check if string represents a negative integer
                elseif ($value -match '^-\d+$') {
                    $value = [int]$value
                    Write-Host "Added integer parameter: $($param.name) = $value"
                }
                # Check if string represents a decimal number
                elseif ($value -match '^-?\d+\.\d+$') {
                    $value = [double]$value
                    Write-Host "Added decimal parameter: $($param.name) = $value"
                }
                else {
                    # Keep as string
                    Write-Host "Added string parameter: $($param.name) = $value"
                }                
                # Add as parameter
                $params[$param.name] = $value
            }
            else {
                Write-Warning "Parameter object format not recognized. Expected 'name' only (switch) or 'name' and 'value': $($param | ConvertTo-Json -Compress)"
            }
        }        
        Write-Host "Parsed $($params.Count) named parameters"
    }
    catch {
        Write-Error "Failed to parse Parameters JSON: $($_.Exception.Message)"
        Write-Host "Parameters content: $Parameters"
        throw
    }
}


# Parse secure parameters - JSON object or array of objects with 'Name' and 'Value' properties
if ($SecureParameter -and $SecureParameter.Trim() -ne '') {
    try {
        [pscustomObject]$secureParam = ConvertFrom-Json $SecureParameter -ErrorAction Stop      

        # Handle switch parameters - if only 'Name' property exists, it's a switch parameter set to $true
        if ($secureParam.PSObject.Properties.Name -contains 'Name' -and $secureParam.PSObject.Properties.Name -notcontains 'Value') {
            $params[$secureParam.Name] = $true
            Write-Host "Added secure switch parameter: $($secureParam.Name) = True"
        }
        # Handle named parameters with values
        elseif ($secureParam.PSObject.Properties.Name -contains 'Name' -and $secureParam.PSObject.Properties.Name -contains 'Value') {
            $value = $secureParam.Value
                
            # All values come in as strings from run commands, so we need to parse them appropriately
            # Check if string represents a boolean
            if ($value.ToLower() -eq 'true') {
                $value = $true
                Write-Host "Added secure boolean parameter: $($secureParam.Name) = $value"
            }
            elseif ($value.ToLower() -eq 'false') {
                $value = $false
                Write-Host "Added secure boolean parameter: $($secureParam.Name) = $value"
            }
            # Check if string represents an integer
            elseif ($value -match '^\d+$') {
                $value = [int]$value
                Write-Host "Added secure integer parameter: $($secureParam.Name) = $value"
            }
            # Check if string represents a negative integer
            elseif ($value -match '^-\d+$') {
                $value = [int]$value
                Write-Host "Added secure integer parameter: $($secureParam.Name) = $value"
            }
            # Check if string represents a decimal number
            elseif ($value -match '^-?\d+\.\d+$') {
                $value = [double]$value
                Write-Host "Added secure decimal parameter: $($secureParam.Name) = $value"
            }
            else {
                # Keep as string
                Write-Host "Added secure string parameter: $($secureParam.Name)"
            }
                
            $params[$secureParam.Name] = $value
        }
        else {
            Write-Warning "Secure parameter object format not recognized. Expected 'Name' only (switch) or 'Name' and 'Value': $($secureParam | ConvertTo-Json -Compress)"
        }
        Write-Host "Parsed $($secureParamObject.Count) secure parameters"
    }
    catch {
        Write-Error "Failed to parse SecureParameter JSON: $($_.Exception.Message)"
        Write-Host "SecureParameter content: $SecureParameter"
        throw
    }        

}



# Execute
$sb = [ScriptBlock]::Create($script)
try {
    Write-Host "----- Begin user script output -----"
    if ($params.Count -gt 0) {
        & $sb @params
    }
    else {
        & $sb
    }

    $exitCode = if ($LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    Write-Host "----- End user script output -----"
    exit $exitCode
}
catch {
    Write-Error ("User script threw: " + $_.Exception.Message)
    Write-Error $_.Exception | Format-List * -Force
    exit 1
}