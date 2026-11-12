$repoRoot = Split-Path -Parent $PSScriptRoot

Describe 'Image validation tag object mapping' {
    It 'preserves grid values and existing resource-type tag callers' {
        $node = Get-Command node -ErrorAction SilentlyContinue
        $runtime = if ($node) { $node.Source } else {
            @(
                "$env:ProgramFiles\Microsoft VS Code\Code.exe"
                "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe"
            ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        }
        if (-not $runtime) { throw 'Tag expression tests require Node.js or VS Code.' }

        $prefix = Join-Path ([IO.Path]::GetTempPath()) ('FederalAVD-Tags-' + [guid]::NewGuid().ToString('N'))
        $scriptFile = "$prefix.js"
        $outputFile = "$prefix.out"
        $errorFile = "$prefix.err"
        $originalElectronMode = $env:ELECTRON_RUN_AS_NODE
        try {
            $script = @'
const fs = require('fs');
const assert = require('assert');
const root = process.argv[2];
const path = require('path');
const form = JSON.parse(fs.readFileSync(path.join(root, 'deployments', 'add-ons', 'imageValidation', 'uiFormDefinition.json'), 'utf8'));
const template = JSON.parse(fs.readFileSync(path.join(root, 'deployments', 'add-ons', 'imageValidation', 'main.json'), 'utf8'));
const parse = JSON.parse, string = JSON.stringify;
const concat = (...parts) => parts.join('');
const map = (values, fn) => values.map(fn), filter = (values, fn) => values.filter(fn);
const substring = (value, start, count) => value.substr(start, count);
const length = value => value.length, sub = (left, right) => left - right;
const replace = (value, from, to) => value.split(from).join(to);
const encodeUriComponent = encodeURIComponent, decodeUriComponent = decodeURIComponent;
const empty = value => value == null || value === '' || (typeof value === 'object' && Object.keys(value).length === 0);
const contains = (value, key) => typeof value === 'string' ? value.includes(key) : Object.keys(value).some(k => k.toLowerCase() === key.toLowerCase());
const items = value => Object.entries(value).map(([key, value]) => ({key, value}));
const tryGet = (value, key) => value[key];
const coalesce = (...values) => values.find(value => value != null);
const createObject = () => ({});

function convertIf(expression) {
    const start = expression.indexOf('if(');
    if (start < 0) return expression;
    let quote = null, depth = 1, partStart = start + 3;
    const parts = [];
    for (let i = partStart; i < expression.length; i++) {
        const c = expression[i];
        if (quote) {
            if (c === '\\') i++;
            else if (c === quote) quote = null;
        } else if (c === "'" || c === '"') quote = c;
        else if (c === '(') depth++;
        else if (c === ')') {
            if (--depth === 0) {
                parts.push(expression.slice(partStart, i));
                assert.strictEqual(parts.length, 3);
                const conditional = '(' + convertIf(parts[0]) + '?' + convertIf(parts[1]) + ':' + convertIf(parts[2]) + ')';
                return convertIf(expression.slice(0, start) + conditional + expression.slice(i + 1));
            }
        } else if (c === ',' && depth === 1) {
            parts.push(expression.slice(partStart, i));
            partStart = i + 1;
        }

    }
    throw new Error('Unclosed if expression');
}

const gridExpression = convertIf(form.view.outputs.parameters.tags.slice(1, -1));
const samples = [
    [],
    [{key: 'Environment', value: 'Production'}],
    [{key: 'Quotes"Key', value: '"quoted" C:\\Temp'}],
    [{key: 'Delimiters', value: '},{ [" "] "," %22%2C'}, {key: 'Other', value: 'value'}],
    [{key: 'Unicode', value: '\u2603 \uD83D\uDE00'}, {key: 'Controls', value: '\t\n\r'}],
    [{key: 'Empty', value: ''}, {key: 'Omitted'}, {key: 'Null', value: null}],
    [{key: '__proto__', value: 'text'}],
    Array.from({length: 50}, (_, i) => ({key: 'Key' + i, value: 'Value' + i}))
];
for (const rows of samples) {
    const steps = () => ({tagsSection: {tags: rows}});
    const expected = Object.fromEntries(rows.map(row => [row.key, row.value ?? '']));
    assert.deepStrictEqual(eval(gridExpression), expected);
}

const cases = [
    {tags: {}, type: 'Microsoft.Web/sites', expected: {}},
    {tags: {Environment: 'Production'}, type: 'Microsoft.Web/sites', expected: {Environment: 'Production'}},
    {tags: {Environment: 'Production'}, type: 'Microsoft.Network/privateEndpoints', expected: {Environment: 'Production'}},
    {tags: {'Microsoft.Web/sites': {App: 'yes'}}, type: 'Microsoft.Web/sites', expected: {App: 'yes'}},
    {tags: {'Microsoft.Web/sites': {App: 'yes'}}, type: 'Microsoft.Storage/storageAccounts', expected: {}},
    {tags: {'Microsoft.Web/sites': {}}, type: 'Microsoft.Web/sites', expected: {}}
];
for (const module of ['functionApp', 'serverFarm', 'storageCmk', 'encryptionKeyVault']) {
    const functions = template.resources[module].properties.template.functions;
    const helper = functions.flatMap(group => Object.values(group.members)).find(fn =>
        fn.parameters?.some(parameter => parameter.name === 'resourceType'));
    assert(helper, module + ' must use shared tag compatibility');
    const expression = convertIf(helper.output.value.slice(1, -1).replace(
        /lambda\('item', contains\(lambdaVariables\('item'\)\.key, '\/'\)\)/g,
        "(item) => contains(item.key, '/')"));
    for (const sample of cases) {
        const parameters = name => name === 'tags' ? sample.tags : sample.type;
        assert.deepStrictEqual(eval(expression), sample.expected);
    }
}
console.log('Passed 8 grid mapping cases and 24 shared-module compatibility cases.');
'@
            [IO.File]::WriteAllText($scriptFile, $script)
            $env:ELECTRON_RUN_AS_NODE = '1'
            $process = Start-Process -FilePath $runtime -ArgumentList @(
                "`"$scriptFile`"", "`"$repoRoot`""
            ) -Wait -PassThru -RedirectStandardOutput $outputFile -RedirectStandardError $errorFile
            if ($process.ExitCode -ne 0) {
                throw (Get-Content -LiteralPath $errorFile -Raw)
            }
            (Get-Content -LiteralPath $outputFile -Raw) |
                Should Match 'Passed 8 grid mapping cases and 24 shared-module compatibility cases.'
        } finally {
            $env:ELECTRON_RUN_AS_NODE = $originalElectronMode
            foreach ($file in @($scriptFile, $outputFile, $errorFile)) {
                if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force -ErrorAction Stop }
            }
        }
    }

    It 'forwards object tags to the validation VM deployment without losing string values' {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $repoRoot 'deployments\add-ons\imageValidation\scripts\run.ps1'),
            [ref]$tokens, [ref]$parseErrors
        )
        $parseErrors.Count | Should Be 0
        $bodyAssignment = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -eq '$Body'
        }, $true)
        $bodyAssignment | Should Not BeNullOrEmpty
        $originalTags = $env:tags
        try {
            $env:tags = '{"Environment":"Production","Notes":"Quotes: \" and path C:\\Temp"}'
            Invoke-Expression $bodyAssignment.Extent.Text
            $vmTags = ($Body | ConvertFrom-Json).properties.parameters.tags.value
            ($vmTags.PSObject.Properties.Name -join ',') | Should Be 'Environment,Notes'
            $vmTags.Environment | Should Be 'Production'
            $vmTags.Notes | Should Be 'Quotes: " and path C:\Temp'
        } finally {
            $env:tags = $originalTags
        }
    }
}
