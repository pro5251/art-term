<#
.SYNOPSIS
Creates a disposable Hyper-V Windows test VM and manages its clean baseline.

.EXAMPLE
.\scripts\windows-test-vm\windows-test-vm.ps1 -Action Create -IsoPath 'D:\ISO\Win11.iso'
.\scripts\windows-test-vm\windows-test-vm.ps1 -Action Checkpoint
.\scripts\windows-test-vm\windows-test-vm.ps1 -Action Restore
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Create', 'Checkpoint', 'Restore')]
    [string]$Action = 'Create',
    [ValidateNotNullOrEmpty()] [string]$VmName = 'art-term-clean-windows',
    [string]$IsoPath,
    [ValidateNotNullOrEmpty()] [string]$VmRoot = (Join-Path $env:PUBLIC 'Documents\Hyper-V-TestVMs'),
    [ValidateNotNullOrEmpty()] [string]$SwitchName = 'Default Switch',
    [ValidateRange(4, 1024)] [int]$MemoryGB = 8,
    [ValidateRange(64, 4096)] [int]$DiskGB = 100,
    [ValidateRange(2, 128)] [int]$Cores = 4,
    [ValidateNotNullOrEmpty()] [string]$CheckpointName = 'before-visual-studio-buildtools',
    [pscredential]$GuestCredential,
    [switch]$NoConsole
)
$ErrorActionPreference = 'Stop'

if (-not [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell window (Run as administrator).'
}
Import-Module Hyper-V -ErrorAction Stop
if ($VmName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
    throw 'VmName contains characters that cannot be used in a Windows folder name.'
}

switch ($Action) {
    'Create' {
        if (-not $IsoPath) { throw 'Provide a Windows 11 x64 ISO with -IsoPath.' }
        $iso = (Resolve-Path -LiteralPath $IsoPath -ErrorAction Stop).Path
        if ([IO.Path]::GetExtension($iso) -ine '.iso' -or -not (Test-Path -LiteralPath $iso -PathType Leaf)) {
            throw "IsoPath must point to an existing .iso file: $iso"
        }
        if (Get-VM -Name $VmName -ErrorAction SilentlyContinue) { throw "VM already exists: $VmName" }
        $vmDirectory = Join-Path ([IO.Path]::GetFullPath($VmRoot)) $VmName
        if ((Test-Path -LiteralPath $vmDirectory) -and (Get-ChildItem -LiteralPath $vmDirectory -Force | Select-Object -First 1)) {
            throw "VM directory is not empty: $vmDirectory"
        }
        if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
            $available = (Get-VMSwitch | Select-Object -ExpandProperty Name) -join ', '
            throw "Virtual switch '$SwitchName' was not found. Use -SwitchName with an existing switch. Available: $available"
        }
        if ($PSCmdlet.ShouldProcess($VmName, "Create Generation 2 VM in $vmDirectory")) {
            New-Item -ItemType Directory -Path $vmDirectory -Force | Out-Null
            $disk = Join-Path $vmDirectory 'system.vhdx'
            New-VM -Name $VmName -Generation 2 -Path $vmDirectory -MemoryStartupBytes ([int64]$MemoryGB * 1GB) `
                -NewVHDPath $disk -NewVHDSizeBytes ([int64]$DiskGB * 1GB) -SwitchName $SwitchName | Out-Null
            Set-VMProcessor -VMName $VmName -Count $Cores
            Set-VM -Name $VmName -AutomaticCheckpointsEnabled $false -CheckpointType ProductionOnly
            Set-VMFirmware -VMName $VmName -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
            Set-VMKeyProtector -VMName $VmName -NewLocalKeyProtector
            Enable-VMTPM -VMName $VmName
            $dvd = Add-VMDvdDrive -VMName $VmName -Path $iso -Passthru
            Set-VMFirmware -VMName $VmName -FirstBootDevice $dvd
            Write-Host "Created $VmName at $vmDirectory."
            if (-not $NoConsole) {
                Start-Process -FilePath (Join-Path $env:WINDIR 'System32\vmconnect.exe') -ArgumentList "localhost `"$VmName`""
            }
            Write-Host 'Start the VM in VMConnect, install Windows, then install Git, Node.js LTS and Rust MSVC inside the guest.'
            Write-Host "Before installing Visual Studio or Build Tools, run: .\scripts\windows-test-vm\windows-test-vm.ps1 -Action Checkpoint -VmName '$VmName'"
        }
    }
    'Checkpoint' {
        $vm = Get-VM -Name $VmName -ErrorAction Stop
        if ($vm.State -ne 'Running') { throw 'Start the VM and finish Windows setup before creating the baseline.' }
        if (Get-VMCheckpoint -VMName $VmName -Name $CheckpointName -ErrorAction SilentlyContinue) {
            throw "Checkpoint already exists: $CheckpointName"
        }
        if (-not $GuestCredential) { $GuestCredential = Get-Credential -Message "Administrator account inside VM '$VmName'" }
        $guest = Invoke-Command -VMName $VmName -Credential $GuestCredential -ScriptBlock {
            $missing = @()
            foreach ($tool in @('git.exe', 'node.exe', 'npm.cmd', 'cargo.exe', 'rustc.exe')) {
                if (-not (Get-Command $tool -CommandType Application -ErrorAction SilentlyContinue)) { $missing += $tool }
            }
            $rustHost = if ($missing -notcontains 'rustc.exe') { (& rustc.exe -vV | Select-String '^host: (.+)$').Matches.Groups[1].Value } else { '' }
            if ($rustHost -ne 'x86_64-pc-windows-msvc') { $missing += 'Rust x86_64-pc-windows-msvc host' }
            $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
            $visualStudio = if (Test-Path -LiteralPath $vswhere) { @(& $vswhere -all -products '*' -property installationPath) } else { @() }
            foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
                $vsRoot = Join-Path $root 'Microsoft Visual Studio'
                if (Test-Path -LiteralPath $vsRoot) {
                    $visualStudio += @(Get-ChildItem -LiteralPath $vsRoot -Directory -ErrorAction SilentlyContinue |
                        Where-Object Name -ne 'Installer' | Select-Object -ExpandProperty FullName)
                }
            }
            $visualStudio = @($visualStudio | Sort-Object -Unique)
            [pscustomobject]@{ Missing = $missing; VisualStudio = $visualStudio }
        }
        if ($guest.VisualStudio.Count -gt 0) { throw "The guest already has Visual Studio/Build Tools: $($guest.VisualStudio -join ', ')" }
        if ($guest.Missing.Count -gt 0) { throw "Install these inside the guest before checkpointing: $($guest.Missing -join ', ')" }
        if ($PSCmdlet.ShouldProcess($VmName, "Create clean checkpoint '$CheckpointName'")) {
            Checkpoint-VM -VMName $VmName -SnapshotName $CheckpointName
            Write-Host "Created checkpoint '$CheckpointName'. Run package-windows.ps1 inside the VM, then use -Action Restore to repeat."
        }
    }
    'Restore' {
        Get-VM -Name $VmName -ErrorAction Stop | Out-Null
        if (-not (Get-VMCheckpoint -VMName $VmName -Name $CheckpointName -ErrorAction SilentlyContinue)) {
            throw "Checkpoint was not found: $CheckpointName"
        }
        if ($PSCmdlet.ShouldProcess($VmName, "Discard guest changes and restore checkpoint '$CheckpointName'")) {
            Restore-VMCheckpoint -VMName $VmName -Name $CheckpointName -Confirm:$false
            Write-Host "Restored '$CheckpointName'."
        }
    }
}
