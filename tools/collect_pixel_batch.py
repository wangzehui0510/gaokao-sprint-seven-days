"""下载PixelLab已明确完成的真实输出，并生成待人工检查的动画清单。"""

import argparse
import json
from pathlib import Path
from urllib.request import urlopen

from PIL import Image


def collect(log_path: Path) -> None:
    """按服务返回的帧数下载；失败直接抛出，不以占位图替代。"""
    production = json.loads(log_path.read_text(encoding="utf-8-sig"))
    root = log_path.parent
    clips = []
    for job in production["jobs"]:
        if job.get("status") != "completed":
            continue
        target = root / "raw" / job["id"]
        target.mkdir(parents=True, exist_ok=True)
        paths = []
        for index in range(job["output_count"]):
            path = target / f"frame_{index:02}.png"
            if not path.exists():
                # 使用服务回执中的下载入口；索引顺序包含原始输入帧。
                url = job["download_url"] + f"?index={index}"
                with urlopen(url, timeout=60) as response:
                    path.write_bytes(response.read())
            with Image.open(path) as source:
                source.verify()
            paths.append(path.relative_to(root).as_posix())
        # 整段动画修订同样保留帧序，纳入原稿检查清单；关键帧图片不混入。
        if job["tool"] not in {"animate", "edit_animation"}:
            continue
        clips.append({
            "id": job["id"], "label": job.get("label", job["id"]),
            "direction": job.get("direction", job["id"].split("_")[-1]),
            "frame_paths": paths, "duration_ms": job.get("duration_ms", 160),
            "canvas": job.get("canvas", [32, 48]),
            "anchor": job.get("anchor", [16, 44]),
            "loop": job.get("loop", True), "review_status": "pending_visual_review",
        })
    destination = root / "raw_review_manifest.json"
    destination.write_text(json.dumps({"schema_version": 1, "clips": clips}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"manifest": str(destination), "completed_clips": len(clips)}, ensure_ascii=False))


def main() -> None:
    """读取指定生产日志，下载完成任务并导出检查清单。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", required=True, type=Path)
    args = parser.parse_args()
    collect(args.log)


if __name__ == "__main__":
    main()
