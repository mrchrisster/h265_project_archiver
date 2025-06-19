#!/usr/bin/env python3
"""
test_full_timecode_roundtrip.py

1) Import a clip and read its Start TC
2) Create a timeline, apply that TC, append the clip
3) Render to MP4 via your preset
4) Use ffprobe to verify the MP4’s embedded timecode matches
"""

import os
import sys
import time
import platform
import subprocess
from pathlib import Path

# ── CONFIG ────────────────────────────────────────────────────────────────
CLIP_PATH          = Path(r"D:\raw_test\A028C753_180823CW_CANON.CRM")
DRT_TEMPLATE_MONO  = Path(r"C:\code\davinci_encoder\Template_Mono_1ch.drt")
PRESET_XML_PATH    = Path(r"C:\code\davinci_encoder\Batch_H265_RenderSettings.xml")
PROJECT_NAME       = "TC_Roundtrip_Test"
DRP_PATH           = ""  # leave empty if you just want to create a new project
OUTPUT_DIR         = Path(r"D:\raw_test\tc_test_output")
OUTPUT_DIR.mkdir(exist_ok=True, parents=True)
# ───────────────────────────────────────────────────────────────────────────

# Resolve API paths
IS_MAC = platform.system() == "Darwin"
IS_WIN = platform.system() == "Windows"
if IS_MAC:
    RESOLVE_PY_MODULE = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting/Modules"
elif IS_WIN:
    RESOLVE_PY_MODULE = r"C:\ProgramData\Blackmagic Design\DaVinci Resolve\Support\Developer\Scripting\Modules"
else:
    sys.exit("❌ Unsupported OS")

sys.path.insert(0, RESOLVE_PY_MODULE)
try:
    import DaVinciResolveScript as dvr
except ImportError as e:
    print("❌ Could not import DaVinciResolveScript:", e)
    sys.exit(1)

def init_resolve():
    print("⏳ Connecting to Resolve...", end="", flush=True)
    resolve = None
    for _ in range(30):
        resolve = dvr.scriptapp("Resolve")
        if resolve:
            break
        print(".", end="", flush=True)
        time.sleep(1)
    print()
    if not resolve:
        print("❌ Resolve not running.")
        return None

    pm = resolve.GetProjectManager()
    # import or create test project
    if PROJECT_NAME not in (pm.GetProjectListInCurrentFolder() or []):
        if DRP_PATH:
            pm.ImportProject(str(DRP_PATH), PROJECT_NAME)
        else:
            pm.CreateProject(PROJECT_NAME)
    pm.LoadProject(PROJECT_NAME)
    project = pm.GetCurrentProject()
    resolve.OpenPage("deliver")
    time.sleep(1)
    return resolve, project

def get_timecode_from_clip(clip):
    props = clip.GetClipProperty()
    return props.get("Start TC") or props.get("Start Timecode")

def get_timecode_from_mp4(mp4_path: Path):
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

if __name__ == '__main__':
    bundle = init_resolve()
    if not bundle:
        sys.exit(1)
    resolve, project = bundle
    mp      = project.GetMediaPool()
    storage = resolve.GetMediaStorage()

    # 1) Import clip
    print(f"📥 Importing clip: {CLIP_PATH}")
    items = storage.AddItemListToMediaPool([str(CLIP_PATH)])
    time.sleep(1)
    if not items:
        print("❌ Failed to import clip.")
        sys.exit(1)
    clip = items[0]

    # 2) Read source TC
    source_tc = get_timecode_from_clip(clip)
    if not source_tc:
        print("⚠️ No Start TC in clip.")
        sys.exit(1)
    print("🔎 Source Start TC:", source_tc)

    # 3) Create timeline from template
    tl_name = "TC_Roundtrip_TL"
    print(f"📂 Importing timeline template: {DRT_TEMPLATE_MONO}")
    timeline = mp.ImportTimelineFromFile(str(DRT_TEMPLATE_MONO), {
        "timelineName": tl_name, "importSourceClips": False
    })
    if not timeline:
        print("❌ Failed to import timeline template.")
        sys.exit(1)

    # 4) Apply Start TC to timeline
    ok = timeline.SetStartTimecode(source_tc)
    print("✅ SetStartTimecode returned:", ok)

    # 5) Append clip
    if not mp.AppendToTimeline([clip]):
        print("❌ Failed to append clip.")
        sys.exit(1)

    # 6) (Re)import render preset
    preset_name = Path(PRESET_XML_PATH).stem
    existing = project.GetRenderPresetList() or []

    # If it already exists, delete it so we can re-import cleanly
    if preset_name in existing:
        project.DeleteRenderPreset(preset_name)
        print(f"🗑️ Deleted existing preset '{preset_name}'")

    ok = resolve.ImportRenderPreset(str(PRESET_XML_PATH))
    print(f"ImportRenderPreset returned: {ok}")

    # Load it (whether freshly imported or just recreated)
    if preset_name in project.GetRenderPresetList() or ok:
        project.LoadRenderPreset(preset_name)
        print(f"✅ Loaded render preset '{preset_name}'")
    else:
        print(f"❌ Preset '{preset_name}' not available; using default settings")

    # 7) Override only output folder & filename
    project.SetRenderSettings({
        'TargetDir': str(OUTPUT_DIR),
        'CustomName': clip.GetName()
    })


    # 7) Render
    job_id = project.AddRenderJob()
    project.StartRendering()
    print("🚀 Rendering…")
    while project.IsRenderingInProgress():
        time.sleep(1)
    print("🏁 Render complete.")

    # 8) Check MP4 TC
    rendered_mp4 = OUTPUT_DIR / f"{clip.GetName()}.mp4"
    mp4_tc = get_timecode_from_mp4(rendered_mp4)
    if mp4_tc:
        print("▶️ Rendered MP4 timecode:", mp4_tc)
        if mp4_tc == source_tc:
            print("🎉 SUCCESS: MP4 TC matches source TC!")
        else:
            print("❌ MISMATCH: MP4 TC differs from source.")
    else:
        print("⚠️ No timecode tag found in MP4 (or ffprobe missing).")
