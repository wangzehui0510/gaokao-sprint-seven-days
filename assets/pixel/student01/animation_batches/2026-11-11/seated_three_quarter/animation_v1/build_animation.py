"""从真实整段动画提取手臂和笔，固定批准关键帧的人物主体与坐姿。"""
from pathlib import Path
import hashlib
import json
from PIL import Image, ImageChops, ImageDraw, ImageFont

BASE = Path(__file__).resolve().parent.parent
OUT = BASE / "animation_v1"
LAYERS = BASE / "layers_v1"
# 往返采用同一次PixelLab生成中的四个姿态，不重生成每帧或移动人物画布。
SOURCE_ORDER = [0, 6, 4, 2, 4, 6]
DURATIONS = [280, 150, 160, 200, 160, 150]
# 人工逐像素确认右手、持笔和前臂范围；桌面纸张及另一只手不随原稿漂移。
MOTION_SPANS = {
    0: {23: (37, 37), 24: (38, 38), 25: (39, 40), 26: (39, 41),
        27: (39, 42), 28: (39, 42), 29: (37, 42), 30: (35, 42),
        31: (34, 41), 32: (32, 41), 33: (32, 40), 34: (31, 39), 35: (31, 38)},
    6: {23: (37, 37), 24: (38, 38), 25: (39, 40), 26: (39, 41),
        27: (39, 42), 28: (39, 42), 29: (37, 42), 30: (35, 42),
        31: (34, 41), 32: (32, 41), 33: (32, 40), 34: (31, 39), 35: (31, 38)},
    4: {21: (37, 37), 22: (38, 38), 23: (39, 40), 24: (39, 41),
        25: (39, 42), 26: (37, 42), 27: (37, 42), 28: (36, 42),
        29: (35, 41), 30: (35, 41), 31: (34, 41), 32: (32, 40),
        33: (32, 39), 34: (31, 38), 35: (31, 35)},
    2: {20: (37, 37), 21: (38, 38), 22: (38, 38), 23: (39, 40),
        24: (39, 41), 25: (39, 42), 26: (37, 42), 27: (36, 42),
        28: (35, 42), 29: (35, 41), 30: (34, 41), 31: (33, 40),
        32: (32, 39), 33: (31, 38), 34: (31, 37)},
}


def sha(path):
    """保留采用源和输出的真实字节摘要。"""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def make_mask(spans):
    """按闭区间逐行创建无抗锯齿动作遮罩。"""
    result = Image.new("L", (64, 64))
    draw = ImageDraw.Draw(result)
    for y, (left, right) in spans.items():
        draw.line((left, y, right, y), fill=255)
    return result


def font(size):
    """预览使用中文字体，缺失时直接报告依赖。"""
    return ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", size)


def build():
    """固定主体后合成六帧人物透明层，并记录所有局部采用与调色映射。"""
    frames_dir = OUT / "curated"
    masks_dir = OUT / "motion_masks"
    frames_dir.mkdir(exist_ok=True)
    masks_dir.mkdir(exist_ok=True)
    seed = Image.open(LAYERS / "character_seed.png").convert("RGBA")
    approved = Image.open(BASE / "seated_write_northeast_v1.png").convert("RGBA")
    raw_zero = Image.open(OUT / "raw/frame_00.png").convert("RGBA")
    assert raw_zero.tobytes() == approved.tobytes(), "首源帧与批准关键帧不同。"
    static_mask = Image.open(LAYERS / "character_static_body_mask.png").convert("L")
    body = Image.new("RGBA", (64, 64))
    body.paste(seed, (0, 0), static_mask)
    # 原稿抬腕会露出身侧轮廓；保留批准源的两像素身侧连接，不推测补画人体。
    fixed_seam = [(31, 35), (32, 35)]
    for point in fixed_seam:
        body.putpixel(point, seed.getpixel(point))
    body.save(OUT / "character_body_fixed.png")
    palette = sorted(set(approved.get_flattened_data()) - {(0, 0, 0, 0)})
    allowed = Image.new("L", (64, 64))
    for spans in MOTION_SPANS.values():
        mask = make_mask(spans)
        allowed = ImageChops.lighter(allowed, mask)
    allowed.save(OUT / "motion_union_mask.png")
    records, frames = [], []
    for frame_index, (source_index, duration) in enumerate(zip(SOURCE_ORDER, DURATIONS)):
        source_path = OUT / "raw" / f"frame_{source_index:02d}.png"
        source = Image.open(source_path).convert("RGBA")
        assert source.size == (64, 64)
        mask = make_mask(MOTION_SPANS[source_index])
        mask.save(masks_dir / f"source_{source_index:02d}.png")
        arm = Image.new("RGBA", (64, 64))
        adjustments = []
        for y in range(64):
            for x in range(64):
                if not mask.getpixel((x, y)):
                    continue
                color = source.getpixel((x, y))
                assert color[3] == 255, f"动作遮罩选择了透明像素：{source_index, x, y}"
                # AI原稿少数抗锯齿色显式量化到批准源调色板，只影响动作mask中的像素。
                if color not in palette:
                    replacement = min(palette, key=lambda p: sum((p[k] - color[k]) ** 2 for k in range(3)))
                    adjustments.append({"xy": [x, y], "from": list(color), "to": list(replacement)})
                    color = replacement
                arm.putpixel((x, y), color)
        result = Image.alpha_composite(body, arm)
        result.save(frames_dir / f"frame_{frame_index:02d}.png")
        arm.save(frames_dir / f"arm_{frame_index:02d}.png")
        changed = [(x, y) for y in range(64) for x in range(64) if result.getpixel((x, y)) != seed.getpixel((x, y))]
        assert all(allowed.getpixel(point) for point in changed), "手部之外发生了像素漂移。"
        assert result.crop((0, 37, 64, 64)).tobytes() == seed.crop((0, 37, 64, 64)).tobytes(), "臀腿脚发生漂移。"
        records.append({"frame": frame_index, "source_frame": source_index, "source_sha256": sha(source_path),
                        "path": str(frames_dir / f"frame_{frame_index:02d}.png"), "sha256": sha(frames_dir / f"frame_{frame_index:02d}.png"),
                        "duration_ms": duration, "changed_from_seed_pixels": len(changed), "palette_adjustments": adjustments,
                        "motion_mask": str(masks_dir / f"source_{source_index:02d}.png")})
        frames.append(result)
    assert frames[0].tobytes() == seed.tobytes(), "整理首帧未能精确保持批准人物。"
    sheet = Image.new("RGB", (6 * 288, 340), "#dfe9e1")
    draw = ImageDraw.Draw(sheet)
    preview = []
    furniture = Image.open(LAYERS / "furniture_visible_source.png").convert("RGBA")
    for index, result in enumerate(frames):
        composed = Image.alpha_composite(furniture, result)
        tile = composed.resize((256, 256), Image.Resampling.NEAREST)
        sheet.paste(tile, (index * 288 + 16, 42), tile)
        draw.text((index * 288 + 16, 12), f"帧{index + 1} / 源{SOURCE_ORDER[index]}", font=font(18), fill="#29433a")
        draw.text((index * 288 + 16, 306), f"{DURATIONS[index]}ms", font=font(18), fill="#29433a")
        bg = Image.new("RGBA", (256, 256), "#dfe9e1")
        bg.alpha_composite(tile)
        preview.append(bg.convert("RGB"))
    sheet.save(OUT / "curated_contact.png")
    preview[0].save(OUT / "writing_preview.gif", save_all=True, append_images=preview[1:], duration=DURATIONS, loop=0, disposal=2)
    provenance = {"status": "curated_pending_layered_gpu_review", "canvas": [64, 64], "station_anchor": [32, 60],
                  "seed": str(BASE / "seated_write_northeast_v1.png"), "seed_sha256": sha(BASE / "seated_write_northeast_v1.png"),
                  "fixed_body_sources_sha256": {name: sha(LAYERS / name) for name in ["character_seed.png", "character_static_body_mask.png", "writing_motion_visibility_mask.png"]},
                  "generated_job_id": "51e7f97e-e979-4fa1-9f82-f375d5a9bc3d", "source_order": SOURCE_ORDER,
                  "duration_ms": DURATIONS, "coordinate_transform": "无缩放、无平移，手臂局部采用真实生成像素",
                  "fixed_seed_seam_pixels": [list(p) for p in fixed_seam], "motion_spans_inclusive": MOTION_SPANS,
                  "raw_excluded": {"1": "无需采用头部偏移源，写字轨迹已由其他姿态覆盖。", "3": "手臂与躯干改动过大，不用于本次小幅写字循环。", "5": "无需采用重复低位姿态，保留真实原稿。"},
                  "frames": records, "checks": {"frame_0_exact_seed_character": True, "changes_within_motion_union": True, "hips_legs_feet_fixed": True},
                  "limitations": ["人物仅含批准视角可见部分，椅背后的人体未补全，不能直接用于起立或移动。", "本轮只制作素材与隔离预览，尚未替换正式行为路由。"]}
    (OUT / "curation.json").write_text(json.dumps(provenance, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"output_frames": len(records), "source_order": SOURCE_ORDER, "changed_pixels": [r["changed_from_seed_pixels"] for r in records]}, ensure_ascii=False))


if __name__ == "__main__":
    build()
