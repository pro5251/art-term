# Checks that the Node and Rust command-line tools exist before a build calls
# them, so a missing tool stops with install guidance instead of a raw
# "command not found" error halfway through the build.
$script:ArtTermBuildTools = [ordered]@{
    node  = @{ Command = 'node.exe';  Package = 'OpenJS.NodeJS.LTS' }
    npm   = @{ Command = 'npm.cmd';   Package = 'OpenJS.NodeJS.LTS' }
    cargo = @{ Command = 'cargo.exe'; Package = 'Rustlang.Rustup' }
    rustc = @{ Command = 'rustc.exe'; Package = 'Rustlang.Rustup' }
}

function Get-ArtTermMissingBuildTools {
    param([string[]]$Tools)
    @($Tools | Where-Object {
        -not (Get-Command $script:ArtTermBuildTools[$_].Command -CommandType Application -ErrorAction SilentlyContinue)
    })
}

function Update-ArtTermSessionPath {
    # Tools installed after this shell started are only on the registry PATH.
    $env:Path = (@($env:Path,
        [Environment]::GetEnvironmentVariable('Path', 'Machine'),
        [Environment]::GetEnvironmentVariable('Path', 'User')) | Where-Object { $_ }) -join ';'
}

function Test-ArtTermInteractiveHost {
    if ($env:CI -or $env:GITHUB_ACTIONS) { return $false }
    if (-not [Environment]::UserInteractive) { return $false }
    -not ([Environment]::GetCommandLineArgs() | Where-Object { $_ -match '^-NonI' })
}

function Assert-ArtTermBuildTools {
    param(
        [ValidateSet('node', 'npm', 'cargo', 'rustc')][string[]]$Tools = @('node', 'npm', 'cargo', 'rustc'),
        [switch]$RequireMsvcHost
    )
    $missing = Get-ArtTermMissingBuildTools $Tools
    if ($missing) {
        Update-ArtTermSessionPath
        $missing = Get-ArtTermMissingBuildTools $Tools
    }
    if ($missing) {
        $packages = @($missing | ForEach-Object { $script:ArtTermBuildTools[$_].Package } | Select-Object -Unique)
        $commands = @($packages | ForEach-Object { "winget install --id $_ --exact --source winget --accept-package-agreements --accept-source-agreements" })
        Write-Host ''
        Write-Host "Missing build tools: $(($missing | ForEach-Object { $script:ArtTermBuildTools[$_].Command }) -join ', ')" -ForegroundColor Yellow
        Write-Host 'Install with:' -ForegroundColor Yellow
        $commands | ForEach-Object { Write-Host "  $_" }
        $winget = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $install = $false
        if ($winget -and (Test-ArtTermInteractiveHost)) {
            $answer = Read-Host 'Install them now with WinGet? [Y/n]'
            $install = $answer -eq '' -or $answer -match '^(y|yes)$'
        }
        if (-not $install) {
            throw "Missing build tools: $($missing -join ', '). Install them with the commands above, reopen PowerShell, then rerun this script."
        }
        foreach ($package in $packages) {
            & $winget.Source install --id $package --exact --source winget --accept-package-agreements --accept-source-agreements
            if ($LASTEXITCODE -ne 0) { throw "WinGet could not install $package (exit code $LASTEXITCODE)." }
        }
        Update-ArtTermSessionPath
        $missing = Get-ArtTermMissingBuildTools $Tools
        if ($missing) {
            throw "Installed, but $($missing -join ', ') is still not on PATH. Reopen PowerShell, then rerun this script."
        }
    }
    if ($RequireMsvcHost) {
        $rustHost = ((& rustc.exe -vV | Select-String '^host: ') -as [string]) -replace '^host: ', ''
        if ($rustHost -ne 'x86_64-pc-windows-msvc') {
            throw "Rust host is '$rustHost'; run 'rustup default stable-x86_64-pc-windows-msvc' and rerun this script."
        }
    }
    $versions = foreach ($tool in $Tools) {
        $version = (& $script:ArtTermBuildTools[$tool].Command --version 2>$null | Select-Object -First 1)
        if ($version -match "^$tool ") { $version } else { "$tool $version" }
    }
    Write-Host "Build tools: $($versions -join '; ')"
}
