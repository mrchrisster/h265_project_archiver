
# H265 Project Transcoder

**H265 Project Transcoder** is an automated python based solution that streamlines the workflow for video backup, encoding, and file management. Designed to integrate seamlessly with Davinci Resolve Studio, this project handles the entire process from verifying source files to moving and encoding video files using the H.265 (HEVC) codec.

If you have old video projects that take up a lot of space on your archive drive, you can achieve a 10x reduction in space while maintaining high visual quality if you ever need to access your old video files again.

---

## Key Features

- **Source Files Pre-Check & Tracking:**  
  - Excludes files with base names ending in `_proxy` to avoid processing proxy files.

- **Automated Video Encoding & Backup:**  
  - Supports multiple video file formats (e.g., `.mxf`, `.mp4`, `.mov`, `.crm`, `.avi`).
  - For video files, changes the extension to `.mp4` post-encoding and organizes them into a backup destination.
  - Performs a free space check on the backup drive before processing to ensure sufficient storage.

---

## Requirements

- **Operating System:** Windows (with python 3.9 and pyav installed)
- **Software:** Davinci Resolve Studio
- **Directories:** Access to a defined source folder, watch folder, and backup drive

---


---

## Usage

1. **Configure Defaults:**  
   Edit the user-defined defaults at the top of the script (source folder, watch folder, backup drive) to match your environment.
   

3. **Run the Script:**  
   ```
   .\python3.9 archive_and_transcode.py
