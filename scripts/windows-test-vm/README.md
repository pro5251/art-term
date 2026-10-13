# 乾淨 Windows 測試 VM

此目錄的 [windows-test-vm.ps1](windows-test-vm.ps1) 在 Hyper-V 建立一台**未安裝 Visual Studio／C++ Build Tools** 的 Windows VM，用來驗證 `package-windows.ps1` 首次安裝工具鏈及打包的流程。同一支腳本可建立基準檢查點並還原，讓每次測試都從相同狀態開始。

## 準備

- 主機：已啟用 Hyper-V 的 Windows 11 Pro／Enterprise，並以**系統管理員 PowerShell**執行腳本。
- 取得 [Microsoft Windows 11 x64 ISO](https://www.microsoft.com/software-download/windows11)，記下本機檔案路徑。
- Hyper-V 中已有可上網的虛擬交換器；預設使用 `Default Switch`。若名稱不同，建立時傳入 `-SwitchName`。
- 預留至少 100 GB 的磁碟配置空間及 8 GB 可用記憶體。VHDX 按使用量擴充，不會一開始佔滿 100 GB。

從 **repo 根目錄**執行以下命令。腳本只在 `-Action Create` 時建立 VM，不會修改或移除現有 VM；同名 VM 或非空目標目錄會直接報錯。

## 1. 建立 VM 並安裝 Windows

```powershell
.\scripts\windows-test-vm\windows-test-vm.ps1 -Action Create -IsoPath 'D:\ISO\Win11.iso'
```

腳本會建立名為 `art-term-clean-windows` 的 Hyper-V 第 2 代 VM，配置 8 GB RAM、4 核心、100 GB 虛擬磁碟、Secure Boot 與 vTPM，掛載 ISO，然後開啟 VMConnect。在 VMConnect 按「啟動」，依 Windows 安裝畫面完成安裝並建立可登入的帳號。**此步仍需在 VM 畫面操作**；腳本不會自動安裝 Windows 或啟動主機上的 Visual Studio。

需要指定主機儲存路徑或交換器時，例如：

```powershell
.\scripts\windows-test-vm\windows-test-vm.ps1 -Action Create -IsoPath 'D:\ISO\Win11.iso' -VmRoot 'D:\HyperV-TestVMs' -SwitchName 'Default Switch'
```

可另外指定 `-VmName`、`-MemoryGB`、`-DiskGB`、`-Cores`；`-NoConsole` 會略過開啟 VMConnect。若沒有 `Default Switch`，腳本會列出可用交換器名稱，不會自行更動主機網路。

## 2. 在 VM 內安裝測試前置工具

登入 **VM 內**的 PowerShell，安裝 Git、Node.js LTS 與 Rustup。此時**不要**安裝 Visual Studio、Build Tools 或 C++ 工作負載，否則無法測試打包腳本的首次安裝分支。

```powershell
winget install --id Git.Git --exact --source winget --accept-package-agreements --accept-source-agreements
winget install --id OpenJS.NodeJS.LTS --exact --source winget --accept-package-agreements --accept-source-agreements
winget install --id Rustlang.Rustup --exact --source winget --accept-package-agreements --accept-source-agreements
```

重新開啟 **VM 內**的 PowerShell，設定 Rust MSVC 工具鏈並檢查命令：

```powershell
rustup default stable-x86_64-pc-windows-msvc
rustc -vV
git --version
node --version
npm.cmd --version
cargo --version
```

`rustc -vV` 應顯示 `host: x86_64-pc-windows-msvc`。若 VM 沒有 WinGet，可從 [Git](https://git-scm.com/download/win)、[Node.js](https://nodejs.org/en/download)及 [Rustup](https://rustup.rs/) 的官方頁面安裝，再執行上面的 Rust 設定與檢查。

## 3. 建立未安裝 Visual Studio 的基準點

回到**主機的系統管理員 PowerShell**，從 repo 根目錄執行：

```powershell
.\scripts\windows-test-vm\windows-test-vm.ps1 -Action Checkpoint
```

輸入 **VM 內 Windows 帳號的密碼**。腳本透過 PowerShell Direct 檢查 VM 已啟動、Git／Node／npm／cargo／rustc 可執行、Rust host 為 x64 MSVC，並確認沒有 Visual Studio／Build Tools。通過後才建立 `before-visual-studio-buildtools` 檢查點；驗證失敗時不建立檢查點。PowerShell Direct 使用 VM 帳號，不需要為 VM 啟用 WinRM 或設定網路連線。

## 4. 在 VM 內驗證打包

回到 **VM 內**，先切到使用者目錄，再取得包含自動安裝修正的分支並執行打包。系統管理員 PowerShell 預設位於 `C:\Windows\System32`，直接 clone 會因無寫入權限失敗：

```powershell
Set-Location $HOME
git clone --branch feature/windows-clean-vm-test https://github.com/pro5251/art-term.git
Set-Location art-term
.\scripts\package-windows.ps1
```

第一次執行應由打包腳本安裝 Visual Studio C++ Build Tools／Windows SDK、載入 MSVC 環境，再完成前端及 Rust 建置。檢查 `dist/windows/` 是否產生 EXE、`connections.toml` 和 `manifest.json`。安裝需要網路及管理員授權；若安裝程式要求重新開機，請在 VM 內重新開機後重跑打包。

## 5. 還原並重測

每次想重新驗證「首次安裝」時，在**主機**執行：

```powershell
.\scripts\windows-test-vm\windows-test-vm.ps1 -Action Restore
```

還原會**捨棄 VM 在檢查點之後的所有變更**，包括剛安裝的 Build Tools 與 repo checkout；主機檔案不受影響。之後重做第 4 步即可。若自訂 VM 名稱或檢查點名稱，後續命令需傳入相同的 `-VmName`／`-CheckpointName`。

## 常見問題

- `Run as administrator`：目前主機 PowerShell 沒有管理 Hyper-V 的權限；請用系統管理員 PowerShell 重跑。
- `Default Switch was not found`：執行 `Get-VMSwitch`，用現有可上網的交換器名稱傳入 `-SwitchName`。
- `Checkpoint` 無法連入 VM：確認 VM 已啟動、Windows 安裝完成，並使用 VM 內帳號的**密碼**登入 PowerShell Direct。
- `could not create work tree dir 'art-term': Permission denied`：目前目錄沒有寫入權限，常見於系統管理員 PowerShell 的預設位置 `C:\Windows\System32`。用 `Get-Location` 確認後，`Set-Location $HOME` 再 clone；不要為此修改系統目錄權限。若 `art-term` 已存在且由其他帳號建立，刪除後重新 clone。
- `Missing build tools`：打包腳本在建置前檢查 `node`、`npm.cmd`、`cargo`、`rustc`，並會先重新讀取系統 PATH（涵蓋剛用 WinGet 安裝但未重開的視窗）。仍找不到時依訊息中的 `winget install` 安裝，重開 PowerShell 後重跑。`Rust host is ...` 表示不是 MSVC 工具鏈，執行 `rustup default stable-x86_64-pc-windows-msvc`。
- `Checkpoint` 報告已有 Visual Studio：這台 VM 已不符合乾淨基準；請使用新的 VM，或回到更早的檢查點。

參考：[Hyper-V PowerShell 建立 VM](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/powershell)、[PowerShell Direct](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/powershell-direct)、[檢查點](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/checkpoints)。
