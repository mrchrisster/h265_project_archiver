# ============================================
# Full Script: Source Files Pre-Check, Recovery, Processing,
# Auto-Restoration, Watch Folder Setup, Space Check, and AME Restart
# ============================================

# ----- User-Defined Defaults -----
$PredefinedSourceFolder = ""     # Ensure trailing backslash
$PredefinedWatchFolder  = ""     # Leave empty to auto-set (default: same drive as source)
$PredefinedBackupDrive  = ""     # Leave empty to auto-set (default: same drive as source)

# ----- Helper Functions -----

# Converts a byte value into a human-readable string (GB/MB)
function Convert-BytesToReadableSize {
    param (
        [Parameter(Mandatory = $true)]
        [long]$bytes
    )
    if ($bytes -ge 1GB) {
        return "{0:N2} GB" -f ($bytes / 1GB)
    } elseif ($bytes -ge 1MB) {
        return "{0:N2} MB" -f ($bytes / 1MB)
    } else {
        return "$bytes bytes"
    }
}

# Checks whether a file’s size remains stable over a short delay.
function Test-FileStability {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [int]$DelaySeconds = 3
    )
    try {
        if (-not (Test-Path $FilePath)) {
            return $false
        }
        $firstSize = (Get-Item $FilePath).Length
        Start-Sleep -Seconds $DelaySeconds
        if (-not (Test-Path $FilePath)) {
            return $false
        }
        $secondSize = (Get-Item $FilePath).Length
        return $firstSize -eq $secondSize
    } catch {
        return $false
    }
}

# Checks if a file is locked by attempting an exclusive open.
function IsFileLocked {
    param (
        [Parameter(Mandatory = $true)]
        [string]$File
    )
    try {
        $stream = [System.IO.File]::Open($File, 'Open', 'ReadWrite', 'None')
        $stream.Close()
        return $false
    } catch {
        return $true
    }
}

# Moves a file with a retry loop. Before moving, it checks that the file is not locked
# and that its size is stable. Diagnostic logging prints the file size and last-write time on each attempt.
function Move-FileWithRetry {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Source,
        [Parameter(Mandatory = $true)]
        [string]$Destination,
        [int]$RetryCount = 50,
        [int]$DelaySeconds = 5
    )
    for ($i = 0; $i -lt $RetryCount; $i++) {
        if (Test-Path $Source) {
            $fileItem = Get-Item $Source
            $currentSize = $fileItem.Length
            $lastWriteTime = $fileItem.LastWriteTime
            Write-Host "Attempt $($i+1): File '$Source' exists with size $currentSize bytes, LastWriteTime: $lastWriteTime" -ForegroundColor Gray
        } else {
            Write-Host "Attempt $($i+1): File '$Source' no longer exists." -ForegroundColor Red
            return $false
        }
        if ((IsFileLocked -File $Source) -or (-not (Test-FileStability -FilePath $Source -DelaySeconds 2))) {
            Write-Host "Attempt $($i + 1) of ${RetryCount}: File '$Source' is locked or unstable." -ForegroundColor Yellow
        } else {
            try {
                Move-Item -Path $Source -Destination $Destination -Force -ErrorAction Stop
                Write-Host "Successfully moved file from '$Source' to '$Destination'." -ForegroundColor Green
                return $true
            } catch {
                Write-Host "Attempt $($i + 1) of ${RetryCount}: Could not move file '$Source' to '$Destination': $_" -ForegroundColor Yellow
            }
        }
        Start-Sleep -Seconds $DelaySeconds
    }
    Write-Host "Failed to move file '$Source' after ${RetryCount} attempts. Continuing script execution." -ForegroundColor Red
    return $false
}

# Computes the expected backup target path for a given file.
# For video files (determined by the provided extensions), the extension is changed to .mp4.
function Get-ExpectedTarget {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File,
        [Parameter(Mandatory = $true)]
        [string]$SourceFolder,
        [Parameter(Mandatory = $true)]
        [string]$DestFolder,
        [Parameter(Mandatory = $true)]
        [string[]]$VideoExtensions
    )
    $relativePath = $File.FullName.Substring($SourceFolder.Length)
    if ($VideoExtensions -contains $File.Extension.ToLower().Trim()) {
        $relativePath = [System.IO.Path]::ChangeExtension($relativePath, ".mp4")
    }
    return Join-Path $DestFolder $relativePath
}

# Restarts Adobe Media Encoder (AME). Stops running processes and starts the latest installed version.
function Restart-AME {
    $ameProcesses = Get-Process "Adobe Media Encoder" -ErrorAction SilentlyContinue
    if ($ameProcesses) {
        Write-Host "Stopping Adobe Media Encoder..." -ForegroundColor Cyan
        $ameProcesses | Stop-Process -Force
        Start-Sleep -Seconds 5
    }
    $ameBasePath = "C:\Program Files\Adobe"
    $ameFolders = Get-ChildItem $ameBasePath -Directory | Where-Object {
        $_.Name -match "^Adobe Media Encoder\s+(\d+)" -and $_.Name -notmatch "beta"
    }
    if ($ameFolders.Count -eq 0) {
        Write-Host "No Adobe Media Encoder installation found in $ameBasePath" -ForegroundColor Red
        return
    }
    $latestAME = $ameFolders | Sort-Object { [int]($_.Name -replace "[^\d]", "") } -Descending | Select-Object -First 1
    $ameExePath = Join-Path $latestAME.FullName "Adobe Media Encoder.exe"
    if (Test-Path $ameExePath) {
        Write-Host "Starting Adobe Media Encoder from: $ameExePath" -ForegroundColor Green
        Start-Process $ameExePath
    } else {
        Write-Host "Executable not found at $ameExePath" -ForegroundColor Red
    }
}

# Removes empty directories recursively (deepest directories first).
function Remove-EmptyDirectories {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    $dirs = Get-ChildItem -Path $Path -Directory -Recurse -Force | Sort-Object { $_.FullName.Length } -Descending
    foreach ($dir in $dirs) {
        $items = Get-ChildItem -Path $dir.FullName -Force
        if ($items.Count -eq 0) {
            try {
                Remove-Item -Path $dir.FullName -Recurse -Force -ErrorAction Stop
                Write-Host "Removed empty folder: $($dir.FullName)" -ForegroundColor Green
            } catch {
                Write-Host "Failed to remove folder: $($dir.FullName). Error: $_" -ForegroundColor Red
            }
        }
    }
}

# Removes empty subfolders from the source folder after move operations.
function Remove-EmptySourceDirectories {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath
    )
    $dirs = Get-ChildItem -Path $SourcePath -Directory -Recurse -Force | Sort-Object { $_.FullName.Length } -Descending
    foreach ($dir in $dirs) {
        $items = Get-ChildItem -Path $dir.FullName -Force
        if ($items.Count -eq 0) {
            try {
                Remove-Item -Path $dir.FullName -Recurse -Force -ErrorAction Stop
                Write-Host "Removed empty subfolder: $($dir.FullName)" -ForegroundColor Green
            } catch {
                Write-Host "Failed to remove folder: $($dir.FullName). Error: $_" -ForegroundColor Red
            }
        }
    }
}

# ------------------------------------------
# 1. Source Files Setup and Pre-Check
# ------------------------------------------
if (-not [string]::IsNullOrEmpty($PredefinedSourceFolder)) {
    $sourceFolder = $PredefinedSourceFolder
} else {
    Add-Type -AssemblyName System.Windows.Forms
    $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderBrowser.Description = "Select the Source Folder"
    if ($folderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $sourceFolder = $folderBrowser.SelectedPath + "\"
    } else {
        Write-Host "No folder selected. Exiting." -ForegroundColor Red
        exit
    }
}
$sourceFilesPath = Join-Path $sourceFolder "source_files.json"

# Generate the source files list excluding files whose base name ends with "_proxy"
if (Test-Path $sourceFilesPath) {
    Write-Host "Loading source files list from '$sourceFilesPath'..." -ForegroundColor Cyan
    $sourceFilesList = Get-Content $sourceFilesPath -Raw | ConvertFrom-Json
} else {
    Write-Host "Source files list not found. Generating source files list..." -ForegroundColor Cyan
    $sourceFilesList = Get-ChildItem -Path $sourceFolder -Recurse -File |
        Where-Object { -not ($_.BaseName -like "*_proxy") } |
        ForEach-Object {
            @{ "RelativePath" = $_.FullName.Substring($sourceFolder.Length) }
        }
    $sourceFilesList | ConvertTo-Json | Out-File $sourceFilesPath
    Write-Host "Source files list generated and saved to '$sourceFilesPath'." -ForegroundColor Green
}

$sourceFileNames = $sourceFilesList | ForEach-Object { [System.IO.Path]::GetFileName($_.RelativePath) } | Sort-Object -Unique

# ------------------------------------------
# 2. Pre-Check: Ensure No Source File Is Already in the Watch Folder
# ------------------------------------------
$defaultWatchFolder = ("$($sourceFolder.Substring(0,1)):\watch_folder")
if (-not [string]::IsNullOrEmpty($PredefinedWatchFolder)) {
    $watchFolder = $PredefinedWatchFolder
} else {
    $watchFolder = $defaultWatchFolder
}
$watchFolderOutput = Join-Path $watchFolder "output"

# Clean up any empty subfolders under the "source" area of the watch folder.
$watchFolderSourceRoot = Join-Path $watchFolder "source"
if (Test-Path $watchFolderSourceRoot) {
    Get-ChildItem -Path $watchFolderSourceRoot -Directory -Recurse -Force | ForEach-Object {
        if ((Get-ChildItem -Path $_.FullName -File -Recurse -Force -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "Removed empty folder: $($_.FullName)" -ForegroundColor Green
        }
    }
}

# Move any source file that is in the watch folder (by file name) back to its source location.
# Exclude any files whose base name ends with "_proxy".
$watchFolderSourceFiles = Get-ChildItem -Path $watchFolder -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notlike ("$watchFolderOutput\*") -and -not ($_.BaseName -like "*_proxy") }
foreach ($wf in $watchFolderSourceFiles) {
    if ($sourceFileNames -contains $wf.Name) {
        Write-Host "Found file '$($wf.Name)' in watch folder; moving it back to source..." -ForegroundColor Yellow
        $sourceEntry = $sourceFilesList | Where-Object { [System.IO.Path]::GetFileName($_.RelativePath) -eq $wf.Name } | Select-Object -First 1
        if ($null -ne $sourceEntry) {
            $destinationPath = Join-Path $sourceFolder $sourceEntry.RelativePath
            $destinationDir = Split-Path $destinationPath -Parent
            if (!(Test-Path $destinationDir)) { New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null }
            Move-FileWithRetry -Source $wf.FullName -Destination $destinationPath | Out-Null
        } else {
            Write-Host "No matching source entry found for file '$($wf.Name)'. Skipping." -ForegroundColor Red
        }
    }
}
Write-Host "Pre-check complete: No source files remain in the watch folder." -ForegroundColor Green

# ------------------------------------------
# 3. Configuration Variables and Backup Destination Setup
# ------------------------------------------
$videoExtensions = @(".mxf", ".mp4", ".mov", ".crm", ".avi")
if (-not [string]::IsNullOrEmpty($PredefinedBackupDrive)) {
    $backupDrive = $PredefinedBackupDrive
} else {
    $backupDrive = (Split-Path $sourceFolder -Qualifier)
}
if ($backupDrive[-1] -ne "\") { $backupDrive += "\" }
$sourceFolderName = Split-Path $sourceFolder -Leaf
$destFolder = Join-Path $backupDrive "$sourceFolderName - h265"
if (!(Test-Path $destFolder)) { New-Item -ItemType Directory -Path $destFolder -Force | Out-Null }
Write-Host "Backup destination folder: $destFolder" -ForegroundColor Cyan
Write-Host "-----------------------------------------"

# ------------------------------------------
# 3.5. Update Watch Folder Info, Perform Space Check, and Restart AME
# ------------------------------------------
$watchFolderInfoPath = "C:\Users\christoph\Documents\Adobe\Adobe Media Encoder\25.0\Watch Folder Info.xml"
if (Test-Path $watchFolderInfoPath) {
    try {
        [xml]$xml = Get-Content $watchFolderInfoPath
        $newWatchFolder = $watchFolder  # Use the watch folder already determined
        if ($xml.PremiereData.WatchFolder) {
            $xml.PremiereData.WatchFolder.WatchFolderName = $newWatchFolder
        }
        else {
            $root = $xml.SelectSingleNode("PremiereData")
            $wfElem = $xml.CreateElement("WatchFolder")
            $nameElem = $xml.CreateElement("WatchFolderName")
            $nameElem.InnerText = $newWatchFolder
            $wfElem.AppendChild($nameElem) | Out-Null
            $root.AppendChild($wfElem) | Out-Null
        }
        $xml.Save($watchFolderInfoPath)
        Write-Host "Updated Watch Folder Info.xml: Watch folder set to $newWatchFolder" -ForegroundColor Green
    }
    catch {
        Write-Host "Error updating Watch Folder Info.xml: $_" -ForegroundColor Red
    }
} else {
    Write-Host "Watch Folder Info XML file not found at $watchFolderInfoPath" -ForegroundColor Red
}

$driveLetter = $backupDrive.Substring(0,1)
$driveInfo = Get-PSDrive -Name $driveLetter
$sourceSize = (Get-ChildItem -Path $sourceFolder -Recurse -File | Measure-Object -Property Length -Sum).Sum
if (-not $sourceSize) {
    Write-Host "Could not determine source folder size. Check the source path." -ForegroundColor Red
    exit
}
$freeSpace = $driveInfo.Free
$requiredSpace = [math]::Ceiling($sourceSize / 5)
$sourceSizeReadable = Convert-BytesToReadableSize -bytes $sourceSize
$requiredSpaceReadable = Convert-BytesToReadableSize -bytes $requiredSpace
$freeSpaceReadable = Convert-BytesToReadableSize -bytes $freeSpace
if ($freeSpace -lt $requiredSpace) {
    Write-Host "WARNING: Free space on drive ${backupDrive} ($freeSpaceReadable) is less than required ($requiredSpaceReadable)." -ForegroundColor Yellow
} else {
    Write-Host "Free space on drive ${backupDrive} is sufficient: $freeSpaceReadable available (required at least $requiredSpaceReadable)." -ForegroundColor Green
}

Restart-AME

# ------------------------------------------
# 4. Pre-Check: Verify Which Source Files Already Have Backup Targets
# ------------------------------------------
Write-Host "Performing pre-check of backup target files..." -ForegroundColor Cyan
$allSourceFiles = Get-ChildItem -Path $sourceFolder -Recurse -File | Where-Object { -not ($_.BaseName -like "*_proxy") }

$missingFromJson = @()
foreach ($entry in $sourceFilesList) {
    $fullPath = Join-Path $sourceFolder $entry.RelativePath
    if (-not (Test-Path $fullPath)) {
        $missingFromJson += $entry.RelativePath
    }
}
if ($missingFromJson.Count -gt 0) {
    Write-Host "WARNING: The following files are listed in the JSON but do NOT exist:" -ForegroundColor Yellow
    $missingFromJson | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
}

$missingFilesPre = @()
$existingFilesPre = @()
foreach ($sf in $allSourceFiles) {
    $expectedTarget = Get-ExpectedTarget -File $sf -SourceFolder $sourceFolder -DestFolder $destFolder -VideoExtensions $videoExtensions
    if (Test-Path $expectedTarget) {
        $existingFilesPre += $sf.FullName
    } else {
        $missingFilesPre += $sf.FullName
    }
}
Write-Host "Pre-check: Backup files already exist for $($existingFilesPre.Count) source files." -ForegroundColor Cyan
Write-Host "Pre-check: Backup files are missing for $($missingFilesPre.Count) source files." -ForegroundColor Cyan
if ($missingFilesPre.Count -eq 0) {
    Write-Host "All source files have backup targets. Nothing to encode." -ForegroundColor Green
} else {
    Write-Host "Processing only missing files..."
}
Write-Host "-----------------------------------------"

# ------------------------------------------
# 5. Process Each Source File (Only Those Missing Backup) with Progress Reporting
# ------------------------------------------
$filesToProcess = $allSourceFiles | Where-Object {
    $expectedTarget = Get-ExpectedTarget -File $_ -SourceFolder $sourceFolder -DestFolder $destFolder -VideoExtensions $videoExtensions
    -not (Test-Path $expectedTarget)
}
$totalToProcess = $filesToProcess.Count
$processedCount = 0

foreach ($file in $filesToProcess) {
    $processedCount++
    $relativePath = $file.FullName.Substring($sourceFolder.Length)
    $expectedTarget = Get-ExpectedTarget -File $file -SourceFolder $sourceFolder -DestFolder $destFolder -VideoExtensions $videoExtensions
    Write-Host "[$processedCount of $totalToProcess] Processing file: $($file.FullName)" -ForegroundColor Cyan

    if ($videoExtensions -contains $file.Extension.ToLower().Trim()) {
        Write-Host "Active file (VIDEO): $($file.FullName)" -ForegroundColor White

        $expectedBase = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        $destRelativePath = [System.IO.Path]::ChangeExtension($relativePath, ".mp4")
        $destFile = Join-Path $destFolder $destRelativePath
        $destDir = Split-Path $destFile -Parent
        if (!(Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

        $watchInputFile = Join-Path $watchFolder $file.Name
        Write-Host "Moving video file to watch folder: $watchInputFile" -ForegroundColor Cyan
        try {
            Move-Item -Path $file.FullName -Destination $watchInputFile -Force -ErrorAction Stop
        } catch {
            Write-Host "Failed to move video file '$($file.FullName)' to watch folder. Continuing script execution." -ForegroundColor Red
            continue
        }

        Write-Host "Waiting for encoded output file matching: $expectedBase*.mp4" -ForegroundColor Cyan
        $encodedFile = $null
        $maxWait = 600  # maximum wait time in seconds
        $waited = 0
        while ($encodedFile -eq $null -and $waited -lt $maxWait) {
            $encodedFile = Get-ChildItem -Path $watchFolderOutput -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "$expectedBase*.mp4" } | Select-Object -First 1
            if ($encodedFile -eq $null) {
                Start-Sleep -Seconds 5
                $waited += 5
            }
        }
        if ($encodedFile -eq $null) {
            Write-Host "Encoded file for '$($file.Name)' not found within timeout period. Skipping file." -ForegroundColor Red
            continue
        }
        Write-Host "Encoded file found: $($encodedFile.FullName)" -ForegroundColor Green

        if (-not (Move-FileWithRetry -Source $encodedFile.FullName -Destination $destFile)) {
            Write-Host "Failed to move encoded file '$($encodedFile.FullName)' to '$destFile'. Continuing script execution." -ForegroundColor Red
        }

        $originalInWatch = Get-ChildItem -Path $watchFolder -Recurse -File -Filter $file.Name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($originalInWatch -ne $null) {
            $originalDest = Join-Path $sourceFolder $relativePath
            $origDir = Split-Path $originalDest -Parent
            if (!(Test-Path $origDir)) { New-Item -ItemType Directory -Path $origDir -Force | Out-Null }
            if (-not (Move-FileWithRetry -Source $originalInWatch.FullName -Destination $originalDest)) {
                Write-Host "Failed to restore original video file '$($originalInWatch.FullName)' to '$originalDest'." -ForegroundColor Red
            }
            else {
                Write-Host "Original video file returned to source location: $originalDest" -ForegroundColor Green
            }
        }
        else {
            Write-Host "No original video file found in the watch folder to return." -ForegroundColor Yellow
            $originalDest = $file.FullName
        }

        try {
            $originalFileItem = Get-Item $originalDest
        }
        catch {
            $originalFileItem = Get-Item $file.FullName
        }
        $encodedFileItem = Get-Item $destFile
        $originalSizeReadable = Convert-BytesToReadableSize -bytes $originalFileItem.Length
        $encodedSizeReadable = Convert-BytesToReadableSize -bytes $encodedFileItem.Length
        Write-Host "File sizes for '$($file.Name)': Original = $originalSizeReadable, Encoded = $encodedSizeReadable" -ForegroundColor Cyan
        Write-Host "------------------------------------------"
    }
    else {
        Write-Host "Active file (NON-VIDEO): $($file.FullName)" -ForegroundColor White
        $destDir = Split-Path $expectedTarget -Parent
        if (!(Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        Copy-Item -Path $file.FullName -Destination $expectedTarget -Force
        Write-Host "Copied non-video file to: $expectedTarget" -ForegroundColor Green
    }
}

Write-Host "Backup process complete. Processed $processedCount files." -ForegroundColor Green

# ------------------------------------------
# 6. Cleanup: Remove Empty Folders from the Watch Folder and Source
# ------------------------------------------
Remove-EmptyDirectories -Path $watchFolder
Remove-EmptySourceDirectories -SourcePath $sourceFolder

# ------------------------------------------
# 7. Final Integrity Check: Report Which Target Files Are Missing
# ------------------------------------------
Write-Host "Performing final integrity check: verifying backup targets..." -ForegroundColor Cyan
$finalMissing = @()
foreach ($sourceFile in $allSourceFiles) {
    $expectedTarget = Get-ExpectedTarget -File $sourceFile -SourceFolder $sourceFolder -DestFolder $destFolder -VideoExtensions $videoExtensions
    if (-not (Test-Path $expectedTarget)) {
        $finalMissing += [PSCustomObject]@{
            SourceFile     = $sourceFile.FullName
            ExpectedTarget = $expectedTarget
        }
    }
}
if ($finalMissing.Count -gt 0) {
    Write-Host "The following files do NOT have corresponding backup files:" -ForegroundColor Red
    $finalMissing | Format-Table -AutoSize
}
else {
    Write-Host "All source files have corresponding backup files." -ForegroundColor Green
}

Write-Host "Script complete." -ForegroundColor Green
