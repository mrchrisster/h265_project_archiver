# H265 Project Transcoder

> A DaVinci Resolve-integrated Python tool to archive, compress, and preserve video projects at 10× smaller size — without compromising quality.

![Python](https://img.shields.io/badge/python-3.9-blue)
![Platform](https://img.shields.io/badge/platform-Windows-lightgrey)
![License](https://img.shields.io/badge/license-MIT-green)

---

## 🎯 Overview

**H265 Project Transcoder** is a fully automated, Python-based solution designed to streamline your video archiving workflow. It integrates with **DaVinci Resolve Studio** to handle everything from video detection and grading to encoding and backup using the H.265 (HEVC) codec with GPU acceleration.

If you have large, long-term video project archives, this tool can cut file sizes by up to **10×** while preserving folder structures and high visual quality — ideal for efficient backups and future access.

It is meant for video production companies who want to archive their old projects (which are unlikely to be used again) and save space or when working together with remote editors.

---

## 🧩 Key Features

- 🔍 **Pre-processing & Smart Skipping**
  - Skips `_proxy` files automatically
  - Checks if output already exists and passes integrity check (via PyAV or FFmpeg)

- 🎬 **Timeline Automation in Resolve**
  - Auto-imports matching mono or stereo timeline templates
  - Applies original clip resolution and frame rate
  - Uses `.drx` grading (optional) for RAW or LOG source media

- 💾 **Space-Saving Backup Workflow**
  - Transcodes to `.mp4` using H.265 NVIDIA NVENC
  - Preserves folder structure for easy reference

- 🧠 **Smart Fallbacks**
  - Falls back to FFmpeg CLI if PyAV is not available
  - Automatically launches Resolve and loads a `.drp` project and `.xml` render preset

---

## ✅ Requirements

| Component               | Requirement                                         |
|------------------------|-----------------------------------------------------|
| OS                     | Windows 10/11 or Mac OSX                                       |
| Python Version         | Python 3.9+                                         |
| Python Packages        | `pyav` (optional, recommended for integrity checks) |
| Video Editor           | DaVinci Resolve **Studio** (not free version)       |
| GPU                    | NVIDIA with NVENC support                           |

---

## 📦 Installation

#### MAC OS X
```
brew install python@3.9
brew install python-tk@3.9
pip3.9 install av
```

## 📦 Supported Formats

- Video: `.mxf`, `.mp4`, `.mov`, `.crm`, `.avi`
- Raw stills (optional): `.arw`, `.cr2`, `.cr3`, `.nef`, `.dng`, `.orf`, `.rw2`, `.sr2`

---

## 📁 Input/Output Example


#### Input folder:
```
MyVideoProject/
├── A001_C001.mov
├── A001_C001_proxy.mov    ← skipped
├── Graphics/
│   └── logo.png
```

#### Output folder:
```
MyVideoProject-265/
├── A001_C001.mp4          ← transcoded
├── Graphics/
│   └── logo.png           ← copied
```

## ⚙️ Usage

1. **Clone or download** this repository.
2. **Update the paths** at the top of `archive_and_transcode.py`:
   - Path to your `.drp` project template
   - Path to your `.drt` mono/stereo timeline templates
   - Path to your `.xml` render preset
   - (Optional) Path to a `.drx` grade file
3. Run:

```bash
python archive_and_transcode.py




