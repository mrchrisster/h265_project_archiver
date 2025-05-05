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

PREREQUISITES: To force mono audio tracks on timeline creation,
set DaVinci → Preferences → User → Edit → Audio → Timeline Audio Tracks → Mono
"""

import os
import sys
import shutil
import argparse
import subprocess
import time
from pathlib import Path

# Optional: PyAV integrity check
try:
    import av
    HAVE_PYAV = True
except ImportError:
    HAVE_PYAV = False
    print("⚠️ PyAV not installed; using FFmpeg CLI for integrity checks.")

# —— Resolve paths ——
RESOLVE_PY_MODULE       = r"C:\ProgramData\Blackmagic Design\DaVinci Resolve\Support\Developer\Scripting\Modules"
RESOLVE_DLL_PATH        = r"C:\Program Files\Blackmagic Design\DaVinci Resolve"
RESOLVE_EXE_PATH        = r"C:\Program Files\Blackmagic Design\DaVinci Resolve\Resolve.exe"

PROJECT_NAME            = "Batch_H265"
DRP_PATH                = r"C:\code\davinci_encoder\Batch_H265.drp"
PRESET_XML_PATH         = r"C:\code\davinci_encoder\Batch_H265_RenderSettings.xml"
PRESET_NAME             = Path(PRESET_XML_PATH).stem
drx_file                = Path(r"C:\code\davinci_encoder\rawfix.drx")
DRT_TEMPLATE_MONO       = r"C:\code\davinci_encoder\Template_Mono_1ch.drt"
DRT_TEMPLATE_STEREO     = r"C:\code\davinci_encoder\Template_Stereo_2ch.drt"


def is_resolve_running():
    try:
        out = subprocess.check_output(['tasklist', '/FI', 'IMAGENAME eq Resolve.exe'], text=True)
        return 'Resolve.exe' in out
    except Exception:
        return False


def init_resolve():
    if not is_resolve_running():
        print("🔄 Resolve not running; launching...")
        if not os.path.isfile(RESOLVE_EXE_PATH):
            print(f"❌ Cannot find Resolve executable at: {RESOLVE_EXE_PATH}")
            return None
        subprocess.Popen([RESOLVE_EXE_PATH])
    else:
        print("ℹ️ Resolve already running.")

    sys.path.insert(0, RESOLVE_PY_MODULE)
    os.add_dll_directory(RESOLVE_DLL_PATH)
    import DaVinciResolveScript as dvr

    print("⏳ Waiting for Resolve scripting API...", end="", flush=True)
    resolve = None
    for _ in range(30):
        resolve = dvr.scriptapp("Resolve")
        if resolve:
            break
        print(".", end="", flush=True)
        time.sleep(1)
    print()
    if not resolve:
        print("❌ Failed to connect to Resolve.")
        return None
    print("✅ Connected to Resolve.")

    pm = resolve.GetProjectManager()
    if PROJECT_NAME not in (pm.GetProjectListInCurrentFolder() or []):
        print(f"📦 Importing .drp as '{PROJECT_NAME}' from: {DRP_PATH}")
        if not os.path.isfile(DRP_PATH) or not pm.ImportProject(DRP_PATH, PROJECT_NAME):
            print(f"❌ Failed to import .drp at {DRP_PATH}")
            return None
    else:
        print(f"ℹ️ Project '{PROJECT_NAME}' already exists.")

    if not pm.LoadProject(PROJECT_NAME):
        print(f"❌ Failed to load project '{PROJECT_NAME}'")
        return None

    project = pm.GetCurrentProject()
    print(f"✅ Using project: '{project.GetName()}'")
    resolve.OpenPage("deliver")
    time.sleep(1)

    for p in project.GetRenderPresetList() or []:
        if p == PRESET_NAME:
            project.DeleteRenderPreset(PRESET_NAME)
            print(f"🗑️ Deleted existing preset '{PRESET_NAME}'")
            break

    if not os.path.isfile(PRESET_XML_PATH):
        print(f"❌ Preset XML not found: {PRESET_XML_PATH}")
        return None
    if not resolve.ImportRenderPreset(PRESET_XML_PATH):
        print("⚠️ XML preset import may have failed.")
    else:
        print(f"✅ Loaded render preset '{PRESET_NAME}'")

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
    vset = {e.lower() for e in video_exts}
    rset = {e.lower() for e in raw_exts}
    non_media, media = [], []
    for root, _, files in os.walk(src):
        for f in files:
            p = Path(root) / f
            if p.suffix.lower() in vset or p.suffix.lower() in rset:
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


def transcode_with_resolve(resolve_bundle, clip_path: Path, src_root: Path, archive_root: Path) -> bool:
    resolve, pm, project = resolve_bundle
    base = clip_path.stem
    rel = clip_path.relative_to(src_root) if src_root in clip_path.parents else Path(base)

    out_folder = archive_root / rel.parent
    out_folder.mkdir(parents=True, exist_ok=True)
    out_file = out_folder / f"{base}.mp4"

    if out_file.exists() and is_readable(out_file):
        print(f"✅ Skipping (exists & OK): {rel}")
        return True
    elif out_file.exists():
        print(f"⚠️ Corrupt, deleting: {rel}")
        out_file.unlink()

    mp = project.GetMediaPool()
    storage = resolve.GetMediaStorage()
    project.DeleteAllRenderJobs()
    for i in range(1, project.GetTimelineCount()+1):
        tl = project.GetTimelineByIndex(i)
        if tl: mp.DeleteTimelines([tl])
    clips = mp.GetRootFolder().GetClipList() or []
    if clips: mp.DeleteClips(clips)
    print("🧹 Resolve cleaned.")

    print(f"📥 Importing: {clip_path}")
    items = storage.AddItemListToMediaPool([str(clip_path)])
    time.sleep(2)
    if not items:
        print(f"❌ Import failed: {clip_path}")
        return False
    clip = items[0]

    channels, layout = get_audio_info(clip)
    props = clip.GetClipProperty()
    w, h = map(int, props['Resolution'].split('x'))
    fps = f"{float(props.get('FPS') or props.get('Frame rate')):.6f}".rstrip('0').rstrip('.')

    # Improved stereo detection
    use_stereo = (
        channels == 2 and (
            layout == "" or "stereo" in layout
        )
    )

    drt_path = DRT_TEMPLATE_STEREO if use_stereo else DRT_TEMPLATE_MONO

    print(f"🎧 Detected {channels}ch ({layout if layout else 'unknown'}); using {'stereo' if use_stereo else 'mono'} template")


    tl_name = f"TL_{base}"
    timeline = mp.ImportTimelineFromFile(drt_path, {
        "timelineName": tl_name,
        "importSourceClips": False
    })
    if not timeline:
        print(f"❌ Failed to import template: {drt_path}")
        return False
        
    timeline.SetSetting("timelineResolutionWidth", str(w))
    timeline.SetSetting("timelineResolutionHeight", str(h))
    timeline.SetSetting("timelineFrameRate", fps)
    timeline.SetSetting("timelinePlaybackFrameRate", fps)

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
                print(f"🗑️ Deleted empty {track_type} track {i}")

    project.LoadRenderPreset(PRESET_NAME)
    project.SetRenderSettings({
        'TargetDir': str(out_folder),
        'CustomName': base,
    })

    if drx_file.exists():
        resolve.OpenPage("color")
        time.sleep(1)
        for vc in project.GetCurrentTimeline().GetItemListInTrack('video', 1) or []:
            fn = getattr(vc.GetNodeGraph(), 'ApplyGradeFromDRX', None)
            if callable(fn) and fn(str(drx_file), 0):
                print(f"✅ Applied grade to {vc.GetName()}")

    job_id = project.AddRenderJob()
    if not job_id:
        print(f"❌ Failed to queue render for {base}")
        return False
    print(f"🚀 Rendering: {rel}")
    project.StartRendering()
    while project.IsRenderingInProgress():
        time.sleep(1)
    print(f"🏁 Completed render: {rel}")

    if is_readable(out_file):
        print(f"✅ Integrity OK: {rel}")
        return True
    print(f"⚠️ Integrity still failed: {rel}")
    return False


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="Archive & transcode via Resolve")
    parser.add_argument('-s', '--source', help="Project root folder")
    parser.add_argument('-d', '--dest', help="Destination root folder")
    parser.add_argument('-v', '--video-exts', nargs='*',
                        default=['.mxf', '.mp4', '.mov', '.crm', '.avi'])
    parser.add_argument('-r', '--raw-exts', nargs='*',
                        default=['.arw', '.cr2', '.cr3', '.nef', '.dng', '.raf', '.orf', '.rw2', '.sr2'])
    args = parser.parse_args()

    src = Path(args.source) if args.source else select_folder_dialog("Select project root")
    dst = Path(args.dest) if args.dest else select_folder_dialog("Select destination root")
    src, dst = src.resolve(), dst.resolve()

    non_media_all, media_all = gather_files(src, args.video_exts, args.raw_exts)
    media = [m for m in media_all if 'proxy' not in (p.lower() for p in m.parts) and not m.stem.lower().endswith('_proxy')]
    archive_root = dst / f"{src.name}-265"
    archive_root.mkdir(parents=True, exist_ok=True)

    media_basenames = {m.stem for m in media_all}
    for f in non_media_all:
        rel = f.relative_to(src)
        if f.stem in media_basenames:
            print(f"🔕 Skipping asset (same base as media): {rel}")
            continue
        outp = archive_root / rel
        outp.parent.mkdir(parents=True, exist_ok=True)
        if outp.exists() and outp.stat().st_size == f.stat().st_size:
            print(f"⏭️ Skipping (exists): {rel}")
            continue
        shutil.copy2(f, outp)
        print(f"📋 Copied asset: {rel}")

    resolve_bundle = init_resolve()
    if not resolve_bundle:
        sys.exit(1)

    for m in media:
        if not transcode_with_resolve(resolve_bundle, m, src, archive_root):
            print(f"⚠️ Failed to transcode: {m.relative_to(src)}")

    print("\n✅ Archive & transcode complete!")
