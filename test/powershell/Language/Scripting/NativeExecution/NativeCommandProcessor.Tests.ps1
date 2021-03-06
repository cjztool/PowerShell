Describe 'native commands lifecycle' -tags 'Feature' {

    BeforeAll {
        $powershell = Join-Path -Path $PsHome -ChildPath "powershell"
    }

    #Marking this test as Pending due to issue # https://github.com/PowerShell/PowerShell/issues/2802
    It "native | ps | native doesn't block" -Pending {
        $first = $true
        & $powershell -command '1..10 | % {Start-Sleep -mill 100; $_}' | %{$_} | & $powershell -command '$input' | % {
            if ($first)
            {
                $first = $false
                $firstTime = [datetime]::Now
            }
            $lastTime = [datetime]::Now
        }

        $lastTime - $firstTime | Should BeGreaterThan ([timespan]::new(0, 0, 0, 0, 100)) # 100 milliseconds
    }
}

Describe "Native Command Processor" -tags "Feature" {

    BeforeAll {
        # Find where test/powershell is so we can find the createchildprocess command relative to it
        $powershellTestDir = $PSScriptRoot
        while ($powershellTestDir -notmatch 'test[\\/]powershell$') {
            $powershellTestDir = Split-Path $powershellTestDir
        }
        $createchildprocess = Join-Path (Split-Path $powershellTestDir) tools/CreateChildProcess/bin/createchildprocess
    }

    # If powershell receives a StopProcessing, it should kill the native process and all child processes

    # this test should pass and no longer Pending when #2561 is fixed
    It "Should kill native process tree" -Pending {

        # make sure no test processes are running
        # on Linux, the Process class truncates the name so filter using Where-Object
        Get-Process | Where-Object {$_.Name -like 'createchildproc*'} | Stop-Process
        
        [int] $numToCreate = 2

        $ps = [PowerShell]::Create().AddCommand($createchildprocess)
        $ps.AddParameter($numToCreate)
        $async = $ps.BeginInvoke()
        $ps.InvocationStateInfo.State | Should Be "Running"

        [bool] $childrenCreated = $false
        while (-not $childrenCreated)
        {
            $childprocesses = Get-Process | Where-Object {$_.Name -like 'createchildproc*'} 
            if ($childprocesses.count -eq $numToCreate+1)
            {
                $childrenCreated = $true
            }
        }

        $startTime = Get-Date
        $beginsync = $ps.BeginStop($null, $async)
        # wait no more than 5 secs for the processes to be terminated, otherwise test has failed
        while (((Get-Date) - $startTime).TotalSeconds -lt 5)
        {
            if (($childprocesses.hasexited -eq $true).count -eq $numToCreate+1)
            {
                break
            }
        }
        $childprocesses = Get-Process | Where-Object {$_.Name -like 'createchildproc*'}
        $count = $childprocesses.count 
        $childprocesses | Stop-Process
        $count | Should Be 0
    }

    It "Should not block running Windows executables" -Skip:(!$IsWindows -or !(Get-Command notepad.exe)) {
        function FindNewNotepad
        {
            Get-Process -Name notepad -ErrorAction Ignore | Where-Object { $_.Id -notin $dontKill }
        }

        # We need to kill the windows process we start and can't know the process id, so get a list of
        # notepad processes already running and don't kill any of those.
        $dontKill = Get-Process -Name notepad -ErrorAction Ignore | ForEach-Object { $_.Id }

        try
        {
            $ps = [powershell]::Create().AddScript('notepad.exe; "ran notepad"')
            $async = $ps.BeginInvoke()

            # Wait for up to 30 seconds for either the pipeline to finish (should mean the test succeeded) or
            # for a new instance of notepad to have started (which mean we're blocked)
            $counter = 0
            while (!$async.AsyncWaitHandle.WaitOne(10000) -and $counter -lt 3 -and !(FindNewNotepad))
            {
                $counter++
            }

            # Stop the new instance of notepad
            $newNotepad = FindNewNotepad
            $newNotepad | Should Not Be $null
            $newNotepad | Stop-Process

            $async.IsCompleted | Should Be $true
            $ps.EndInvoke($async) | Should Be "ran notepad"
        }
        finally
        {
            if (!$async.IsCompleted)
            {
                $ps.Stop()
            }
            $ps.Dispose()
        }
    }

}
