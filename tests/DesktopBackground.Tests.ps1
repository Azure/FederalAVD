BeforeAll {
    $artifactPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'customer-examples\artifacts\Configure-DesktopBackground'
    $installerPath = Join-Path $artifactPath 'Set-DesktopBackground.ps1'
    $readme = Get-Content -LiteralPath (Join-Path $artifactPath 'README.md') -Raw
    Add-Type -AssemblyName System.Drawing
}

Describe 'Bundled desktop background images' {
    It 'contains one root installer and exactly the documented JPEG choices' {
        @(Get-ChildItem -LiteralPath $artifactPath -Filter '*.ps1' -File).Count | Should -Be 1
        $names = @(Get-ChildItem -LiteralPath $artifactPath -Filter '*.jpg' -File).Name | Sort-Object
        $expectedNames = @(
            'FederalAVD_Air_Force_MissionReady_4K.jpg'
            'FederalAVD_Army_MissionReady_4K.jpg'
            'FederalAVD_Civilian_Missions_MissionReady_4K.jpg'
            'FederalAVD_Coast_Guard_MissionReady_4K.jpg'
            'FederalAVD_Federal_Generic_MissionReady_4K.jpg'
            'FederalAVD_Intelligence_MissionReady_4K.jpg'
            'FederalAVD_Marine_Corps_MissionReady_4K.jpg'
            'FederalAVD_Navy_MissionReady_4K.jpg'
            'FederalAVD_Space_Force_MissionReady_4K.jpg'
        )
        $names -join ',' | Should -Be ($expectedNames -join ',')
        foreach ($name in $expectedNames) {
            $readme | Should -Match ([regex]::Escape("[$name]($name)"))
        }
    }

    It 'ships <ImageFile> as a decoded 3840x2160 JPEG under 3 MB' -TestCases @(
        @{ ImageFile = 'FederalAVD_Federal_Generic_MissionReady_4K.jpg' }
        @{ ImageFile = 'FederalAVD_Air_Force_MissionReady_4K.jpg' }
        @{ ImageFile = 'FederalAVD_Army_MissionReady_4K.jpg' }
        @{ ImageFile = 'FederalAVD_Civilian_Missions_MissionReady_4K.jpg' }
        @{ ImageFile = 'FederalAVD_Coast_Guard_MissionReady_4K.jpg' }
        @{ ImageFile = 'FederalAVD_Intelligence_MissionReady_4K.jpg' }
        @{ ImageFile = 'FederalAVD_Marine_Corps_MissionReady_4K.jpg' }
        @{ ImageFile = 'FederalAVD_Navy_MissionReady_4K.jpg' }
        @{ ImageFile = 'FederalAVD_Space_Force_MissionReady_4K.jpg' }
    ) {
        param($ImageFile)
        $path = Join-Path $artifactPath $ImageFile
        $image = [System.Drawing.Image]::FromFile($path)
        try {
            $image.RawFormat.Guid | Should -Be ([System.Drawing.Imaging.ImageFormat]::Jpeg.Guid)
            $image.Width | Should -Be 3840
            $image.Height | Should -Be 2160
            (Get-Item -LiteralPath $path).Length | Should -BeLessThan 3MB
        } finally {
            $image.Dispose()
        }
    }
}

Describe 'Desktop background selection and isolated policy writes' {
    BeforeEach {
        $originalSystemRoot = $env:SystemRoot
        $originalSuppressFileLog = $env:SUPPRESS_FILELOG
        $env:SystemRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $env:SUPPRESS_FILELOG = '1'
        New-Item -ItemType Directory -Path $env:SystemRoot | Out-Null
    }

    AfterEach {
        $env:SystemRoot = $originalSystemRoot
        $env:SUPPRESS_FILELOG = $originalSuppressFileLog
    }

    It 'selects <Label> and preserves the three User-scope policy values' -TestCases @(
        @{ Label = 'the Federal Generic default'; Selection = @{}; Expected = 'FederalAVD_Federal_Generic_MissionReady_4K.jpg' }
        @{ Label = 'Federal Generic explicitly'; Selection = @{ ImageFile = 'FederalAVD_Federal_Generic_MissionReady_4K.jpg' }; Expected = 'FederalAVD_Federal_Generic_MissionReady_4K.jpg' }
        @{ Label = 'Air Force'; Selection = @{ ImageFile = 'FederalAVD_Air_Force_MissionReady_4K.jpg' }; Expected = 'FederalAVD_Air_Force_MissionReady_4K.jpg' }
        @{ Label = 'Army'; Selection = @{ ImageFile = 'FederalAVD_Army_MissionReady_4K.jpg' }; Expected = 'FederalAVD_Army_MissionReady_4K.jpg' }
        @{ Label = 'Civilian Missions'; Selection = @{ ImageFile = 'FederalAVD_Civilian_Missions_MissionReady_4K.jpg' }; Expected = 'FederalAVD_Civilian_Missions_MissionReady_4K.jpg' }
        @{ Label = 'Coast Guard'; Selection = @{ ImageFile = 'FederalAVD_Coast_Guard_MissionReady_4K.jpg' }; Expected = 'FederalAVD_Coast_Guard_MissionReady_4K.jpg' }
        @{ Label = 'Intelligence'; Selection = @{ ImageFile = 'FederalAVD_Intelligence_MissionReady_4K.jpg' }; Expected = 'FederalAVD_Intelligence_MissionReady_4K.jpg' }
        @{ Label = 'Marine Corps'; Selection = @{ ImageFile = 'FederalAVD_Marine_Corps_MissionReady_4K.jpg' }; Expected = 'FederalAVD_Marine_Corps_MissionReady_4K.jpg' }
        @{ Label = 'Navy'; Selection = @{ ImageFile = 'FederalAVD_Navy_MissionReady_4K.jpg' }; Expected = 'FederalAVD_Navy_MissionReady_4K.jpg' }
        @{ Label = 'Space Force'; Selection = @{ ImageFile = 'FederalAVD_Space_Force_MissionReady_4K.jpg' }; Expected = 'FederalAVD_Space_Force_MissionReady_4K.jpg' }
    ) {
        param($Label, $Selection, $Expected)
        . $installerPath @Selection

        $destination = Join-Path $env:SystemRoot "Web\Wallpaper\Custom\$Expected"
        $actualBytes = [IO.File]::ReadAllBytes($destination)
        $expectedBytes = [IO.File]::ReadAllBytes((Join-Path $artifactPath $Expected))
        [Convert]::ToBase64String($actualBytes) | Should -Be ([Convert]::ToBase64String($expectedBytes))
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $destination) -File).Count | Should -Be 1
        Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\GroupPolicy\Machine\Registry.pol') |
            Should -BeFalse
        $gpt = Get-Content -LiteralPath (Join-Path $env:SystemRoot 'System32\GroupPolicy\gpt.ini') -Raw
        $gpt | Should -Match 'gPCUserExtensionNames='
        $gpt | Should -Not -Match 'gPCMachineExtensionNames='

        $entries = Read-PRegFile -Path (Join-Path $env:SystemRoot 'System32\GroupPolicy\User\Registry.pol')
        $entries.Count | Should -Be 3
        $wallpaper = @($entries | Where-Object Name -eq 'Wallpaper')
        $wallpaper.Count | Should -Be 1
        $wallpaper[0].Key | Should -Be 'Software\Microsoft\Windows\CurrentVersion\Policies\System'
        $wallpaper[0].Type | Should -Be 1
        [Text.Encoding]::Unicode.GetString($wallpaper[0].Data).TrimEnd([char]0) | Should -Be $destination
        $style = @($entries | Where-Object Name -eq 'WallpaperStyle')
        $style.Count | Should -Be 1
        $style[0].Key | Should -Be $wallpaper[0].Key
        $style[0].Type | Should -Be 1
        [Text.Encoding]::Unicode.GetString($style[0].Data).TrimEnd([char]0) | Should -Be '4'
        $prevent = @($entries | Where-Object Name -eq 'NoChangingWallPaper')
        $prevent.Count | Should -Be 1
        $prevent[0].Key | Should -Be 'Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop'
        $prevent[0].Type | Should -Be 4
        [BitConverter]::ToUInt32($prevent[0].Data, 0) | Should -Be 1
    }

    It 'fails explicitly for a missing selection instead of choosing another JPEG' {
        { . $installerPath -ImageFile 'Missing.jpg' 2>$null } |
            Should -Throw "*Background image 'Missing.jpg' was not found*"
        Test-Path -LiteralPath (Join-Path $env:SystemRoot 'Web\Wallpaper\Custom') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\GroupPolicy\User\Registry.pol') |
            Should -BeFalse
    }

    It 'rejects invalid selection <ImageFile> before writing policy' -TestCases @(
        @{ ImageFile = '..\FederalAVD_Federal_Generic_MissionReady_4K.jpg' }
        @{ ImageFile = 'C:\FederalAVD_Federal_Generic_MissionReady_4K.jpg' }
        @{ ImageFile = '*.jpg' }
        @{ ImageFile = 'FederalAVD_Federal_Generic_MissionReady_4K.png' }
        @{ ImageFile = '' }
    ) {
        param($ImageFile)
        { . $installerPath -ImageFile $ImageFile } | Should -Throw
        @(Get-ChildItem -LiteralPath $env:SystemRoot -Recurse -File).Count | Should -Be 0
    }
}
