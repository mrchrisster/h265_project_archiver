# ============================================
# Full Script: Source Files Pre-Check, Recovery, Processing,
# Auto-Restoration, Watch Folder Setup, Space Check, AME Restart,
# and Adaptive Encoding Progress Estimation
# ============================================

# ----- Global Settings & Debug Flag -----
$PredefinedSourceFolder = ""  # Ensure trailing backslash
$PredefinedWatchFolder  = ""   # Leave empty to auto-set (default: same drive as source)
$PredefinedBackupDrive  = ""   # Leave empty to auto-set (default: same drive as source)
$videoExtensions = @(".mxf", ".mp4", ".mov", ".crm", ".avi")
$rawExtensions = @(".arw", ".cr2", ".cr3", ".nef", ".dng", ".raf", ".orf", ".rw2", ".sr2")
$JpgQuality = 75
$RawTherapeePath = "C:\Program Files\RawTherapee\5.11\rawtherapee-cli.exe"


# Helper function for debug logging.
function Write-DebugLog {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [ConsoleColor]$Color = "Gray"
    )
    if ($debug) {
        Write-Host $Message -ForegroundColor $Color
    }
}

# ----- AME Version Folder Detection & Log File Setup -----
$ameUserDocsBase = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "Adobe\Adobe Media Encoder"
if (Test-Path $ameUserDocsBase) {
    $AMEVersionFolders = Get-ChildItem -Path $ameUserDocsBase -Directory | Where-Object { $_.Name -match '^\d+(\.\d+)?$' }
    if ($AMEVersionFolders.Count -gt 0) {
        $latestAMEFolder = $AMEVersionFolders | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
        $watchFolderInfoPath = Join-Path $latestAMEFolder.FullName "Watch Folder Info.xml"
        $logPath = Join-Path $latestAMEFolder.FullName "AMEEncodingErrorLog.txt"
    }
    else {
        Write-Host "No version folders found in $ameUserDocsBase. Using default paths." -ForegroundColor Yellow
        $watchFolderInfoPath = "C:\Users\$env:USERNAME\Documents\Adobe\Adobe Media Encoder\25.0\Watch Folder Info.xml"
        $logPath = "C:\Users\$env:USERNAME\Documents\Adobe\Adobe Media Encoder\25.0\AMEEncodingErrorLog.txt"
    }
}
else {
    Write-Host "AME documents folder not found. Using default paths." -ForegroundColor Yellow
    $watchFolderInfoPath = "C:\Users\$env:USERNAME\Documents\Adobe\Adobe Media Encoder\25.0\Watch Folder Info.xml"
    $logPath = "C:\Users\$env:USERNAME\Documents\Adobe\Adobe Media Encoder\25.0\AMEEncodingErrorLog.txt"
}

if (!(Test-Path $logPath)) {
    New-Item -Path $logPath -ItemType File -Force | Out-Null
}

# ----- Helper Functions -----

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

function Test-AMEErrorLog {
    param (
        [Parameter(Mandatory = $true)]
        [string]$WatchFilePath,
        [Parameter(Mandatory = $true)]
        [datetime]$Since
    )
    if (-not (Test-Path $logPath)) {
        return $false
    }
    $logContent = Get-Content $logPath -Raw
    $blocks = $logContent -split "^-{5,}"
    foreach ($block in $blocks) {
        if ($block -match [regex]::Escape($WatchFilePath)) {
            $lines = $block -split "`n"
            foreach ($line in $lines) {
                if ($line -match '^(?<timestamp>\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2} (AM|PM))') {
                    $tsStr = $Matches['timestamp']
                    try {
                        $entryTime = [datetime]::ParseExact($tsStr, "MM/dd/yyyy hh:mm:ss tt", $null)
                    } catch {
                        continue
                    }
                    if ($entryTime -ge $Since) {
                        return $true
                    }
                }
            }
        }
    }
    return $false
}

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
            Write-DebugLog "Attempt $($i+1): File '$Source' exists with size $currentSize bytes, LastWriteTime: $lastWriteTime"
        } else {
            Write-Host "Attempt $($i+1): File '$Source' no longer exists." -ForegroundColor Red
            return $false
        }
        if ((IsFileLocked -File $Source) -or (-not (Test-FileStability -FilePath $Source -DelaySeconds 2))) {
            Write-DebugLog "Attempt $($i + 1) of ${RetryCount}: File '$Source' is locked or unstable." "Yellow"
        } else {
            try {
                Move-Item -Path $Source -Destination $Destination -Force -ErrorAction Stop
                Write-DebugLog "Successfully moved file from '$Source' to '$Destination'." "Green"
                return $true
            } catch {
                Write-DebugLog "Attempt $($i + 1) of ${RetryCount}: Could not move file '$Source' to '$Destination': $_" "Yellow"
            }
        }
        Start-Sleep -Seconds $DelaySeconds
    }
    Write-Host "Failed to move file '$Source' after ${RetryCount} attempts. Continuing script execution." -ForegroundColor Red
    return $false
}

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

# Function to convert a raw file to a JPEG using RawTherapee CLI v5.11.
function Convert-RawToJpg {
    param (
        [Parameter(Mandatory=$true)]
        [string]$InputFile,
        [Parameter(Mandatory=$true)]
        [string]$OutputFile,
        [int]$Quality = 75
    )

    # Extract the output directory from the desired output file.
    $outputDir = Split-Path $OutputFile -Parent
    Write-Host "Converting raw file '$InputFile' to JPEG in directory '$outputDir' with quality $Quality..." -ForegroundColor Cyan

    # Call RawTherapee with the -d option to specify the output directory.
    & $RawTherapeePath -Y -j$Quality -c $InputFile -d $outputDir

    # The CLI should write the file with the same base name and a .jpg extension in the output directory.
    if (Test-Path $OutputFile) {
        Write-Host "Conversion succeeded: $OutputFile" -ForegroundColor Green
    } else {
        Write-Host "Conversion for $InputFile may have failed." -ForegroundColor Red
    }
}




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

function Test-VideoReadability {
    param (
        [Parameter(Mandatory=$true)]
        [string]$FilePath
    )
    try {
        $mediainfoOutput = & mediainfo --Output=JSON $FilePath 2>&1
        if ([string]::IsNullOrWhiteSpace($mediainfoOutput)) {
            Write-DebugLog "No MediaInfo output for file '$FilePath'." "Yellow"
            return $false
        }
    }
    catch {
        Write-DebugLog "Error running mediainfo on '$FilePath': $_" "Yellow"
        return $false
    }

    try {
        $json = $mediainfoOutput | ConvertFrom-Json
    }
    catch {
        Write-DebugLog "Failed to parse MediaInfo JSON for file '$FilePath': $_" "Yellow"
        return $false
    }

    if ($json.media -eq $null) {
        Write-DebugLog "MediaInfo returned null for file '$FilePath'." "Yellow"
        return $false
    }

    # Coerce the track property into an array and filter for Video tracks.
    $tracks = @($json.media.track)
    $videoTracks = $tracks | Where-Object { $_."@type" -eq "Video" }

    # Instead of checking the count, simply check for the presence of a key attribute (e.g. ID)
    if ($videoTracks -and $videoTracks.ID) {
        return $true
    }
    else {
        Write-DebugLog "No valid video track attribute found in '$FilePath'." "Yellow"
        return $false
    }
}




function Remove-EmptyDirectories {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    if (-not (Test-Path $Path)) { return }
    $dirs = Get-ChildItem -Path $Path -Directory -Recurse -Force | Sort-Object { $_.FullName.Length } -Descending
    foreach ($dir in $dirs) {
        $items = Get-ChildItem -Path $dir.FullName -Force
        if ($items.Count -eq 0) {
            try {
                Remove-Item -Path $dir.FullName -Recurse -Force -ErrorAction Stop
                Write-DebugLog "Removed empty folder: $($dir.FullName)" "Green"
            } catch {
                Write-Host "Failed to remove folder: $($dir.FullName). Error: $_" -ForegroundColor Red
            }
        }
    }
}

# ----- 1. Source Files Setup and Pre-Check -----
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

# ----- 2. Pre-Check: Ensure No Source File Is Already in the Watch Folder -----
$defaultWatchFolder = ("$($sourceFolder.Substring(0,1)):\watch_folder")
if (-not [string]::IsNullOrEmpty($PredefinedWatchFolder)) {
    $watchFolder = $PredefinedWatchFolder
} else {
    $watchFolder = $defaultWatchFolder
}

if (-not (Test-Path $watchFolder)) {
    New-Item -Path $watchFolder -ItemType Directory -Force | Out-Null
    Write-Host "Created watch folder: $watchFolder" -ForegroundColor Green
}
$watchFolderOutput = Join-Path $watchFolder "output"
if (-not (Test-Path $watchFolderOutput)) {
    New-Item -Path $watchFolderOutput -ItemType Directory -Force | Out-Null
    Write-Host "Created watch folder output folder: $watchFolderOutput" -ForegroundColor Green
}

$watchFolderSourceRoot = Join-Path $watchFolder "source"
if (Test-Path $watchFolderSourceRoot) {
    Get-ChildItem -Path $watchFolderSourceRoot -Directory -Recurse -Force | ForEach-Object {
        if ((Get-ChildItem -Path $_.FullName -File -Recurse -Force -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            Write-DebugLog "Removed empty folder in watch source: $($_.FullName)" "Green"
        }
    }
}

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

# ----- 3. Configuration Variables and Backup Destination Setup -----
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

if (Test-Path $watchFolderInfoPath) {
    try {
        [xml]$xml = Get-Content $watchFolderInfoPath
        $newWatchFolder = $watchFolder
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
        if ($xml.PremiereData.WatchFolderOutput) {
            $xml.PremiereData.WatchFolderOutput.OutputFolderName = "$watchFolder\Output\"
        }
        else {
            $root = $xml.SelectSingleNode("PremiereData")
            $wfoElem = $xml.CreateElement("WatchFolderOutput")
            $outputElem = $xml.CreateElement("OutputFolderName")
            $outputElem.InnerText = "$watchFolder\Output\"
            $wfoElem.AppendChild($outputElem) | Out-Null
            $root.AppendChild($wfoElem) | Out-Null
        }
        $xml.Save($watchFolderInfoPath)
        Write-Host "Updated Watch Folder Info.xml: Watch folder set to $newWatchFolder and output folder set to $watchFolder\Output\" -ForegroundColor Green
    }
    catch {
        Write-Host "Error updating Watch Folder Info.xml: $_" -ForegroundColor Red
    }
}
else {
    Write-Host "Watch Folder Info XML file not found at $watchFolderInfoPath" -ForegroundColor Red
}

$driveLetter = $backupDrive.Substring(0,1)
$driveInfo = Get-PSDrive -Name $driveLetter
$videoSourceFiles = Get-ChildItem -Path $sourceFolder -Recurse -File | Where-Object { $videoExtensions -contains $_.Extension.ToLower().Trim() }
$TotalProjectSourceSize = ($videoSourceFiles | Measure-Object -Property Length -Sum).Sum
if (-not $TotalProjectSourceSize) {
    Write-Host "Could not determine total video source size. Check the source path." -ForegroundColor Red
    exit
}
$freeSpace = $driveInfo.Free
$requiredSpace = [math]::Ceiling(($TotalProjectSourceSize) / 5)
$sourceSizeReadable = Convert-BytesToReadableSize -bytes $TotalProjectSourceSize
$requiredSpaceReadable = Convert-BytesToReadableSize -bytes $requiredSpace
$freeSpaceReadable = Convert-BytesToReadableSize -bytes $freeSpace
if ($freeSpace -lt $requiredSpace) {
    Write-Host "WARNING: Free space on drive ${backupDrive} ($freeSpaceReadable) is less than required ($requiredSpaceReadable)." -ForegroundColor Yellow
} else {
    Write-Host "Free space on drive ${backupDrive} is sufficient: $freeSpaceReadable available (required at least $requiredSpaceReadable)." -ForegroundColor Green
}

Restart-AME

# ----- 4. Pre-Check: Verify Which Source Files Already Have Backup Targets -----
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
Write-Host "Pre-check complete." -ForegroundColor Green

# ----- Adaptive Estimation Initialization -----
$preProcessedVideoFiles = Get-ChildItem -Path $destFolder -Recurse -File | Where-Object {
    $_.Extension.ToLower().Trim() -eq ".mp4"
}

$CumulativeEncoded = 0
$CumulativeSourceEncoded = 0

foreach ($encFile in $preProcessedVideoFiles) {
    $srcEntry = $sourceFilesList | Where-Object {
        $expectedTarget = Get-ExpectedTarget -File (Get-Item (Join-Path $sourceFolder $_.RelativePath)) `
                            -SourceFolder $sourceFolder -DestFolder $destFolder -VideoExtensions $videoExtensions
        $expectedTarget -eq $encFile.FullName
    } | Select-Object -First 1

    if ($srcEntry) {
        $srcFilePath = Join-Path $sourceFolder $srcEntry.RelativePath
        if (Test-Path $srcFilePath) {
            $srcSize = (Get-Item $srcFilePath).Length
            $CumulativeSourceEncoded += $srcSize
            $CumulativeEncoded += $encFile.Length
        }
    }
}

if ($CumulativeSourceEncoded -gt 0) {
    $adaptiveRatio = $CumulativeEncoded / $CumulativeSourceEncoded
} else {
    $adaptiveRatio = 0.1
}

$expectedFinalEncodedSize = $TotalProjectSourceSize * $adaptiveRatio

if ($expectedFinalEncodedSize -gt 0) {
    $progressPercentage = [math]::Round(($CumulativeEncoded / $expectedFinalEncodedSize) * 100, 2)
} else {
    $progressPercentage = 0
}

Write-Progress -Activity "Encoding Progress" `
    -Status ("Pre-existing: Encoded {0:N2} GB of estimated {1:N2} GB (Ratio: {2:N2})" -f ($CumulativeEncoded/1GB), ($expectedFinalEncodedSize/1GB), $adaptiveRatio) `
    -PercentComplete $progressPercentage

# ----- 5. Process Each Source File with Simplified Output -----
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
        # Verify video file using MediaInfo CLI
        if (-not (Test-VideoReadability -FilePath $file.FullName)) {
            Write-Host "Skipping unreadable or invalid video file: $($file.FullName)" -ForegroundColor Yellow
            continue
        }
        
        Write-DebugLog "Active file (VIDEO): $($file.FullName)" "White"
        $expectedBase = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        $destRelativePath = [System.IO.Path]::ChangeExtension($relativePath, ".mp4")
        $destFile = Join-Path $destFolder $destRelativePath
        $destDir = Split-Path $destFile -Parent
        if (!(Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

        $sourceDrive = [System.IO.Path]::GetPathRoot($sourceFolder).ToUpper()
        $watchDrive  = [System.IO.Path]::GetPathRoot($watchFolder).ToUpper()
        $sameDrive   = ($sourceDrive -eq $watchDrive)

        $watchInputFile = Join-Path $watchFolder $file.Name
        if ($debug) { Write-Host "Sending video file to watch folder: $watchInputFile" -ForegroundColor Cyan }
        if ($sameDrive) {
            try {
                Move-Item -Path $file.FullName -Destination $watchInputFile -Force -ErrorAction Stop
            } catch {
                Write-Host "Failed to move video file '$($file.FullName)' to watch folder. Continuing script execution." -ForegroundColor Red
                continue
            }
        } else {
            try {
                Copy-Item -Path $file.FullName -Destination $watchInputFile -Force -ErrorAction Stop
            } catch {
                Write-Host "Failed to copy video file '$($file.FullName)' to watch folder. Continuing script execution." -ForegroundColor Red
                continue
            }
        }

        # High-level summary output for video encoding
        Write-Host "Encoding in progress..."
        $fileStartTime = Get-Date

        $encodedFile = $null
        while ($true) {
            $candidate = Get-ChildItem -Path $watchFolderOutput -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "$expectedBase*.mp4" } | Select-Object -First 1
            if ($candidate -ne $null) {
                $initialSize = $candidate.Length
                Start-Sleep -Seconds 5
                if (Test-Path $candidate.FullName) {
                    $currentSize = (Get-Item $candidate.FullName).Length
                } else {
                    $currentSize = 0
                }
                if ($initialSize -eq $currentSize -and $initialSize -gt 0) {
                    Write-DebugLog "Encoded file '$($candidate.FullName)' is stable (size: $currentSize bytes)." "Green"
                    $encodedFile = $candidate
                    break
                } else {
                    Write-DebugLog "Encoded file '$($candidate.FullName)' is still growing (from $initialSize to $currentSize bytes). Waiting..." "Yellow"
                }
            }
            if (Test-AMEErrorLog -WatchFilePath $watchInputFile -Since $fileStartTime) {
                Write-Host "Error detected in AME encoding for file '$watchInputFile'." -ForegroundColor Red
                break
            }
            Start-Sleep -Seconds 5
        }

        if ($encodedFile -eq $null) {
            continue
        }

        Write-DebugLog "Encoded file found: $($encodedFile.FullName)" "Green"
        if (-not (Move-FileWithRetry -Source $encodedFile.FullName -Destination $destFile)) {
            Write-Host "Failed to move encoded file '$($encodedFile.FullName)' to '$destFile'. Continuing script execution." -ForegroundColor Red
        }
        
        $originalInWatch = Get-ChildItem -Path $watchFolder -Recurse -File -Filter $file.Name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($originalInWatch -ne $null) {
            if ($sameDrive) {
                $originalDest = Join-Path $sourceFolder $relativePath
                $origDir = Split-Path $originalDest -Parent
                if (!(Test-Path $origDir)) { New-Item -ItemType Directory -Path $origDir -Force | Out-Null }
                if (-not (Move-FileWithRetry -Source $originalInWatch.FullName -Destination $originalDest)) {
                    Write-Host "Failed to restore original video file '$($originalInWatch.FullName)' to '$originalDest'." -ForegroundColor Red
                }
                else {
                    Write-DebugLog "Original video file returned to source location: $originalDest" "Green"
                    $watchSubdir = Split-Path $originalInWatch.FullName -Parent
                    if ($watchSubdir -like "$watchFolderSourceRoot*") {
                        if ((Get-ChildItem -Path $watchSubdir -Force -Recurse -ErrorAction SilentlyContinue).Count -eq 0) {
                            Remove-Item -Path $watchSubdir -Recurse -Force -ErrorAction SilentlyContinue
                            Write-DebugLog "Removed empty watch subdirectory: $watchSubdir" "Green"
                        }
                    }
                }
            }
            else {
                try {
                    Remove-Item -Path $originalInWatch.FullName -Force -ErrorAction Stop
                    Write-DebugLog "Copied video file removed from watch folder." "Green"
                } catch {
                    Write-Host "Failed to remove copied video file '$($originalInWatch.FullName)' from watch folder." -ForegroundColor Red
                }
            }
        }
        
        Write-Host "Encoding finished."
        $origReadable = Convert-BytesToReadableSize -bytes $file.Length
        $encodedReadable = Convert-BytesToReadableSize -bytes ((Get-Item $destFile).Length)
        Write-Host "Original Size: $origReadable    Encoded Size: $encodedReadable"

        # Adaptive status bar update
        try {
            $encodedFileItem = Get-Item $destFile
            $CumulativeEncoded += $encodedFileItem.Length
            $CumulativeSourceEncoded += $file.Length

            if ($CumulativeSourceEncoded -gt 0) {
                $adaptiveRatio = $CumulativeEncoded / $CumulativeSourceEncoded
            } else {
                $adaptiveRatio = 0.1
            }
            $expectedFinalEncodedSize = $TotalProjectSourceSize * $adaptiveRatio
            if ($expectedFinalEncodedSize -gt 0) {
                $progressPercentage = [math]::Round(($CumulativeEncoded / $expectedFinalEncodedSize) * 100, 2)
            } else {
                $progressPercentage = 0
            }
            Write-Progress -Activity "Encoding Progress" -Status ("Encoded {0:N2} GB of estimated {1:N2} GB (Adaptive Ratio: {2:N2})" -f ($CumulativeEncoded/1GB), ($expectedFinalEncodedSize/1GB), $adaptiveRatio) -PercentComplete $progressPercentage
        } catch {
            Write-Host "Error updating progress: $_" -ForegroundColor Red
        }
    }
    else {
        # Non-video file branch
        if ($rawExtensions -contains $file.Extension.ToLower().Trim()) {
            Write-Host "Active file (RAW IMAGE): $($file.FullName)" -ForegroundColor White
            $expectedTargetJpg = [System.IO.Path]::ChangeExtension($expectedTarget, ".jpg")
            Convert-RawToJpg -InputFile $file.FullName -OutputFile $expectedTargetJpg -Quality $JpgQuality
        }
        else {
            Write-Host "Active file (NON-VIDEO): $($file.FullName)" -ForegroundColor White
            $destDir = Split-Path $expectedTarget -Parent
            if (!(Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
            Copy-Item -Path $file.FullName -Destination $expectedTarget -Force
            Write-Host "Copied non-video file to: $expectedTarget" -ForegroundColor Green
        }
    }
}




Write-Host "Backup process complete. Processed $processedCount files." -ForegroundColor Green

# ----- 6. Cleanup: Remove Empty Folders from the Watch Folder -----
Remove-EmptyDirectories -Path $watchFolder

# ----- 7. Final Integrity Check: Report Which Target Files Are Missing -----
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
