"""执行已人工确认的像素修订，导出动画与可追溯的检查清单。"""

import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image, ImageOps


def translate_without_clipping(image: Image.Image, offset: list[int]) -> Image.Image:
    """按人工确认的整数位移归位，若会裁掉可见像素则直接报错。"""
    dx, dy = offset
    bounds = image.getbbox()
    if bounds and not (0 <= bounds[0] + dx < bounds[2] + dx <= image.width
                       and 0 <= bounds[1] + dy < bounds[3] + dy <= image.height):
        raise ValueError(f"整数归位会裁切可见像素：{bounds}，位移 {offset}")
    result = Image.new("RGBA", image.size)
    result.paste(image, (dx, dy))
    return result


def curate(plan_path: Path) -> None:
    """按明确清单选帧、局部复制、锁区或镜像，不自动批准任何结果。"""
    root = plan_path.parent
    plan = json.loads(plan_path.read_text(encoding="utf-8-sig"))
    raw = json.loads((root / "raw_review_manifest.json").read_text(encoding="utf-8"))
    sources = {clip["id"]: clip for clip in raw["clips"]}
    clips, evidence = [], []
    for entry in plan["clips"]:
        source = sources[entry["source_clip_id"]]
        target = root / "curated" / entry["id"]
        target.mkdir(parents=True, exist_ok=True)
        images = [Image.open(root / name).convert("RGBA") for name in source["frame_paths"]]
        paths, records = [], []
        for frame_number, index in enumerate(entry["selected_indexes"]):
            image = images[index].copy()
            # 锁定范围由逐帧检查后手动给定，保留源关键帧的固定物体或接触点。
            for rectangle in entry.get("lock_regions", []):
                image.paste(images[0].crop(tuple(rectangle)), tuple(rectangle[:2]))
            # 仅在指定输出帧复制已目检的源局部，例如补齐首帧缺失的固定衣褶。
            for repair in entry.get("copy_regions", []):
                if frame_number in repair["target_frames"]:
                    rectangle = repair["region"]
                    image.paste(images[repair["source_index"]].crop(tuple(rectangle)), tuple(rectangle[:2]))
            for rectangle in entry.get("clear_regions", []):
                # 只清除人工圈定、与角色不相交的附加特效，原始输出保留。
                image.paste((0, 0, 0, 0), tuple(rectangle))
            if entry.get("mirror_horizontal", False):
                image = ImageOps.mirror(image)
            if "translate" in entry:
                image = translate_without_clipping(image, entry["translate"])
            destination = target / f"frame_{frame_number:02}.png"
            image.save(destination)
            paths.append(destination.relative_to(root).as_posix())
            records.append({"source_index": index, "source_path": source["frame_paths"][index],
                            "source_sha256": hashlib.sha256((root / source["frame_paths"][index]).read_bytes()).hexdigest(),
                            "output_sha256": hashlib.sha256(destination.read_bytes()).hexdigest()})
        clips.append({"id": entry["id"], "label": entry["label"], "direction": entry["direction"],
                      "frame_paths": paths, "duration_ms": entry["duration_ms"],
                      "canvas": source["canvas"], "anchor": entry.get("anchor", source["anchor"]),
                      "loop": entry["loop"], "review_status": entry["review_status"],
                      "family": entry["id"].split("_")[0],
                      "notes": entry.get("notes", ""),
                      "source_clip_id": source["id"]})
        evidence.append({**entry, "frames": records})
    (root / "curated_manifest.json").write_text(json.dumps({"schema_version": 1, "clips": clips}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (root / "curation_provenance.json").write_text(json.dumps({"schema_version": 1, "clips": evidence}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"curated_clips": len(clips), "manifest": str(root / "curated_manifest.json")}, ensure_ascii=False))


def main() -> None:
    """读取人工检查决定并导出，不接触正式游戏资源索引。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", required=True, type=Path)
    args = parser.parse_args()
    curate(args.plan)


if __name__ == "__main__":
    main()
