![AME](https://github.com/mrchrisster/h265_project_archiver/blob/main/media/ame.png)
![Powershell]((https://github.com/mrchrisster/h265_project_archiver/blob/main/media/h265_output.png))

# H265 Project Transcoder

**H265 Project Transcoder** is an automated PowerShell solution that streamlines the workflow for video backup, encoding, and file management. Designed to integrate seamlessly with Adobe Media Encoder (AME), this project handles the entire process from verifying source files to moving and encoding video files using the H.265 (HEVC) codec.

If you have old video projects that take up a lot of space on your archive drive, you can achieve a 10x reduction in space while maintaining high visual quality if you ever need to access your raw files again.

---

## Key Features

- **Source Files Pre-Check & Tracking:**  
  - Scans the designated source folder and generates (or updates) a JSON file list to track all source files.
  - Excludes files with base names ending in `_proxy` to avoid processing proxy files.

- **Watch Folder Automation:**  
  - Configures a watch folder that AME monitors.
  - Moves video files from the source folder into the watch folder to trigger encoding.
  - Automatically retrieves and restores source files after the encoding process is complete.

- **Automated Video Encoding & Backup:**  
  - Supports multiple video file formats (e.g., `.mxf`, `.mp4`, `.mov`, `.crm`, `.avi`).
  - For video files, changes the extension to `.mp4` post-encoding and organizes them into a backup destination.
  - Performs a free space check on the backup drive before processing to ensure sufficient storage.

- **Robust Error Handling & Recovery:**  
  - Implements retry loops with diagnostic logging to check file stability and locks.
  - Logs detailed file size and timestamp information if a file is locked or unstable.
  - Continues processing even if individual file moves fail, with built-in recovery on script restart.

- **Clean-Up Operations:**  
  - Automatically removes empty subfolders from both the watch folder and the source folder after files are moved.
  - Ensures the workspace remains tidy without manual intervention.

- **Adobe Media Encoder Integration:**  
  - Monitors and restarts AME as needed to maintain a seamless encoding pipeline.
  - Automatically updates AME’s watch folder configuration for consistency.

---

## Requirements

- **Operating System:** Windows (with PowerShell 5.1 or later)
- **Software:** Adobe Media Encoder (compatible version, e.g., 25.0)
- **Directories:** Access to a defined source folder, watch folder, and backup drive

---

## Requirements
- **You must have one watch folder present in Adobe Media Encoder. This script will update the watch folder location to be on the same drive as the project, so the path you choose for your watch folder doesn't matter.**
- Create wtach folder in AME by going to File -> Add Watch Folder

---

## Usage

1. **Configure Defaults:**  
   Edit the user-defined defaults at the top of the script (source folder, watch folder, backup drive) to match your environment.
   

3. **Run the Script:**  
   Execute the PowerShell script (`h265_project_archiver.ps1`) from a command prompt or PowerShell session:
   ```powershell
   .\h265_project_archiver.ps1
