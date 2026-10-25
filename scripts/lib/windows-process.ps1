# Match the complete Windows argument vector, including quoted paths and empty
# arguments. Substring matching a configuration path can select another tunnel.
if (-not ('RemoteEverything.ProcessCommandLine' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace RemoteEverything {
    public static class ProcessCommandLine {
        [DllImport("shell32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern IntPtr CommandLineToArgvW(string commandLine, out int count);
        [DllImport("kernel32.dll")]
        static extern IntPtr LocalFree(IntPtr memory);
        public static string[] Parse(string commandLine) {
            int count;
            IntPtr memory = CommandLineToArgvW(commandLine, out count);
            if (memory == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
            try {
                var result = new string[count];
                for (int i = 0; i < count; i++)
                    result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(memory, i * IntPtr.Size));
                return result;
            } finally { LocalFree(memory); }
        }
    }
}
'@
}

function Test-ComponentProcess($Process, $Component) {
    if (-not $Process.ExecutablePath -or -not $Process.CommandLine) { return $false }
    if (-not [string]::Equals($Process.ExecutablePath, $Component.executable, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $argv = [RemoteEverything.ProcessCommandLine]::Parse($Process.CommandLine)
    if ($argv.Count -ne $Component.arguments.Count + 1) { return $false }
    for ($index = 0; $index -lt $Component.arguments.Count; $index++) {
        if (-not [string]::Equals($argv[$index + 1], $Component.arguments[$index], [StringComparison]::Ordinal)) { return $false }
    }
    return $true
}

function Get-ComponentProcess($Component) {
    Get-CimInstance Win32_Process | Where-Object { Test-ComponentProcess $_ $Component }
}

function Stop-ComponentProcess($Snapshot, $Component) {
    $current = Get-CimInstance Win32_Process -Filter "ProcessId=$($Snapshot.ProcessId)"
    if (-not $current) { return }
    if ($current.CreationDate -ne $Snapshot.CreationDate -or -not (Test-ComponentProcess $current $Component)) {
        throw "Process identity changed for PID $($Snapshot.ProcessId); refusing to stop it."
    }
    $process = Get-Process -Id $current.ProcessId -ErrorAction SilentlyContinue
    if (-not $process) { return }
    try {
        # Opening the process handle before killing also closes the PID reuse race.
        # CIM timestamps have microsecond precision; Process.StartTime retains
        # 100 ns ticks. Compare at the precision provided by the snapshot.
        if ($process.StartTime.ToUniversalTime().ToString('yyyyMMddHHmmssffffff') -cne
            $current.CreationDate.ToUniversalTime().ToString('yyyyMMddHHmmssffffff')) {
            throw "Process start time changed for PID $($current.ProcessId); refusing to stop it."
        }
        $process.Kill()
        if (-not $process.WaitForExit(10000)) { throw "Process $($current.ProcessId) did not stop." }
    } finally { $process.Dispose() }
}
