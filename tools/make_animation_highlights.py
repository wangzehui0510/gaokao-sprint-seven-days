"""按真实清单时间轴生成六格动画抽样预览，不修改源帧或审核结论。"""

import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

from review_pixel_animations import DEFAULT_FONT, load_frame, read_manifest


# 六个片段由本轮明确指定，缺失时直接报错，不用其他素材补位。
HIGHLIGHT_IDS = [
    "A01_write_north", "A04_sleep_desk_north", "A07_computer_east",
    "A08_step_east", "A10_wash_face_east", "A13_pillow_east",
]
SCALE = 3
TICK_MS = 50
FRAME_COUNT = 80
CELL_WIDTH = 256
CELL_HEIGHT = 230
HEADER = 64
FOOTER = 36


def source_frame_at(clip, elapsed_ms):
    """按清单逐帧时长采样；循环片段回绕，单次片段保留最后一帧。"""
    total = sum(clip["durations"])
    position = elapsed_ms % total if clip["manifest"]["loop"] else min(elapsed_ms, total - 1)
    cumulative = 0
    for index, duration in enumerate(clip["durations"]):
        cumulative += duration
        if position < cumulative:
            return index
    raise ValueError(f"清单时间轴不能定位帧：{clip['manifest']['id']}")


def main():
    """生成固定四秒预览及可选首帧PNG，同时保存每格采样索引与来源摘要。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--gif-output", type=Path)
    parser.add_argument("--png-output", type=Path)
    parser.add_argument("--report-output", type=Path)
    parser.add_argument("--font", type=Path, default=Path(DEFAULT_FONT))
    args = parser.parse_args()
    manifest_path = args.manifest.resolve(strict=True)
    _, validated, _ = read_manifest(manifest_path, None)
    indexed = {clip["manifest"]["id"]: clip for clip in validated}
    missing = [identifier for identifier in HIGHLIGHT_IDS if identifier not in indexed]
    if missing:
        raise ValueError(f"清单缺少指定预览片段：{missing}")
    clips = [indexed[identifier] for identifier in HIGHLIGHT_IDS]
    font_path = args.font.resolve(strict=True)
    title_font = ImageFont.truetype(str(font_path), 21)
    label_font = ImageFont.truetype(str(font_path), 18)
    small_font = ImageFont.truetype(str(font_path), 12)
    gif_output = args.gif_output.resolve() if args.gif_output else manifest_path.parent / "highlights.gif"
    outputs = [gif_output]
    if args.png_output:
        outputs.append(args.png_output.resolve())
    if args.report_output:
        outputs.append(args.report_output.resolve())
    inputs = {manifest_path, font_path} | {path for clip in clips for path in clip["paths"]}
    if inputs.intersection(outputs) or len(outputs) != len(set(outputs)):
        raise ValueError("预览输出不能覆盖输入素材，且各输出路径必须不同")
    decoded = [[load_frame(path) for path in clip["paths"]] for clip in clips]
    positions = []
    for clip, images in zip(clips, decoded):
        anchor = clip["manifest"].get("anchor")
        if anchor is None:
            raise ValueError(f"六格预览必须有明确锚点：{clip['manifest']['id']}")
        x, y = CELL_WIDTH // 2 - anchor[0] * SCALE, 202 - anchor[1] * SCALE
        if any(x < 0 or y < 60 or x + image.width * SCALE > CELL_WIDTH or y + image.height * SCALE > CELL_HEIGHT for image in images):
            raise ValueError(f"源帧按3倍与锚点对齐后超出预览格，请调整预览布局：{clip['manifest']['id']}")
        positions.append((x, y))
    width, height = CELL_WIDTH * 3, HEADER + CELL_HEIGHT * 2 + FOOTER
    base = Image.new("RGB", (width, height), "#edf2f3")
    draw = ImageDraw.Draw(base)
    draw.text((16, 8), "动画抽样预览 · 仅展示，不代表验收通过", font=title_font, fill="#173e4c")
    for number, clip in enumerate(clips):
        left, top = number % 3 * CELL_WIDTH, HEADER + number // 3 * CELL_HEIGHT
        draw.text((left + 13, top + 6), clip["manifest"]["label"], font=label_font, fill="#173e4c")
        draw.text((left + 13, top + 34), clip["manifest"]["id"], font=small_font, fill="#55717c")
        for y in range(60, CELL_HEIGHT, 12):
            for x in range(0, CELL_WIDTH, 12):
                fill = "#dce2e1" if ((x // 12 + y // 12) % 2 == 0) else "#eef1ee"
                draw.rectangle((left + x, top + y, left + min(x + 11, CELL_WIDTH - 1), top + min(y + 11, CELL_HEIGHT - 1)), fill=fill)
    draw.text((14, height - FOOTER + 10), "4秒抽样 / 每50毫秒展示 / 按源时长取帧 / 3倍最近邻 / 原PNG不变", font=label_font, fill="#45616b")
    frames = []
    timeline = []
    for display_index in range(FRAME_COUNT):
        elapsed = display_index * TICK_MS
        composed = base.copy()
        display = ImageDraw.Draw(composed)
        # 时间码让80张展示帧可逐张回查，避免GIF编码器合并相同的停留画面。
        display.text((16, 38), f"时间 {elapsed / 1000:04.2f} 秒 · 展示帧 {display_index + 1:02d}/{FRAME_COUNT}", font=small_font, fill="#55717c")
        indices = []
        for number, clip in enumerate(clips):
            source_index = source_frame_at(clip, elapsed)
            image = decoded[number][source_index]
            enlarged = image.resize((image.width * SCALE, image.height * SCALE), Image.Resampling.NEAREST)
            x, y = positions[number]
            point = (number % 3 * CELL_WIDTH + x, HEADER + number // 3 * CELL_HEIGHT + y)
            composed.paste(enlarged, point, enlarged)
            indices.append(source_index)
        frames.append(composed)
        timeline.append({"display_frame": display_index, "at_ms": elapsed, "source_indices": indices})
    for destination in outputs:
        destination.parent.mkdir(parents=True, exist_ok=True)
    frames[0].save(gif_output, format="GIF", save_all=True, append_images=frames[1:], duration=TICK_MS, loop=0, optimize=False, disposal=2)
    with Image.open(gif_output) as encoded:
        encoded_count = encoded.n_frames
        durations = []
        for index in range(encoded_count):
            encoded.seek(index)
            durations.append(encoded.info.get("duration"))
    if encoded_count != FRAME_COUNT or durations != [TICK_MS] * FRAME_COUNT:
        raise ValueError(f"GIF未保留80张50ms展示帧：帧数={encoded_count}，时长={durations}")
    if args.png_output:
        frames[0].save(args.png_output.resolve(), format="PNG")
    report = {
        "manifest_path": str(manifest_path), "manifest_sha256": hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
        "visual_approval": "not_assessed_by_script", "gif_output": str(gif_output), "scale": SCALE,
        "display_frames": FRAME_COUNT, "display_frame_duration_ms": TICK_MS, "duration_ms": FRAME_COUNT * TICK_MS,
        "source_pixels_modified": False, "source_frames_interpolated": False,
        "clips": [{"id": clip["manifest"]["id"], "label": clip["manifest"]["label"], "anchor": clip["manifest"]["anchor"],
                   "frame_sources": [{"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()} for path in clip["paths"]]}
                  for clip in clips], "timeline": timeline,
        "limitations": ["GIF为有限调色板展示预览；精确像素审核应使用源PNG和Canvas交互页。", "四秒仅为抽样窗口，不替代完整片段审核。"],
    }
    if args.report_output:
        args.report_output.resolve().write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: report[key] for key in ("gif_output", "display_frames", "display_frame_duration_ms", "duration_ms", "visual_approval")}, ensure_ascii=False))


if __name__ == "__main__":
    main()
