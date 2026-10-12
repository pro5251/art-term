param(
    [switch]$SkipBuild,
    [string]$ConfigPath = "$PSScriptRoot/../config/connections.example.toml",
    [string]$OutputPath
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$productVersion = (Get-Content -LiteralPath (Join-Path $projectRoot 'crates/art-term-gui/tauri.conf.json') -Raw | ConvertFrom-Json).version
$defaultOutput = -not $OutputPath
if ($defaultOutput) { $OutputPath = Join-Path $projectRoot "dist/windows/art-term-$productVersion" }
$packagePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
if ((Test-Path -LiteralPath $packagePath) -and -not (Test-Path -LiteralPath $packagePath -PathType Container)) {
    throw "OutputPath is not a directory: $packagePath"
}
$hasExistingPackage = $false
if (Test-Path -LiteralPath $packagePath) {
    $hasExistingPackage = [bool](Get-ChildItem -LiteralPath $packagePath -Force | Select-Object -First 1)
}
if ($hasExistingPackage -and -not $defaultOutput) {
    throw "OutputPath already contains files: $packagePath. Choose a new or empty directory."
}
$outputRoot = $packagePath
if ($hasExistingPackage) {
    $outputRoot = Join-Path (Split-Path -Parent $packagePath) ".$(Split-Path -Leaf $packagePath).staging-$([guid]::NewGuid().ToString('N'))"
    if (Test-Path -LiteralPath $outputRoot) { throw "Temporary package directory already exists: $outputRoot" }
}
. "$PSScriptRoot/build-paths.ps1"
function Get-VsInstallation {
    param([string]$Vswhere, [switch]$RequireCpp)
    if (-not (Test-Path -LiteralPath $Vswhere)) { return $null }
    $args = @('-latest', '-products', '*', '-property', 'installationPath')
    if ($RequireCpp) { $args += @('-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64') }
    $installation = & $Vswhere @args
    if (-not $installation) { $installation = & $Vswhere @args -prerelease }
    return $installation
}
function Invoke-VsInstaller {
    param([string]$Installation, [ValidateSet('modify', 'repair')][string]$Operation)
    $setup = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/setup.exe'
    if (-not (Test-Path -LiteralPath $setup)) { throw "Visual Studio Installer was not found at $setup." }
    $arguments = "$Operation --installPath `"$Installation`" --passive"
    if ($Operation -eq 'modify') {
        $arguments += ' --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
    }
    Write-Host "Visual Studio Installer: $Operation $Installation (administrator approval may be required)..."
    $result = Start-Process -FilePath $setup -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    if ($result.ExitCode -notin @(0, 3010)) { throw "Visual Studio Installer $Operation failed (exit code $($result.ExitCode))." }
}
function Install-MsvcBuildTools {
    param([string]$Vswhere)
    $existing = Get-VsInstallation -Vswhere $Vswhere
    if ($existing) {
        Write-Host "Adding the C++ workload and Windows SDK to $existing (administrator approval may be required)..."
        Invoke-VsInstaller -Installation $existing -Operation modify
    } else {
        $winget = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        Write-Host 'Installing Visual Studio Build Tools with the C++ workload and Windows SDK (administrator approval may be required)...'
        if ($winget) {
            & $winget.Source install --id Microsoft.VisualStudio.2022.BuildTools --exact --source winget --accept-package-agreements --accept-source-agreements --override '--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --passive --norestart --wait'
            if ($LASTEXITCODE -ne 0) { throw "Visual Studio Build Tools installation failed (exit code $LASTEXITCODE)." }
        } else {
            $bootstrapper = Join-Path $env:TEMP "art-term-vs-buildtools-$([guid]::NewGuid().ToString('N')).exe"
            try {
                Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vs_buildtools.exe' -OutFile $bootstrapper -UseBasicParsing
                $signature = Get-AuthenticodeSignature -LiteralPath $bootstrapper
                if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation') {
                    throw 'Downloaded Visual Studio Build Tools bootstrapper does not have a valid Microsoft signature.'
                }
                $arguments = '--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --passive --norestart --wait'
                $result = Start-Process -FilePath $bootstrapper -ArgumentList $arguments -Verb RunAs -Wait -PassThru
                if ($result.ExitCode -notin @(0, 3010)) { throw "Visual Studio Build Tools installation failed (exit code $($result.ExitCode))." }
            } finally {
                if (Test-Path -LiteralPath $bootstrapper) { Remove-Item -LiteralPath $bootstrapper -Force }
            }
        }
    }
}
function Initialize-MsvcBuildEnvironment {
    $linkerOverride = [Environment]::GetEnvironmentVariable('CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER')
    # Respect an explicitly configured Cargo linker and toolchain environment.
    if ($linkerOverride) { return }
    $linker = Get-Command link.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($linker -and $env:VSCMD_VER -and $env:WindowsSdkDir -and
        (Get-Item -LiteralPath $linker.Source).VersionInfo.CompanyName -match '^Microsoft') { return }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $installation = Get-VsInstallation -Vswhere $vswhere -RequireCpp
    if (-not $installation) {
        Install-MsvcBuildTools -Vswhere $vswhere
        $installation = Get-VsInstallation -Vswhere $vswhere -RequireCpp
        if (-not $installation) { throw 'Visual Studio C++ tools are still unavailable after installation. Check Visual Studio Installer logs.' }
    }
    $devShell = Join-Path $installation 'Common7/Tools/Launch-VsDevShell.ps1'
    if (-not (Test-Path -LiteralPath $devShell)) {
        Invoke-VsInstaller -Installation $installation -Operation repair
        if (-not (Test-Path -LiteralPath $devShell)) {
            throw "Visual Studio Developer PowerShell is still missing at $devShell after repair. Check Visual Studio Installer logs."
        }
    }
    & $devShell -Arch amd64 -HostArch amd64 -SkipAutomaticLocation | Out-Null
    $linker = Get-Command link.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $linker -or (Get-Item -LiteralPath $linker.Source).VersionInfo.CompanyName -notmatch '^Microsoft') {
        $found = if ($linker) { $linker.Source } else { '(none)' }
        throw "Visual Studio environment did not select the Microsoft linker; first link.exe: $found. Check the C++ build tools installation and PATH."
    }
    if (-not $env:WindowsSdkDir) {
        Invoke-VsInstaller -Installation $installation -Operation modify
        & $devShell -Arch amd64 -HostArch amd64 -SkipAutomaticLocation | Out-Null
        if (-not $env:WindowsSdkDir) { throw 'Windows SDK is still unavailable after installation. Check Visual Studio Installer logs.' }
    }
}
$previousRustFlags = $env:CARGO_ENCODED_RUSTFLAGS
$previousConfig = $env:ART_TERM_CONNECTIONS_FILE
$env:CARGO_ENCODED_RUSTFLAGS = Get-ArtTermBuildRustFlags -ProjectRoot $projectRoot
$env:ART_TERM_CONNECTIONS_FILE = $ConfigPath
try {
    if (-not $SkipBuild) {
        Initialize-MsvcBuildEnvironment
        Push-Location (Join-Path $projectRoot 'apps/desktop')
        try {
            & npm.cmd ci
            if ($LASTEXITCODE -ne 0) { throw 'npm ci failed' }
            & npm.cmd run build
            if ($LASTEXITCODE -ne 0) { throw 'Frontend build failed' }
        } finally { Pop-Location }
        Push-Location $projectRoot
        try {
            & cargo build -p art-term-gui --release --locked
            if ($LASTEXITCODE -ne 0) { throw 'GUI build failed' }
        } finally { Pop-Location }
    }
    New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
    Copy-Item -LiteralPath (Join-Path $projectRoot 'target/release/art-term-gui.exe') -Destination (Join-Path $outputRoot 'art-term-gui.exe')
    Copy-Item -LiteralPath $ConfigPath -Destination (Join-Path $outputRoot 'connections.toml')
    Copy-Item -LiteralPath (Join-Path $projectRoot 'LICENSE') -Destination (Join-Path $outputRoot 'LICENSE')
    Copy-Item -LiteralPath (Join-Path $projectRoot 'docs/third-party-notices.md') -Destination (Join-Path $outputRoot 'THIRD-PARTY-NOTICES.md')
    $instructions = @(
        '# art-term Windows', '',
        '需要 Windows 10 1809 以上、WebView2 Runtime 與可達 Runtime Host 的網路。',
        '開啟 art-term-gui.exe，按「新增 openab-pty 連線」選擇 Host／Agent 分類，填入可信 HTTPS 根網址與管理憑證。',
        '點名稱開啟 Shell；右側「Shell」可列出、選擇或建立工作。', '',
        '程式旁 connections.toml 是唯一連線來源；不存在、空白或 connections = [] 時顯示空清單，可直接新增或匯入。',
        '新增、編輯、刪除及匯入皆寫回同一份 TOML（schema_version=5）；管理憑證以目前 Windows 使用者 DPAPI 保護後保存，沒有明文憑證。',
        '換裝置：在「管理」多選匯出連線，含憑證時用密碼加密；自行搬移檔案後，在新裝置選檔解鎖並勾選匯入。',
        '相同網址預設略過，明確勾選才更新；不含憑證的 JSON 在新裝置需逐筆補入管理憑證。',
        '修改設定後重啟；覆寫路徑：art-term-gui.exe --config C:/path/connections.toml。',
        '不讀取使用者目錄中的舊 runtime-hosts-v1.json；舊版本連線需先在舊 App 匯出，再於新版匯入。',
        '請將整包放在可寫目錄；手動修改或刪除 TOML 前先關閉 App。刪除後重開為空清單，舊檔與金鑰不會自動移除。',
        'Android 同樣使用裝置內唯一 connections.toml；首次使用可新增或匯入，APK 不嵌入預設連線。',
        '桌面沿用既有管理憑證，由 App 建立專用截圖 Shell 呼叫 Host helper，圖片經原 Runtime 連線回傳；不會把截圖指令送進工作 Shell。',
        '整個交付資料夾一起搬移，請保留設定與授權檔案。',
        '關分頁只本機脫離；遠端 Shell 仍受 TTL 及 runtime 生命週期限制。'
    )
    Set-Content -LiteralPath (Join-Path $outputRoot 'README.md') -Value $instructions -Encoding UTF8
    $manifest = foreach ($name in @('art-term-gui.exe','connections.toml','README.md','LICENSE','THIRD-PARTY-NOTICES.md')) {
        $path = Join-Path $outputRoot $name
        [ordered]@{file=$name;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant();bytes=(Get-Item -LiteralPath $path).Length}
    }
    [ordered]@{platform='windows-x64';version=$productVersion;configuration_sha256=(Get-FileHash -LiteralPath (Join-Path $outputRoot 'connections.toml')).Hash.ToLowerInvariant();build=if($SkipBuild){'existing binary; verify source separately'}else{'cargo build -p art-term-gui --release --locked'};files=@($manifest)} |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $outputRoot 'manifest.json') -Encoding UTF8
    if ($hasExistingPackage) {
        $packageParent = Split-Path -Parent $packagePath
        $backupRoot = Join-Path $packageParent '.previous'
        New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
        $backupName = "$(Split-Path -Leaf $packagePath)-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        $backupPath = Join-Path $backupRoot $backupName
        $suffix = 2
        while (Test-Path -LiteralPath $backupPath) {
            $backupPath = Join-Path $backupRoot "$backupName-$suffix"
            $suffix++
        }
        # Keep every directory move inside the package parent.
        $parentPrefix = [IO.Path]::GetFullPath($packageParent).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        foreach ($path in @($packagePath, $outputRoot, $backupPath)) {
            if (-not [IO.Path]::GetFullPath($path).StartsWith($parentPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw ('Package path is outside {0}: {1}' -f $packageParent, $path)
            }
        }
        foreach ($directory in @($packageParent, $backupRoot)) {
            if ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Refusing to move a package through a directory link: $directory"
            }
        }
        if ((Get-Item -LiteralPath $packagePath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Refusing to move a package directory link: $packagePath"
        }
        Move-Item -LiteralPath $packagePath -Destination $backupPath
        try {
            if (Test-Path -LiteralPath $packagePath) { throw "Package destination is occupied: $packagePath" }
            Move-Item -LiteralPath $outputRoot -Destination $packagePath
        } catch {
            $publishError = $_
            if (Test-Path -LiteralPath $packagePath) {
                throw "Publishing failed: $publishError. Previous package remains at $backupPath; destination is occupied."
            }
            try {
                Move-Item -LiteralPath $backupPath -Destination $packagePath
            } catch {
                throw "Publishing failed: $publishError. Previous package remains at $backupPath; restore it manually."
            }
            throw $publishError
        }
        Write-Output "Previous Windows package: $backupPath"
    }
    Write-Output "Windows package: $packagePath"
} finally {
    $env:ART_TERM_CONNECTIONS_FILE = $previousConfig
    $env:CARGO_ENCODED_RUSTFLAGS = $previousRustFlags
}
