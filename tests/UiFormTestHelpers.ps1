function ConvertTo-CuiAst {
    param([string] $Expression)
    $text = $Expression.Substring(1, $Expression.Length - 2)
    $matches = [regex]::Matches($text, '\s*(=>|[(),.{}:]|"(?:[^"\\]|\\.)*"|''(?:[^'']|'''')*''|[A-Za-z_][A-Za-z0-9_]*|\d+)')
    if (($matches.Value -join '') -ne $text) { throw "Unrecognized expression token: $Expression" }
    $state = @{ Tokens = @($matches | ForEach-Object { $_.Groups[1].Value }); Position = 0 }
    function Read-CuiNode($State) {
        $token = $State.Tokens[$State.Position++]
        if ($token -eq '{') {
            $properties = @{}
            while ($State.Tokens[$State.Position] -ne '}') {
                $key = ConvertFrom-Json -InputObject $State.Tokens[$State.Position++]
                if ($State.Tokens[$State.Position++] -ne ':') { throw 'Expected object property separator' }
                $properties[$key] = Read-CuiNode $State
                if ($State.Tokens[$State.Position] -ne ',') { break }
                $State.Position++
            }
            if ($State.Tokens[$State.Position++] -ne '}') { throw 'Expected object closing brace' }
            return @{ Kind = 'object'; Properties = $properties }
        }
        if ($token -eq '(') {
            $parameter = $State.Tokens[$State.Position++]
            if ($State.Tokens[$State.Position++] -ne ')' -or $State.Tokens[$State.Position++] -ne '=>') {
                throw 'Expected lambda'
            }
            return @{ Kind = 'lambda'; Parameter = $parameter; Body = (Read-CuiNode $State) }
        }
        if ($token.StartsWith("'")) {
            $node = @{ Kind = 'literal'; Value = $token.Substring(1, $token.Length - 2).Replace("''", "'") }
        } elseif ($token.StartsWith('"')) {
            $node = @{ Kind = 'literal'; Value = (ConvertFrom-Json -InputObject $token) }
        } elseif ($token -match '^\d+$') {
            $node = @{ Kind = 'literal'; Value = [int] $token }
        } elseif ($token -in @('true', 'false')) {
            $node = @{ Kind = 'literal'; Value = ($token -eq 'true') }
        } elseif ($State.Position -lt $State.Tokens.Count -and $State.Tokens[$State.Position] -eq '(') {
            $State.Position++
            $arguments = [System.Collections.Generic.List[object]]::new()
            if ($State.Tokens[$State.Position] -ne ')') {
                while ($true) {
                    $arguments.Add((Read-CuiNode $State))
                    if ($State.Tokens[$State.Position] -ne ',') { break }
                    $State.Position++
                }
            }
            if ($State.Tokens[$State.Position++] -ne ')') { throw "Expected ')' in $token" }
            $node = @{ Kind = 'call'; Name = $token; Arguments = $arguments.ToArray() }
        } else {
            $node = @{ Kind = 'variable'; Name = $token }
        }
        while ($State.Position -lt $State.Tokens.Count -and $State.Tokens[$State.Position] -eq '.') {
            $State.Position++
            $node = @{ Kind = 'member'; Object = $node; Name = $State.Tokens[$State.Position++] }
        }
        return $node
    }
    $result = Read-CuiNode $state
    if ($state.Position -ne $state.Tokens.Count) { throw 'Unexpected trailing expression tokens' }
    return $result
}

function Test-CuiEmpty($Value) {
    return ($null -eq $Value -or ($Value -is [string] -and $Value.Length -eq 0) -or
        ($Value -is [array] -and $Value.Count -eq 0) -or
        ($Value -is [System.Collections.IDictionary] -and $Value.Count -eq 0))
}

function Invoke-CuiAst($Node, $Variables, $Steps, [bool] $PortalLambdaScope = $false) {
    switch ($Node.Kind) {
        literal { return ,$Node.Value }
        object {
            $result = @{}
            foreach ($key in $Node.Properties.Keys) {
                $result[$key] = Invoke-CuiAst $Node.Properties[$key] $Variables $Steps $PortalLambdaScope
            }
            return ,$result
        }
        variable {
            if (-not $Variables.ContainsKey($Node.Name)) { throw "Unresolved lambda variable: $($Node.Name)" }
            return ,$Variables[$Node.Name]
        }
        member {
            $value = Invoke-CuiAst $Node.Object $Variables $Steps $PortalLambdaScope
            if ($null -eq $value) { return $null }
            return ,$value.($Node.Name)
        }
        call {
            if ($Node.Name -eq 'if') {
                $condition = Invoke-CuiAst $Node.Arguments[0] $Variables $Steps $PortalLambdaScope
                $branch = if ($condition) { 1 } else { 2 }
                return ,(Invoke-CuiAst $Node.Arguments[$branch] $Variables $Steps $PortalLambdaScope)
            }
            if ($Node.Name -in @('map', 'filter')) {
                $items = Invoke-CuiAst $Node.Arguments[0] $Variables $Steps $PortalLambdaScope
                if ($null -eq $items) { throw "$($Node.Name) evaluated before its array was ready" }
                $lambda = $Node.Arguments[1]
                $result = [System.Collections.Generic.List[object]]::new()
                foreach ($item in $items) {
                    $scope = if ($PortalLambdaScope) { @{} } else { $Variables.Clone() }
                    $scope[$lambda.Parameter] = $item
                    $value = Invoke-CuiAst $lambda.Body $scope $Steps $PortalLambdaScope
                    if ($Node.Name -eq 'map') { $result.Add($value) }
                    elseif ($value) { $result.Add($item) }
                }
                return ,$result.ToArray()
            }
            $arguments = [System.Collections.Generic.List[object]]::new()
            foreach ($argument in $Node.Arguments) {
                $arguments.Add((Invoke-CuiAst $argument $Variables $Steps $PortalLambdaScope))
            }
            switch ($Node.Name) {
                steps { return ,$Steps[$arguments[0]] }
                parse { return ,(ConvertFrom-Json -InputObject $arguments[0] -AsHashtable -NoEnumerate) }
                string {
                    if ($arguments[0] -is [string]) { return $arguments[0] }
                    return (ConvertTo-Json -InputObject $arguments[0] -Depth 100 -Compress)
                }
                empty { return (Test-CuiEmpty $arguments[0]) }
                not { return (-not $arguments[0]) }
                and { return (-not (@($arguments | Where-Object { -not $_ }).Count -gt 0)) }
                or { return (@($arguments | Where-Object { $_ }).Count -gt 0) }
                equals { return ($arguments[0] -ceq $arguments[1]) }
                contains {
                    if ($arguments[0] -is [string]) { return $arguments[0].Contains([string] $arguments[1]) }
                    if ($arguments[0] -is [System.Collections.IDictionary]) { return $arguments[0].Contains($arguments[1]) }
                    return ($arguments[0] -ccontains $arguments[1])
                }
                startsWith { return $arguments[0].StartsWith($arguments[1], [StringComparison]::Ordinal) }
                concat { return ($arguments -join '') }
                split { return ,$arguments[0].Split([string] $arguments[1]) }
                skip { return ,@($arguments[0] | Select-Object -Skip $arguments[1]) }
                first { return ,$arguments[0][0] }
                default { throw "Unsupported function: $($Node.Name)" }
            }
        }
        default { throw "Unexpected node kind: $($Node.Kind)" }
    }
}

function Invoke-CuiExpression([string] $Expression, [hashtable] $Steps, [switch] $PortalLambdaScope) {
    if (-not $Expression.StartsWith('[')) { return $Expression }
    return ,(Invoke-CuiAst (ConvertTo-CuiAst $Expression) @{} $Steps $PortalLambdaScope.IsPresent)
}

function Set-CuiValue([hashtable] $Steps, [string] $Reference, $Value) {
    $match = [regex]::Match($Reference, "^steps\('([^']+)'\)\.(.+)$")
    if (-not $match.Success) { throw "Invalid control reference: $Reference" }
    $parts = @($match.Groups[1].Value) + $match.Groups[2].Value.Split('.')
    $current = $Steps
    foreach ($part in $parts[0..($parts.Count - 2)]) {
        if (-not $current.ContainsKey($part)) { $current[$part] = @{} }
        $current = $current[$part]
    }
    $current[$parts[-1]] = $Value
}

function ConvertFrom-CuiAst($Node) {
    switch ($Node.Kind) {
        literal {
            if ($Node.Value -is [string]) { return "'$($Node.Value.Replace("'", "''"))'" }
            return ([string] $Node.Value).ToLowerInvariant()
        }
        member { return "$(ConvertFrom-CuiAst $Node.Object).$($Node.Name)" }
        object {
            $properties = foreach ($key in $Node.Properties.Keys) {
                "$(ConvertTo-Json -InputObject $key -Compress): $(ConvertFrom-CuiAst $Node.Properties[$key])"
            }
            return "{$($properties -join ', ')}"
        }
        variable { return $Node.Name }
        lambda { return "($($Node.Parameter)) => $(ConvertFrom-CuiAst $Node.Body)" }
        call { return "$($Node.Name)($((@($Node.Arguments | ForEach-Object { ConvertFrom-CuiAst $_ })) -join ', '))" }
    }
}

function Get-CuiObjectBinding([string] $Expression, [string] $Property) {
    $node = ConvertTo-CuiAst $Expression
    if ($node.Name -ne 'first' -or $node.Arguments[0].Name -ne 'map' -or
        $node.Arguments[0].Arguments[1].Body.Kind -ne 'object') {
        throw 'Expected a native object-valued map expression'
    }
    $properties = $node.Arguments[0].Arguments[1].Body.Properties
    if (-not $properties.ContainsKey($Property)) { throw "Missing object property: $Property" }
    return "[$(ConvertFrom-CuiAst $properties[$Property])]"
}
