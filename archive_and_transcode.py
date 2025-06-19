#!/usr/bin/env python3
"""
archive_and_transcode.py

Archives a video project by:
  1. Copying non-media assets (excluding video/raw files) into <Project>-archive (named <Project>-265).
  2. Transcoding each media file (video/raw) via DaVinci Resolve to H.265 NVIDIA NVENC
     in an MP4 container, placing the output alongside the assets in the same archive folder,
     preserving folder structure.

Supports resuming interrupted transfers (skips existing good files, re-renders corrupted ones),
and runs a post-render integrity check using PyAV (or FFmpeg CLI fallback).

"""

import os
import sys
import shutil
import argparse
import subprocess
import time
import platform
from pathlib import Path

# Optional: PyAV integrity check
try:
    import av
    HAVE_PYAV = True
except ImportError:
    HAVE_PYAV = False
    print("⚠️ PyAV not installed; using FFmpeg CLI for integrity checks.")


from pathlib import Path

IS_MAC = platform.system() == "Darwin"
IS_WIN = platform.system() == "Windows"

if IS_MAC:
    RESOLVE_PY_MODULE = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/Modules"
    RESOLVE_EXE_PATH  = "/Applications/DaVinci Resolve/DaVinci Resolve.app"
    DRP_PATH          = os.path.expanduser("~/code/davinci_encoder/Batch_H265.drp")
    PRESET_XML_PATH   = os.path.expanduser("~/code/davinci_encoder/Batch_H265_RenderSettings.xml")
    drx_file          = os.path.expanduser("~/code/davinci_encoder/rawfix.drx")
    DRT_TEMPLATE_MONO =  os.path.expanduser("~/code/davinci_encoder/Template_Mono_1ch.drt")
    DRT_TEMPLATE_STEREO =  os.path.expanduser("~/code/davinci_encoder/Template_Stereo_2ch.drt")
elif IS_WIN:
    RESOLVE_PY_MODULE = r"C:\ProgramData\Blackmagic Design\DaVinci Resolve\Support\Developer\Scripting\Modules"
    RESOLVE_DLL_PATH  = r"C:\Program Files\Blackmagic Design\DaVinci Resolve"
    RESOLVE_EXE_PATH  = r"C:\Program Files\Blackmagic Design\DaVinci Resolve\Resolve.exe"
    DRP_PATH          = r"C:\code\davinci_encoder\Batch_H265.drp"
    PRESET_XML_PATH   = r"C:\code\davinci_encoder\Batch_H265_RenderSettings.xml"
    drx_file          = r"C:\code\davinci_encoder\rawfix.drx"
    DRT_TEMPLATE_MONO = r"C:\code\davinci_encoder\Template_Mono_1ch.drt"
    DRT_TEMPLATE_STEREO = r"C:\code\davinci_encoder\Template_Stereo_2ch.drt"
else:
    sys.exit("❌ Unsupported OS")
    

PROJECT_NAME = "Batch_H265"
PRESET_NAME = Path(PRESET_XML_PATH).stem

# Directories (by name) to skip entirely
EXCLUDE_DIRS = ["Exports", "Proxies", "Proxy"]

# File‑name patterns to skip entirely (case‑insensitive)
# e.g. "_proxy" will skip foo_proxy.mov or anything with “proxy” in its stem
EXCLUDE_FILE_PATTERNS = ["_proxy"]



def init_resolve():
    """
    Attach to an already‑running DaVinci Resolve (must be open), or exit with an error message.
    Returns a tuple (resolve, projectManager, project) on success, or None on failure.
    """
    # 1) Add the Resolve scripting API path (and DLL directory on Windows)
    sys.path.insert(0, RESOLVE_PY_MODULE)
    if IS_WIN:
        os.add_dll_directory(RESOLVE_DLL_PATH)

    # 2) Import the DaVinci Resolve scripting module
    try:
        import DaVinciResolveScript as dvr
    except Exception as e:
        print(f"❌ Could not import DaVinciResolveScript: {e}")
        return None

    # 3) Attempt to connect to the Resolve application via the scripting API
    print("⏳ Connecting to Resolve scripting API...", end="", flush=True)
    resolve = None
    for _ in range(30):
        resolve = dvr.scriptapp("Resolve")
        if resolve:
            break
        print(".", end="", flush=True)
        time.sleep(1)
    print()
    if not resolve:
        print("❌ DaVinci Resolve doesn’t appear to be running.")
        print("   Please launch DaVinci Resolve Studio and re‑run this script.")
        return None

    print("✅ Connected to DaVinci Resolve.")

    # 4) Load or import the project
    pm = resolve.GetProjectManager()
    project_list = pm.GetProjectListInCurrentFolder() or []
    if PROJECT_NAME not in project_list:
        print(f"📦 Importing project '{PROJECT_NAME}' from: {DRP_PATH}")
        if not os.path.isfile(DRP_PATH) or not pm.ImportProject(DRP_PATH, PROJECT_NAME):
            print(f"❌ Failed to import .drp at {DRP_PATH}")
            return None
    else:
        print(f"ℹ️ Project '{PROJECT_NAME}' already exists.")

    if not pm.LoadProject(PROJECT_NAME):
        print(f"❌ Failed to load project '{PROJECT_NAME}'")
        return None

    project = pm.GetCurrentProject()
    print(f"✅ Loaded project: {project.GetName()}")

    # 5) Switch to the Deliver page and load the render preset
    resolve.OpenPage("deliver")
    time.sleep(1)

    # Remove any existing preset with the same name
    for preset in project.GetRenderPresetList() or []:
        if preset == PRESET_NAME:
            project.DeleteRenderPreset(PRESET_NAME)
            print(f"🗑️ Deleted existing preset '{PRESET_NAME}'")
            break

    if not os.path.isfile(PRESET_XML_PATH):
        print(f"❌ Render preset XML not found at: {PRESET_XML_PATH}")
        return None

    if not resolve.ImportRenderPreset(PRESET_XML_PATH):
        print("⚠️ Warning: render preset import may have failed.")
    else:
        print(f"✅ Imported render preset '{PRESET_NAME}'")

    # 6) Return the Resolve app, Project Manager, and Project objects
    return resolve, pm, project

def select_folder_dialog(prompt: str) -> Path:
    try:
        import tkinter as tk
        from tkinter import filedialog
        root = tk.Tk(); root.withdraw()
        path = filedialog.askdirectory(title=prompt)
        if not path:
            sys.exit("Cancelled.")
        return Path(path)
    except ImportError:
        return Path(input(f"{prompt}: ").strip())


def format_size(n_bytes: int) -> str:
    for unit in ('bytes','KB','MB','GB','TB'):
        if n_bytes < 1024.0 or unit == 'TB':
            return f"{n_bytes:,.2f} {unit}"
        n_bytes /= 1024.0


def gather_files(src: Path, video_exts, raw_exts):
    """
    Walk src, returning (non_media, media), but skipping:
      • directories in EXCLUDE_DIRS
      • files whose suffix is in raw_exts (skipped entirely)
    """
    vset    = {e.lower() for e in video_exts}
    skipset = {e.lower() for e in raw_exts}
    non_media, media = [], []

    for root, dirs, files in os.walk(src):
        # 1) prune unwanted directories
        dirs[:] = [d for d in dirs if d not in EXCLUDE_DIRS]

        for f in files:
            p = Path(root) / f
            suffix = p.suffix.lower()

            # 2) skip raw‑image files entirely
            if suffix in skipset:
                continue

            # 3) classify what remains
            if suffix in vset:
                media.append(p)
            else:
                non_media.append(p)

    return non_media, media


def is_readable(path: Path) -> bool:
    if not path.exists():
        print(f"⚠️ Integrity failed (not found): {path}")
        return False
    if HAVE_PYAV:
        try:
            with av.open(str(path)) as ct:
                for _ in ct.decode(video=0): break
            return True
        except Exception as e:
            print(f"🔍 PyAV error on {path.name}: {e}")
            return False
    p = subprocess.run(['ffmpeg','-v','error','-i',str(path),'-f','null','-'],
                       stderr=subprocess.PIPE, stdout=subprocess.DEVNULL)
    return p.returncode == 0


def get_audio_info(clip):
    for _ in range(20):
        props = clip.GetClipProperty()
        ch = props.get("Audio Channels") or props.get("Audio Ch")
        if ch not in [None, "", "0"]:
            break
        time.sleep(0.25)

    props = clip.GetClipProperty()
    raw = props.get("Audio Channels") or props.get("Audio Ch")
    try:
        channels = int(raw)
    except:
        channels = -1
    layout = (props.get("Audio Track Type") or "").lower()
    return channels, layout

def get_timecode_from_clip(clip):
    """Return the clip’s start timecode, or None."""
    props     = clip.GetClipProperty()
    return props.get("Start TC") or props.get("Start Timecode")

def get_timecode_from_mp4(mp4_path):
    """Use ffprobe to read the embedded timecode tag from an MP4."""
    cmd = [
        'ffprobe','-v','error',
        '-select_streams','v:0',
        '-show_entries','stream_tags=timecode',
        '-of','default=noprint_wrappers=1:nokey=1',
        str(mp4_path)
    ]
    try:
        out = subprocess.check_output(cmd, text=True).strip()
        return out or None
    except Exception:
        return None
# ─── Replace your existing transcode_with_resolve() with this version ──

def transcode_with_resolve(resolve_bundle, clip_path: Path, src_root: Path, archive_root: Path) -> bool:
    resolve, pm, project = resolve_bundle
    base = clip_path.stem
    rel = clip_path.relative_to(src_root) if src_root in clip_path.parents else Path(base)

    out_folder = archive_root / rel.parent
    out_folder.mkdir(parents=True, exist_ok=True)
    out_file = out_folder / f"{base}.mp4"

    # 1) Quick skip if already rendered correctly
    if out_file.exists() and is_readable(out_file):
        print(f"✅ Skipping (exists & OK): {rel}")
        return True

    # 2) If corrupt MP4 exists, delete it (with retries on Windows locks)
    if out_file.exists():
        print(f"⚠️ Corrupt output, deleting old file: {out_file}")
        time.sleep(1)
        for attempt in range(3):
            try:
                out_file.unlink()
                break
            except PermissionError:
                print(f"🕒 File locked, retrying delete (attempt {attempt+1}/3)…")
                time.sleep(1)
        else:
            print(f"❌ Could not delete old file after retries: {out_file}")
            return False

    # 3) Clean Resolve project
    mp = project.GetMediaPool()
    storage = resolve.GetMediaStorage()
    project.DeleteAllRenderJobs()
    for i in range(1, project.GetTimelineCount() + 1):
        tl = project.GetTimelineByIndex(i)
        if tl:
            mp.DeleteTimelines([tl])
    clips = mp.GetRootFolder().GetClipList() or []
    if clips:
        mp.DeleteClips(clips)
    print("🧹 Resolve cleaned.")

    # 4) Import source clip
    print(f"📥 Importing: {clip_path}")
    items = storage.AddItemListToMediaPool([str(clip_path)])
    time.sleep(2)
    if not items:
        print(f"❌ Import failed: {clip_path}")
        return False
    clip = items[0]

    # 5) Grab source timecode (if any)
    raw_source_tc = get_timecode_from_clip(clip)
    if raw_source_tc:
        # normalize drop-frame semicolon to plain colon
        source_tc = raw_source_tc.replace(';', ':')
        print(f"🔎 Source Start TC: {raw_source_tc}  →  normalized to {source_tc}")
    else:
        source_tc = None
        print("⚠️ No Start TC found on source clip; defaulting to 00:00:00:00")

    # 6) Read clip properties for resolution & FPS
    props = clip.GetClipProperty()
    w, h = map(int, props['Resolution'].split('x'))
    fps = f"{float(props.get('FPS') or props.get('Frame rate')):.6f}".rstrip('0').rstrip('.')

    project.SetSetting("timelineUseCustomSettings", "1")
    project.SetSetting("timelineResolutionWidth", str(w))
    project.SetSetting("timelineResolutionHeight", str(h))
    project.SetSetting("timelineFrameRate", fps)
    project.SetSetting("timelinePlaybackFrameRate", fps)

    # 7) Pick mono vs stereo template
    channels, layout = get_audio_info(clip)
    use_stereo = (channels == 2 and (layout == "" or "stereo" in layout))
    drt_path = DRT_TEMPLATE_STEREO if use_stereo else DRT_TEMPLATE_MONO
    print(f"🎧 Detected {channels}ch; using {'stereo' if use_stereo else 'mono'} template")

    # 8) Import template timeline
    tl_name = f"TL_{base}"
    timeline = mp.ImportTimelineFromFile(drt_path, {
        "timelineName": tl_name,
        "importSourceClips": False
    })
    if not timeline:
        print(f"❌ Failed to import template: {drt_path}")
        return False

    # 9) Apply source timecode to the new timeline
    if source_tc:
        ok = timeline.SetStartTimecode(source_tc)
        print(f"✅ SetStartTimecode returned: {ok}")

    # 10) Double‑check timeline settings
    timeline.SetSetting("timelineResolutionWidth", str(w))
    timeline.SetSetting("timelineResolutionHeight", str(h))
    timeline.SetSetting("timelineFrameRate", fps)
    timeline.SetSetting("timelinePlaybackFrameRate", fps)
    tw = timeline.GetSetting("timelineResolutionWidth")
    th = timeline.GetSetting("timelineResolutionHeight")
    tfps = timeline.GetSetting("timelineFrameRate")
    print(f"📐 Timeline set to: {tw}x{th} @ {tfps} fps")

    # 11) Append clip and prune empty tracks
    if not mp.AppendToTimeline([clip]):
        print("❌ Failed to append actual media to timeline.")
        return False

    used_tracks = {'video': set(), 'audio': set()}
    for track_type in ['video', 'audio']:
        for i in range(1, timeline.GetTrackCount(track_type) + 1):
            if timeline.GetItemListInTrack(track_type, i):
                used_tracks[track_type].add(i)
    for track_type in ['video', 'audio']:
        for i in reversed(range(1, timeline.GetTrackCount(track_type) + 1)):
            if i not in used_tracks[track_type]:
                timeline.DeleteTrack(track_type, i)

    # 12) Load render preset (assumes you’ve already imported it) and set output
    project.LoadRenderPreset(PRESET_NAME)
    project.SetRenderSettings({
        'TargetDir': str(out_folder),
        'CustomName': base,
    })

    # 13) Optional DRX grade
    if os.path.exists(drx_file):
        resolve.OpenPage("color")
        time.sleep(1)
        for vc in project.GetCurrentTimeline().GetItemListInTrack('video', 1) or []:
            fn = getattr(vc.GetNodeGraph(), 'ApplyGradeFromDRX', None)
            if callable(fn) and fn(str(drx_file), 0):
                print(f"✅ Applied grade to {vc.GetName()}")

    # 14) Render
    job_id = project.AddRenderJob()
    if not job_id:
        print(f"❌ Failed to queue render for {base}")
        return False
    print(f"🚀 Rendering: {rel}")
    project.StartRendering()
    while project.IsRenderingInProgress():
        time.sleep(1)
    print(f"🏁 Completed render: {rel}")

    # 15) Verify integrity and timecode in the MP4
    if is_readable(out_file):
        print(f"✅ Integrity OK: {rel}")
        mp4_tc = get_timecode_from_mp4(out_file)
        if mp4_tc:
            print(f"▶️ Rendered MP4 timecode: {mp4_tc}")
            if source_tc and mp4_tc == source_tc:
                print("🎉 SUCCESS: MP4 timecode matches source!")
            else:
                print("❌ WARNING: MP4 timecode does not match source.")
        else:
            print("⚠️ No timecode tag found in MP4 (or ffprobe missing).")
        return True

    print(f"⚠️ Integrity still failed: {rel}")
    return False

# __main__ block with folder-based skip logic

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="Archive & transcode via Resolve")
    parser.add_argument('-s', '--source', help="Project root folder")
    parser.add_argument('-d', '--dest',   help="Destination root folder")
    parser.add_argument('-v', '--video-exts', nargs='*',
                        default=['.mxf', '.mp4', '.mov', '.crm', '.avi'],
                        help="Video extensions to transcode")
    parser.add_argument('-r', '--raw-exts', nargs='*',
                        default=['.arw', '.cr2', '.cr3', '.nef', '.dng', '.raf', '.orf', '.rw2', '.sr2'],
                        help="Raw file extensions to ignore during asset copy")
    args = parser.parse_args()

    # 1. Determine source and destination
    src = Path(args.source) if args.source else select_folder_dialog("Select project root")
    dst = Path(args.dest)   if args.dest   else select_folder_dialog("Select destination root")
    src, dst = src.resolve(), dst.resolve()

    # 2. Gather all files
    non_media_all, media_all = gather_files(src, args.video_exts, args.raw_exts)

    # 3. Build map: folder -> set of media stems in that folder
    media_stems_by_dir = {}
    for m in media_all:
        media_stems_by_dir.setdefault(m.parent, set()).add(m.stem.lower())

    # 4. Prepare archive folder
    archive_root = dst / f"{src.name}-265"
    archive_root.mkdir(parents=True, exist_ok=True)

    # 5. Copy non-media assets, skipping any file that shares stem with a media file in same folder
    for f in non_media_all:
        rel = f.relative_to(src)
        stem = f.stem.lower()

        # Skip side‑cars that have same name as media in the same directory
        if stem in media_stems_by_dir.get(f.parent, set()):
            print(f"🔕 Skipping side‑car asset: {rel}")
            continue

        # Copy if not already present with correct size
        outp = archive_root / rel
        outp.parent.mkdir(parents=True, exist_ok=True)
        if outp.exists() and outp.stat().st_size == f.stat().st_size:
            print(f"⏭️ Skipping existing: {rel}")
            continue

        shutil.copy2(f, outp)
        print(f"📋 Copied asset: {rel}")

    # 6. Initialize Resolve
    resolve_bundle = init_resolve()
    if not resolve_bundle:
        sys.exit(1)

    # 7. Transcode each media file
    for clip_path in media_all:
        # Skip proxies and raw files if desired (media_all already excludes proxies by design)
        if not transcode_with_resolve(resolve_bundle, clip_path, src, archive_root):
            print(f"⚠️ Failed to transcode: {clip_path.relative_to(src)}")

    print("\n✅ Archive & transcode complete!")

    # ── Prevent the window from closing immediately ──
    if IS_WIN:
        # on Windows, this will show "Press any key to continue . . ."
        os.system("pause")
    else:
        # on macOS/Linux, wait for Enter
        input("Press Enter to exit…")