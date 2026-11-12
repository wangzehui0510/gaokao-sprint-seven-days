"""把已验收的整理帧安装到正式目录，并分离教室空壳与原桌椅。"""

import hashlib
import json
import shutil
from pathlib import Path

from PIL import Image


def install() -> None:
    """保留原稿和草稿隔离，只复制curated索引所声明的最终帧。"""
    root = Path(__file__).resolve().parents[1]
    batch = root / "assets/pixel/student01/animation_batches/2026-11-11"
    destination = root / "assets/pixel/student01/animations"
    source_manifest = batch / "curated_manifest.json"
    manifest = json.loads(source_manifest.read_text(encoding="utf-8"))
    frame_count = 0
    for clip in manifest["clips"]:
        installed_paths = []
        for source_path in clip["frame_paths"]:
            relative = Path(source_path).relative_to("curated")
            output = destination / relative
            output.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(batch / source_path, output)
            # 正式帧必须逐字节等于整理稿，尤其保留首帧领口和衣褶补片。
            if output.read_bytes() != (batch / source_path).read_bytes():
                raise RuntimeError(f"正式动画复制不一致：{output}")
            installed_paths.append(relative.as_posix())
            frame_count += 1
        clip["frame_paths"] = installed_paths
    manifest["source_manifest_sha256"] = hashlib.sha256(source_manifest.read_bytes()).hexdigest()
    (destination / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    # 原教室四桌均覆盖48像素方区；从空地复制同相位16像素地砖，其他像素不改。
    classroom_path = root / "assets/pixel/classroom/classroom.png"
    original = Image.open(classroom_path).convert("RGBA")
    shell = original.copy()
    for left, top in [(88, 96), (248, 96), (88, 176), (248, 176)]:
        for y in range(top, top + 48):
            for x in range(left, left + 48):
                shell.putpixel((x, y), original.getpixel((160 + x % 16, 64 + y % 16)))
    shell.save(classroom_path.with_name("classroom_shell.png"))
    print(f"正式动画已安装：{len(manifest['clips'])}组，{frame_count}帧")


if __name__ == "__main__":
    install()
