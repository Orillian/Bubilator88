param(
    [Parameter(Mandatory = $true)]
    [string]$ExePath
)

$ErrorActionPreference = 'Stop'
$exe = (Resolve-Path -LiteralPath $ExePath).Path
if (Get-Process Bubilator88 -ErrorAction SilentlyContinue) {
    throw 'Close Bubilator88 before running this check.'
}

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class SingleInstanceWindowCheck {
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
}
'@
Add-Type -AssemblyName System.Windows.Forms

function Start-TestApp {
    Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) -WindowStyle Hidden -PassThru
}

function Wait-TestWindow($process) {
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $process.Refresh()
        if ($process.HasExited) { throw "App exited before showing a window: $($process.ExitCode)" }
        if ($process.MainWindowHandle -ne [IntPtr]::Zero) { return }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'App did not show a window within 30 seconds.'
}

$started = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
$foreground = [System.Windows.Forms.Form]::new()
$foreground.Text = 'Bubilator88 launch test'
try {
    $foreground.Show()
    [System.Windows.Forms.Application]::DoEvents()
    $first = Start-TestApp
    $started.Add($first)
    Wait-TestWindow $first
    $window = $first.MainWindowHandle
    foreach ($minimized in @($false, $true)) {
        # Minimizing the first window returns focus to the previous window.
        [SingleInstanceWindowCheck]::ShowWindow($window, 6) | Out-Null
        if (-not $minimized) { [SingleInstanceWindowCheck]::ShowWindow($window, 4) | Out-Null }

        # Start the next process from the foreground, as when launched from Explorer.
        [SingleInstanceWindowCheck]::SetForegroundWindow($foreground.Handle) | Out-Null
        if ([SingleInstanceWindowCheck]::GetForegroundWindow() -ne $foreground.Handle) {
            Write-Host "Click the '$($foreground.Text)' window to continue."
            $deadline = [DateTime]::UtcNow.AddSeconds(15)
            while ([SingleInstanceWindowCheck]::GetForegroundWindow() -ne $foreground.Handle -and [DateTime]::UtcNow -lt $deadline) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 100
            }
        }
        if ([SingleInstanceWindowCheck]::GetForegroundWindow() -ne $foreground.Handle) {
            throw "The test window could not take focus (minimized: $minimized). Run this check from the active desktop."
        }
        $second = Start-TestApp
        $started.Add($second)
        if (-not $second.WaitForExit(15000)) { throw 'Second launch stayed running.' }
        if ($second.ExitCode -ne 0) { throw "Second launch failed: $($second.ExitCode)" }
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        while ([SingleInstanceWindowCheck]::GetForegroundWindow() -ne $window -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 100
        }
        if ([SingleInstanceWindowCheck]::GetForegroundWindow() -ne $window) { throw "Existing window did not take focus (minimized: $minimized)." }
        if ([SingleInstanceWindowCheck]::IsIconic($window)) { throw 'Existing window was not restored.' }
        if ($first.HasExited) { throw 'Original instance exited.' }
    }

    $first.CloseMainWindow() | Out-Null
    if (-not $first.WaitForExit(15000)) { throw 'Original instance did not close.' }
    $restarted = Start-TestApp
    $started.Add($restarted)
    Wait-TestWindow $restarted
    $restarted.CloseMainWindow() | Out-Null
    if (-not $restarted.WaitForExit(15000)) { throw 'Restarted instance did not close.' }

    # Race several cold launches, before any instance has finished creating its UI.
    $burst = @(1..4 | ForEach-Object {
        $process = Start-TestApp
        $started.Add($process)
        $process
    })
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 100
        $running = @($burst | Where-Object { -not $_.HasExited })
    } while ($running.Count -gt 1 -and [DateTime]::UtcNow -lt $deadline)
    if ($running.Count -ne 1) { throw "Concurrent launches left $($running.Count) running instances." }
    Wait-TestWindow $running[0]
    foreach ($process in $burst) {
        if ($process.HasExited -and $process.ExitCode -ne 0) { throw "Concurrent launch failed: $($process.ExitCode)" }
    }
    Write-Output 'PASS: duplicate launches foreground the existing window, concurrent launches leave one instance, and relaunch after closing succeeds.'
}
finally {
    $foreground.Dispose()
    foreach ($process in $started) {
        if (-not $process.HasExited) {
            $process.CloseMainWindow() | Out-Null
            if (-not $process.WaitForExit(5000)) { $process.Kill() }
        }
        $process.Dispose()
    }
}
