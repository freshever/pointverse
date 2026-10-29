"""Fail closed when the explicitly selected external model volume is unavailable."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess


def model_storage_ready(model_root,volume='',volume_uuid='',minimum_free=10*(1<<30)):
    try:
        root=Path(model_root)
        if volume:
            mount=Path(volume)
            if not volume_uuid or not os.path.ismount(mount):return False
            info=plistlib.loads(subprocess.check_output(['diskutil','info','-plist',str(mount)],stderr=subprocess.DEVNULL,timeout=5))
            if info.get('VolumeUUID')!=volume_uuid or info.get('MountPoint')!=str(mount) or info.get('Internal') is not False:return False
            if not root.resolve().is_relative_to(mount.resolve()):return False
        return root.is_dir() and shutil.disk_usage(root).free>=minimum_free
    except (OSError,ValueError,subprocess.SubprocessError):return False
