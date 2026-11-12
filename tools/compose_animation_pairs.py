"""按显式场景计划合成真实动画帧，输出待人工核验的双人接触预览。"""

import argparse
import hashlib
import json
import re
from datetime import datetime, timezone
from pathlib import Path

from PIL import Image, ImageColor, ImageDraw, ImageFont

from review_pixel_animations import DEFAULT_FONT, load_frame, positive_integer, read_manifest, review_clip


def digest(path):
    """记录真实文件摘要，供复现时核对输入与合成结果。"""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def integer_pair(value, context, positive=False):
    """在入口验证二维整数坐标或尺寸，后续合成不再猜测缺失值。"""
    if not isinstance(value, list) or len(value) != 2 or any(type(number) is not int for number in value):
        raise ValueError(f"{context} 必须是整数二元数组")
    if positive:
        for number in value:
            positive_integer(number, context)
    return value


def declared_color(value, context):
    """解析计划明确指定的颜色，透明色可用八位十六进制表示。"""
    if not isinstance(value, str) or not value:
        raise ValueError(f"{context} 必须是明确的颜色字符串")
    try:
        return ImageColor.getcolor(value, "RGBA")
    except ValueError as error:
        raise ValueError(f"{context} 颜色无效：{value}") from error


def validate_scenes(plan, sources):
    """一次性校验场景、索引、真实尺寸及边界，禁止隐式截断或自动补帧。"""
    scenes = plan.get("scenes")
    if not isinstance(scenes, list) or not scenes:
        raise ValueError("计划 scenes 必须为非空数组")
    identifiers = set()
    validated = []
    for number, scene in enumerate(scenes):
        context = f"scenes[{number}]"
        if not isinstance(scene, dict):
            raise ValueError(f"{context} 必须是对象")
        for key in ("id", "label"):
            if not isinstance(scene.get(key), str) or not scene[key].strip():
                raise ValueError(f"{context}.{key} 必须是非空字符串")
        if not re.fullmatch(r"[A-Za-z0-9_-]+", scene["id"]):
            raise ValueError(f"{context}.id 只能包含字母、数字、下划线和连字符")
        if scene["id"] in identifiers:
            raise ValueError(f"场景ID重复：{scene['id']}")
        identifiers.add(scene["id"])
        canvas = integer_pair(scene.get("canvas"), f"{context}.canvas", positive=True)
        if type(scene.get("loop")) is not bool:
            raise ValueError(f"{context}.loop 必须是布尔值")
        background = declared_color(scene.get("background_color"), f"{context}.background_color")
        rectangles = scene.get("static_rectangles")
        if not isinstance(rectangles, list):
            raise ValueError(f"{context}.static_rectangles 必须是数组，可为空")
        prepared_rectangles = []
        for index, rectangle in enumerate(rectangles):
            label = f"{context}.static_rectangles[{index}]"
            if not isinstance(rectangle, dict):
                raise ValueError(f"{label} 必须是对象")
            coordinates = rectangle.get("rect")
            if not isinstance(coordinates, list) or len(coordinates) != 4 or any(type(value) is not int for value in coordinates):
                raise ValueError(f"{label}.rect 必须是整数 [x0,y0,x1,y1]")
            x0, y0, x1, y1 = coordinates
            if not (0 <= x0 < x1 <= canvas[0] and 0 <= y0 < y1 <= canvas[1]):
                raise ValueError(f"{label}.rect 非空且须完整位于画布内，右下边界不含")
            fill = declared_color(rectangle.get("fill"), f"{label}.fill")
            outline = declared_color(rectangle["outline"], f"{label}.outline") if rectangle.get("outline") is not None else None
            prepared_rectangles.append({"rect": coordinates, "fill": fill, "outline": outline})
        actors = scene.get("actors")
        if not isinstance(actors, list) or not actors:
            raise ValueError(f"{context}.actors 必须是非空数组")
        prepared_actors = []
        frame_count = None
        for index, actor in enumerate(actors):
            label = f"{context}.actors[{index}]"
            if not isinstance(actor, dict) or actor.get("clip_id") not in sources:
                raise ValueError(f"{label}.clip_id 必须指向源清单已有片段")
            position = integer_pair(actor.get("position"), f"{label}.position")
            indices = actor.get("frame_indices")
            source = sources[actor["clip_id"]]
            if not isinstance(indices, list) or not indices or any(type(value) is not int or value < 0 or value >= len(source["paths"]) for value in indices):
                raise ValueError(f"{label}.frame_indices 必须是非空、合法的零起始源帧索引")
            if frame_count is None:
                frame_count = len(indices)
            elif len(indices) != frame_count:
                raise ValueError(f"{context} 的各actor.frame_indices必须等长，不自动补帧或截短")
            frames = []
            for source_index in indices:
                path = source["paths"][source_index]
                image = load_frame(path)
                if path.read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
                    raise ValueError(f"合成源帧必须是真实PNG：{path}")
                if position[0] < 0 or position[1] < 0 or position[0] + image.width > canvas[0] or position[1] + image.height > canvas[1]:
                    raise ValueError(f"{label} 源帧{source_index}超出合成画布，将发生裁切，必须修正计划：{path}")
                frames.append(image)
            prepared_actors.append({"declaration": actor, "source": source, "images": frames})
        duration = scene.get("duration_ms")
        if type(duration) is int:
            durations = [positive_integer(duration, f"{context}.duration_ms")] * frame_count
        elif isinstance(duration, list) and len(duration) == frame_count:
            durations = [positive_integer(value, f"{context}.duration_ms") for value in duration]
        else:
            raise ValueError(f"{context}.duration_ms 必须是正整数或与合成帧数等长的正整数数组")
        validated.append({"declaration": scene, "background": background, "rectangles": prepared_rectangles,
                          "actors": prepared_actors, "frame_count": frame_count, "durations": durations})
    return validated


def compose_scene(scene, output):
    """只按计划位置与索引叠加真实像素，返回每帧来源证据和待审清单条目。"""
    declaration = scene["declaration"]
    directory = output / declaration["id"]
    directory.mkdir(parents=True, exist_ok=True)
    base = Image.new("RGBA", tuple(declaration["canvas"]), scene["background"])
    draw = ImageDraw.Draw(base)
    # 家具示意矩形在角色之前绘制；右下边界不含，保持与清单包围盒一致。
    for rectangle in scene["rectangles"]:
        x0, y0, x1, y1 = rectangle["rect"]
        draw.rectangle((x0, y0, x1 - 1, y1 - 1), fill=rectangle["fill"], outline=rectangle["outline"])
    frames = []
    provenance = []
    for frame_index in range(scene["frame_count"]):
        composite = base.copy()
        actor_sources = []
        # 数组先后就是图层顺序，不替用户猜测前后景或同步时间。
        for actor_number, actor in enumerate(scene["actors"]):
            actor_data = actor["declaration"]
            source_index = actor_data["frame_indices"][frame_index]
            source_path = actor["source"]["paths"][source_index]
            composite.alpha_composite(actor["images"][frame_index], tuple(actor_data["position"]))
            actor_sources.append({
                "actor_index": actor_number, "clip_id": actor_data["clip_id"], "position": actor_data["position"],
                "source_frame_index": source_index, "source_path": str(source_path), "source_sha256": digest(source_path),
                "source_duration_ms": actor["source"]["durations"][source_index],
                "source_canvas": list(actor["images"][frame_index].size),
            })
        relative = Path(declaration["id"]) / f"frame_{frame_index:02d}.png"
        path = output / relative
        composite.save(path, format="PNG")
        frames.append(relative.as_posix())
        provenance.append({"output_frame_index": frame_index, "duration_ms": scene["durations"][frame_index],
                           "output_path": str(path), "output_sha256": digest(path), "actors": actor_sources})
    record = {
        "id": declaration["id"], "label": declaration["label"], "direction": "paired",
        "canvas": declaration["canvas"], "anchor": None, "frame_paths": frames,
        "duration_ms": scene["durations"], "loop": declaration["loop"],
        "review_status": "paired_contact_pending", "category": "双人接触",
        "notes": "真实源帧按计划合成，仅为接触与站位待审预览；没有插帧、镜像、拉伸或自动批准。",
    }
    evidence = {
        "id": declaration["id"], "label": declaration["label"], "review_status": "paired_contact_pending",
        "canvas": declaration["canvas"], "background_color": declaration["background_color"],
        "static_rectangles": declaration["static_rectangles"], "actors": declaration["actors"],
        "pixel_operations": ["declared_background", "declared_static_rectangles", "ordered_rgba_alpha_composite"],
        "source_pixels_resampled": False, "source_frames_interpolated": False, "frames": provenance,
    }
    return record, evidence


def main():
    """在独立输出目录合成并调用已有检查流程，失败直接报出，不触碰生产帧。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--font", type=Path, default=Path(DEFAULT_FONT))
    parser.add_argument("--scale", type=int, default=4)
    parser.add_argument("--columns", type=int, default=4)
    args = parser.parse_args()
    positive_integer(args.scale, "--scale")
    positive_integer(args.columns, "--columns")
    plan_path = args.plan.resolve(strict=True)
    plan = json.loads(plan_path.read_text(encoding="utf-8-sig"))
    if not isinstance(plan, dict) or not isinstance(plan.get("manifest_path"), str) or not plan["manifest_path"]:
        raise ValueError("计划必须声明manifest_path字符串")
    manifest_path = Path(plan["manifest_path"])
    if not manifest_path.is_absolute():
        manifest_path = plan_path.parent / manifest_path
    manifest_path = manifest_path.resolve(strict=True)
    _, validated, _ = read_manifest(manifest_path, None)
    sources = {item["manifest"]["id"]: item for item in validated}
    scenes = validate_scenes(plan, sources)
    output = args.output_dir.resolve() if args.output_dir else plan_path.parent / "paired_review"
    font_path = args.font.resolve(strict=True)
    font = ImageFont.truetype(str(font_path), 18)
    # 合成结果与预览不能覆盖任何真实输入；所有写入路径在写入前集中核对。
    inputs = {plan_path, manifest_path, font_path} | {path for item in validated for path in item["paths"]}
    destinations = {output / "pairs_manifest.json", output / "composition_sources.json", output / "review" / "review.json"}
    for scene in scenes:
        identifier = scene["declaration"]["id"]
        destinations.update(output / identifier / f"frame_{index:02d}.png" for index in range(scene["frame_count"]))
        destinations.update(output / "review" / identifier / name for name in ("strip.png", "contact_sheet.png", "preview.gif", "metrics.json"))
    collisions = inputs & destinations
    if collisions:
        raise ValueError(f"输出会覆盖真实输入：{sorted(str(path) for path in collisions)}")
    output.mkdir(parents=True, exist_ok=True)
    results = [compose_scene(scene, output) for scene in scenes]
    manifest = {"schema_version": 1, "clips": [record for record, _ in results]}
    pairs_path = output / "pairs_manifest.json"
    pairs_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    provenance = {
        "schema_version": 1, "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "plan_path": str(plan_path), "plan_sha256": digest(plan_path),
        "source_manifest_path": str(manifest_path), "source_manifest_sha256": digest(manifest_path),
        "review_status": "paired_contact_pending", "visual_approval": "not_assessed_by_script",
        "rectangle_convention": "left_top_inclusive_right_bottom_exclusive",
        "actor_layer_order": "actors_array_back_to_front", "scenes": [evidence for _, evidence in results],
    }
    (output / "composition_sources.json").write_text(json.dumps(provenance, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    _, pairs, _ = read_manifest(pairs_path, None)
    reviews = [review_clip(clip, output / "review" / clip["manifest"]["id"], args.scale, args.columns, font) for clip in pairs]
    review = {"schema_version": 1, "manifest_path": str(pairs_path), "manifest_sha256": digest(pairs_path),
              "visual_approval": "not_assessed_by_script", "review_status": "paired_contact_pending",
              "clip_count": len(reviews), "clips": reviews}
    (output / "review" / "review.json").write_text(json.dumps(review, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"pairs_manifest": str(pairs_path), "source_report": str(output / "composition_sources.json"),
                      "scene_count": len(results), "frame_count": sum(len(record["frame_paths"]) for record, _ in results),
                      "review_status": "paired_contact_pending", "visual_approval": "not_assessed_by_script"}, ensure_ascii=False))


if __name__ == "__main__":
    main()
