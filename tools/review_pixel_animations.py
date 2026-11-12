"""从真实动画帧导出像素预览和客观指标；视觉是否通过始终由人工判断。"""

import argparse
import hashlib
import json
import math
import re
from datetime import datetime, timezone
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


# 预览使用固定中性色棋盘；原始横条不加背景，也不修改任何源文件。
BACKGROUND_COLORS = ("#dce2e1", "#eef1ee")
DEFAULT_FONT = "C:/Windows/Fonts/msyh.ttc"


def positive_integer(value, context):
    """在清单入口拒绝布尔值、非整数及非正数。"""
    if type(value) is not int or value <= 0:
        raise ValueError(f"{context} 必须是正整数：{value!r}")
    return value


def source_path(value, base_dir, context):
    """显式解析清单中的真实文件，缺失时直接报告路径错误。"""
    if not isinstance(value, str) or not value:
        raise ValueError(f"{context} 必须是非空路径字符串")
    path = Path(value)
    if not path.is_absolute():
        path = base_dir / path
    path = path.resolve(strict=True)
    if not path.is_file():
        raise ValueError(f"{context} 不是文件：{path}")
    return path


def read_manifest(path, asset_root):
    """集中校验清单契约，之后的导出流程直接使用已验证的数据。"""
    manifest = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(manifest, dict) or type(manifest.get("schema_version")) is not int or manifest["schema_version"] != 1:
        raise ValueError("清单必须声明整数 schema_version=1")
    clips = manifest.get("clips")
    if not isinstance(clips, list) or not clips:
        raise ValueError("清单 clips 必须是非空数组")
    base_dir = asset_root.resolve(strict=True) if asset_root else path.parent
    if not base_dir.is_dir():
        raise ValueError(f"素材根目录不存在：{base_dir}")
    ids = set()
    validated = []
    for index, clip in enumerate(clips):
        context = f"clips[{index}]"
        if not isinstance(clip, dict):
            raise ValueError(f"{context} 必须是对象")
        for key in ("id", "label", "direction", "review_status"):
            if not isinstance(clip.get(key), str) or not clip[key].strip():
                raise ValueError(f"{context}.{key} 必须是非空字符串")
        if not re.fullmatch(r"[A-Za-z0-9_-]+", clip["id"]):
            raise ValueError(f"{context}.id 只能包含英文字母、数字、下划线和连字符")
        if clip["id"] in ids:
            raise ValueError(f"动画 id 重复：{clip['id']}")
        ids.add(clip["id"])
        canvas = clip.get("canvas")
        if not isinstance(canvas, list) or len(canvas) != 2:
            raise ValueError(f"{context}.canvas 必须是 [宽,高]")
        for value in canvas:
            positive_integer(value, f"{context}.canvas")
        anchor = clip.get("anchor")
        if anchor is not None and (not isinstance(anchor, list) or len(anchor) != 2 or any(type(value) is not int for value in anchor)):
            raise ValueError(f"{context}.anchor 必须是整数 [x,y] 或 null")
        if type(clip.get("loop")) is not bool:
            raise ValueError(f"{context}.loop 必须是布尔值")
        frame_paths = clip.get("frame_paths")
        if not isinstance(frame_paths, list) or not frame_paths:
            raise ValueError(f"{context}.frame_paths 必须是非空数组")
        paths = [source_path(value, base_dir, f"{context}.frame_paths[{number}]") for number, value in enumerate(frame_paths)]
        duration = clip.get("duration_ms")
        if type(duration) is int:
            durations = [positive_integer(duration, f"{context}.duration_ms")] * len(paths)
        elif isinstance(duration, list) and len(duration) == len(paths):
            durations = [positive_integer(value, f"{context}.duration_ms[{number}]") for number, value in enumerate(duration)]
        else:
            raise ValueError(f"{context}.duration_ms 必须是正整数或与帧数等长的正整数数组")
        reference = clip.get("reference_path")
        validated.append({"manifest": clip, "paths": paths, "durations": durations,
                          "reference": source_path(reference, base_dir, f"{context}.reference_path") if reference is not None else None})
    return manifest, validated, base_dir


def load_frame(path):
    """只在内存中解码为 RGBA，不重采样或写回源图。"""
    with Image.open(path) as source:
        if getattr(source, "n_frames", 1) != 1:
            raise ValueError(f"frame_paths 必须指向单帧图像：{path}")
        return source.convert("RGBA")


def canonical_pixels(image):
    """比较时忽略完全透明像素中不可见的 RGB，保留所有可见颜色与透明度。"""
    return [(red, green, blue, alpha) if alpha else (0, 0, 0, 0)
            for red, green, blue, alpha in image.get_flattened_data()]


def frame_metrics(path, image, canvas, anchor):
    """记录尺寸、颜色、透明轮廓与边缘接触；接触边缘只表示可能裁切。"""
    pixels = list(image.get_flattened_data())
    alpha = image.getchannel("A")
    histogram = alpha.histogram()
    bbox = alpha.getbbox()
    visible = [(red, green, blue, opacity) for red, green, blue, opacity in pixels if opacity]
    edges = []
    for name, box in (("left", (0, 0, 1, image.height)), ("top", (0, 0, image.width, 1)),
                      ("right", (image.width - 1, 0, image.width, image.height)),
                      ("bottom", (0, image.height - 1, image.width, image.height))):
        if alpha.crop(box).getbbox() is not None:
            edges.append(name)
    weight = sum(opacity for _, _, _, opacity in pixels)
    centroid = None
    if weight:
        centroid = [round(sum((index % image.width) * pixel[3] for index, pixel in enumerate(pixels)) / weight, 4),
                    round(sum((index // image.width) * pixel[3] for index, pixel in enumerate(pixels)) / weight, 4)]
    return {
        "path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "dimensions": list(image.size), "matches_declared_canvas": list(image.size) == canvas,
        "visible_bbox": list(bbox) if bbox else None,
        "visible_bbox_relative_to_anchor": [bbox[0] - anchor[0], bbox[1] - anchor[1], bbox[2] - anchor[0], bbox[3] - anchor[1]] if bbox and anchor is not None else None,
        "alpha_weighted_centroid": centroid, "empty": bbox is None,
        "transparent_pixels": histogram[0], "partial_alpha_pixels": sum(histogram[1:255]),
        "opaque_pixels": histogram[255], "visible_pixels": len(visible),
        "unique_rgba_colors": len(set(pixels)), "visible_rgba_colors": len(set(visible)),
        "edge_contacts": edges, "possible_edge_clipping": bool(edges),
    }


def compare_frames(first, second, first_index, second_index):
    """测量两帧可见像素变化；不同尺寸明确标为不可逐像素比较。"""
    record = {"from_frame": first_index, "to_frame": second_index, "comparable": first.size == second.size}
    if first.size != second.size:
        return record | {"reason": "frame_dimensions_differ", "from_dimensions": list(first.size), "to_dimensions": list(second.size)}
    first_pixels, second_pixels = canonical_pixels(first), canonical_pixels(second)
    changed = [index for index, pair in enumerate(zip(first_pixels, second_pixels)) if pair[0] != pair[1]]
    bounds = None
    if changed:
        xs, ys = [index % first.width for index in changed], [index // first.width for index in changed]
        bounds = [min(xs), min(ys), max(xs) + 1, max(ys) + 1]
    return record | {
        "visible_changed_pixels": len(changed), "visible_changed_fraction": round(len(changed) / len(first_pixels), 6),
        "exact_rgba_changed_pixels": sum(a != b for a, b in zip(first.get_flattened_data(), second.get_flattened_data())),
        "changed_bbox": bounds, "visually_identical": not changed,
        "mean_absolute_rgba_difference": round(sum(abs(a - b) for left, right in zip(first_pixels, second_pixels) for a, b in zip(left, right)) / (len(first_pixels) * 4), 6),
    }


def checkerboard(size, tile):
    """生成只用于预览的棋盘底色，源 PNG 与原尺寸横条保留透明度。"""
    result = Image.new("RGB", size, BACKGROUND_COLORS[0])
    draw = ImageDraw.Draw(result)
    for y in range(0, size[1], tile):
        for x in range(0, size[0], tile):
            draw.rectangle((x, y, x + tile - 1, y + tile - 1), fill=BACKGROUND_COLORS[(x // tile + y // tile) % 2])
    return result


def fit_text(draw, text, font, max_width):
    """按预览实际宽度换行，避免中文标签在接触表标题处被截断。"""
    lines, current = [], ""
    for char in text:
        candidate = current + char
        if current and draw.textlength(candidate, font=font) > max_width:
            lines.append(current)
            current = char
        else:
            current = candidate
    lines.append(current)
    return lines


def export_previews(clip, frames, output, scale, columns, font):
    """导出横条、逐帧接触表与动图；只在预览中进行整数最近邻放大。"""
    data, durations = clip["manifest"], clip["durations"]
    cell = (max(image.width for image in frames), max(image.height for image in frames))
    output.mkdir(parents=True, exist_ok=True)
    strip = Image.new("RGBA", (cell[0] * len(frames), cell[1]))
    for index, frame in enumerate(frames):
        # 不使用透明蒙版二次混合，确保横条中各帧 RGBA 字节与源图一致。
        strip.paste(frame, (index * cell[0], 0))
    strip.save(output / "strip.png")

    shown_columns = min(columns, len(frames))
    margin, gap, label_height, line_height = 16, 12, 32, 26
    preview_size = (cell[0] * scale, cell[1] * scale)
    width = margin * 2 + shown_columns * preview_size[0] + (shown_columns - 1) * gap
    measuring = ImageDraw.Draw(Image.new("RGB", (1, 1)))
    title = f"{data['id']} · {data['label']} · {data['direction']}"
    lines = fit_text(measuring, title, font, width - margin * 2)
    header = margin * 2 + line_height * len(lines)
    height = header + math.ceil(len(frames) / shown_columns) * (preview_size[1] + label_height + gap)
    sheet = Image.new("RGB", (width, height), "#f7f8f5")
    draw = ImageDraw.Draw(sheet)
    for index, line in enumerate(lines):
        draw.text((margin, margin + index * line_height), line, font=font, fill="#21382f")
    gif_frames = []
    for index, frame in enumerate(frames):
        tile = checkerboard(preview_size, 4 * scale)
        enlarged = frame.resize((frame.width * scale, frame.height * scale), Image.Resampling.NEAREST)
        tile.paste(enlarged, (0, 0), enlarged)
        x = margin + (index % shown_columns) * (preview_size[0] + gap)
        y = header + (index // shown_columns) * (preview_size[1] + label_height + gap)
        sheet.paste(tile, (x, y))
        draw.text((x, y + preview_size[1] + 4), f"#{index:02d}  {durations[index]} ms", font=font, fill="#21382f")
        # GIF 不支持完整 RGBA；显式放到棋盘背景上，避免透明像素被隐式改色。
        gif_frames.append(tile)
    sheet.save(output / "contact_sheet.png")
    save_options = {"save_all": True, "append_images": gif_frames[1:], "duration": durations,
                    "disposal": 2, "optimize": False}
    if data["loop"]:
        save_options["loop"] = 0
    gif_frames[0].save(output / "preview.gif", **save_options)
    # 回读真实编码结果；GIF 可能合并相邻相同帧，并按 10 毫秒粒度保存时长。
    with Image.open(output / "preview.gif") as encoded:
        encoded_durations = []
        for index in range(encoded.n_frames):
            encoded.seek(index)
            encoded_durations.append(encoded.info.get("duration", 0))
        encoded_loop = encoded.info.get("loop")
    return {
        "strip": str(output / "strip.png"), "contact_sheet": str(output / "contact_sheet.png"),
        "gif": str(output / "preview.gif"), "strip_cell_canvas": list(cell),
        "strip_frame_rects": [[index * cell[0], 0, frame.width, frame.height] for index, frame in enumerate(frames)],
        "source_pixels_resampled": False, "preview_scale": scale, "preview_resampling": "nearest_neighbor",
        "gif_background": "opaque_checkerboard", "gif_encoded_frame_count": len(encoded_durations),
        "gif_requested_durations_ms": durations, "gif_encoded_durations_ms": encoded_durations,
        "gif_requested_total_duration_ms": sum(durations), "gif_encoded_total_duration_ms": sum(encoded_durations),
        "gif_encoded_loop": encoded_loop,
        "gif_encoding_note": "GIF使用10毫秒时间单位，编码器可能合并连续相同帧；逐帧表和原始横条始终保留全部输入帧。",
    }


def review_clip(clip, output, scale, columns, font):
    """为一段真实动画输出客观证据，不将指标转换为视觉批准结果。"""
    data = clip["manifest"]
    frames = [load_frame(path) for path in clip["paths"]]
    metrics = [frame_metrics(path, frame, data["canvas"], data.get("anchor")) for path, frame in zip(clip["paths"], frames)]
    adjacent = [compare_frames(frames[index], frames[index + 1], index, index + 1) for index in range(len(frames) - 1)]
    reference = None
    if clip["reference"] is not None:
        reference_image = load_frame(clip["reference"])
        reference = {"image": frame_metrics(clip["reference"], reference_image, data["canvas"], data.get("anchor")),
                     "first_frame_difference": compare_frames(reference_image, frames[0], "reference", 0)}
    artifacts = export_previews(clip, frames, output, scale, columns, font)
    flags = []
    if any(not frame["matches_declared_canvas"] for frame in metrics):
        flags.append("declared_canvas_mismatch")
    if len({tuple(frame["dimensions"]) for frame in metrics}) != 1:
        flags.append("inconsistent_frame_dimensions")
    if any(frame["empty"] for frame in metrics):
        flags.append("empty_frame")
    if any(frame["possible_edge_clipping"] for frame in metrics):
        flags.append("edge_contact_requires_visual_review")
    if any(frame["partial_alpha_pixels"] for frame in metrics):
        flags.append("partial_alpha_requires_visual_review")
    if any(pair.get("visually_identical") for pair in adjacent):
        flags.append("adjacent_identical_frames")
    first_last = compare_frames(frames[0], frames[-1], 0, len(frames) - 1)
    if len(frames) > 1 and first_last.get("visually_identical"):
        flags.append("first_last_identical")
    if artifacts["gif_requested_total_duration_ms"] != artifacts["gif_encoded_total_duration_ms"]:
        flags.append("gif_duration_changed_by_encoding")
    result = {
        "id": data["id"], "label": data["label"], "direction": data["direction"],
        "declared_canvas": data["canvas"], "anchor": data.get("anchor"), "loop": data["loop"],
        "review_status": data["review_status"], "visual_approval": "not_assessed_by_script",
        "input_frame_count": len(frames), "input_total_duration_ms": sum(clip["durations"]),
        "bbox_convention": "left_top_inclusive_right_bottom_exclusive",
        "review_flags": flags, "frames": metrics, "adjacent_differences": adjacent,
        "first_last_difference": first_last, "reference": reference, "artifacts": artifacts,
        "limitations": ["指标不能判断人体结构、服装一致性、道具语义或动作是否自然。", "边缘接触仅提示可能裁切；透明像素中不可见的RGB不计入可见变化。", "不同尺寸只在预览中以左上角放入最大画布，不修改或修复源帧。"],
    }
    (output / "metrics.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return result


def main():
    """校验所有输入并导出检查资料；错误直接报出，任何源文件均不写回。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--asset-root", type=Path)
    parser.add_argument("--scale", type=int, default=8)
    parser.add_argument("--columns", type=int, default=4)
    parser.add_argument("--font", type=Path, default=Path(DEFAULT_FONT))
    args = parser.parse_args()
    positive_integer(args.scale, "--scale")
    positive_integer(args.columns, "--columns")
    manifest_path = args.manifest.resolve(strict=True)
    manifest, clips, base_dir = read_manifest(manifest_path, args.asset_root)
    output = args.output_dir.resolve()
    font_path = args.font.resolve(strict=True)
    font = ImageFont.truetype(str(font_path), 18)
    # 输出与输入必须无重名，防止用户选错目录时覆盖真实素材或清单。
    inputs = {manifest_path, font_path}
    for clip in clips:
        inputs.update(clip["paths"])
        if clip["reference"] is not None:
            inputs.add(clip["reference"])
    destinations = {output / "review.json"}
    for clip in clips:
        destinations.update(output / clip["manifest"]["id"] / name for name in ("strip.png", "contact_sheet.png", "preview.gif", "metrics.json"))
    collisions = inputs & destinations
    if collisions:
        raise ValueError(f"输出会覆盖输入文件：{sorted(str(path) for path in collisions)}")
    results = [review_clip(clip, output / clip["manifest"]["id"], args.scale, args.columns, font) for clip in clips]
    report = {
        "schema_version": 1, "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "manifest_path": str(manifest_path), "manifest_sha256": hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
        "asset_root": str(base_dir), "visual_approval": "not_assessed_by_script",
        "clip_count": len(results), "clips": results,
    }
    (output / "review.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"report": str(output / "review.json"), "clip_count": len(results), "visual_approval": report["visual_approval"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
