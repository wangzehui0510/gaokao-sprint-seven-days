"""按批准关键帧的原生坐标拆分可见人物与家具，保留每项修复的来源。"""

from pathlib import Path
import argparse
import base64
import hashlib
import json
import shutil
from PIL import Image, ImageDraw, ImageFont

OUT = Path(__file__).resolve().parent
SOURCE = OUT.parent / "seated_write_northeast_v1.png"
ROOT = OUT.parents[6]

# 人物可见边界逐行确认；包含头发、脸、校服、双臂、裤腿、鞋及手持笔。
# 椅背已经遮住的人体不补画，桌面上的纸张仍归家具层。
SPANS = {
    8: [(23, 30)], 9: [(21, 32)], 10: [(20, 34)], 11: [(19, 34)],
    12: [(18, 35)], 13: [(18, 36)], 14: [(18, 36)], 15: [(18, 36)],
    16: [(18, 36)], 17: [(18, 35)], 18: [(18, 34)], 19: [(18, 34)],
    20: [(18, 34)], 21: [(19, 34)], 22: [(20, 34)],
    23: [(21, 33), (37, 37)], 24: [(21, 33), (38, 38)],
    25: [(19, 32), (39, 40)], 26: [(18, 31), (39, 41)],
    27: [(17, 33), (39, 42)], 28: [(17, 42)], 29: [(17, 42)],
    30: [(16, 42)], 31: [(16, 41)], 32: [(16, 41)], 33: [(16, 40)],
    34: [(19, 39)], 35: [(21, 38)], 36: [(23, 32)], 37: [(25, 32)],
    38: [(25, 32)], 39: [(25, 37)], 40: [(25, 38)], 41: [(25, 39)],
    42: [(25, 39)], 43: [(25, 39)], 44: [(24, 39)], 45: [(24, 39)],
    46: [(24, 30), (34, 39)], 47: [(23, 28), (34, 39)],
    48: [(34, 41)], 49: [(34, 42)], 50: [(34, 42)],
    51: [(35, 41)], 52: [(36, 40)],
}

# 持笔的右前臂与手/笔分开记录，托纸的另一只手保持在固定主体中。
WRITING_HAND_PEN = {23: [(37, 37)], 24: [(38, 38)], 25: [(39, 40)],
                    26: [(39, 41)], 27: [(39, 42)], 28: [(39, 42)],
                    29: [(40, 42)], 30: [(41, 42)]}
RIGHT_FOREARM = {29: [(37, 39)], 30: [(35, 40)], 31: [(34, 41)],
                 32: [(32, 41)], 33: [(32, 40)], 34: [(31, 39)], 35: [(31, 38)]}

# 椅子与课桌相接处按逐行像素归属拆分；分层只改变绘制归属，不改坐标和颜色。
CHAIR_RIGHT = {31: 12, 32: 13, 33: 15, 34: 18, 35: 20, 36: 22,
               37: 24, 38: 24, 39: 25, 40: 28, 41: 31, 42: 34,
               43: 34, 44: 34, 45: 33, 46: 33, 47: 33, 48: 33,
               49: 33, 50: 33, 51: 33, 52: 33, 53: 33, 54: 33,
               55: 24, 56: 24, 57: 24, 58: 24, 59: 24, 60: 24}

# 前景只取原稿已经可见的椅背木板与立柱，不把重绘填入人体区域的像素置于人物前面。
CHAIR_FRONT = {
    31: [(9, 12)], 32: [(8, 13)], 33: [(8, 15)], 34: [(8, 18)],
    35: [(8, 20)], 36: [(8, 22)], 37: [(8, 24)], 38: [(8, 24)],
    39: [(8, 24)], 40: [(9, 24)], 41: [(9, 24)],
    42: [(9, 11), (13, 24)], 43: [(9, 11), (14, 24)],
    44: [(9, 11), (17, 24)], 45: [(9, 11), (18, 24)],
    46: [(9, 11), (20, 23)],
}


def sha(path):
    """记录原始字节摘要，确保批准关键帧和外部返回稿不会被覆盖。"""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare_masks():
    """输出纯黑白人物mask、精确可见人物层及可见家具mask。"""
    OUT.mkdir(parents=True, exist_ok=True)
    source = Image.open(SOURCE).convert("RGBA")
    assert source.size == (64, 64)
    shutil.copy2(SOURCE, OUT / "source_seed.png")
    mask = Image.new("L", source.size, 0)
    draw = ImageDraw.Draw(mask)
    for y, spans in SPANS.items():
        for left, right in spans:
            draw.line((left, y, right, y), fill=255)
    # 可见人物mask只选择批准源中真实不透明像素，不把透明边界当成人体。
    alpha = source.getchannel("A")
    for y in range(64):
        for x in range(64):
            if alpha.getpixel((x, y)) == 0:
                mask.putpixel((x, y), 0)
    mask.convert("RGB").save(OUT / "character_visibility_mask.png")
    mask.convert("RGB").save(OUT / "inpaint_person_mask.png")
    character = Image.new("RGBA", source.size)
    character.paste(source, (0, 0), mask)
    character.save(OUT / "character_seed.png")
    furniture_mask = Image.new("L", source.size)
    furniture_visible = Image.new("RGBA", source.size)
    for y in range(64):
        for x in range(64):
            if alpha.getpixel((x, y)) and not mask.getpixel((x, y)):
                furniture_mask.putpixel((x, y), 255)
                furniture_visible.putpixel((x, y), source.getpixel((x, y)))
    furniture_mask.convert("RGB").save(OUT / "furniture_visibility_mask.png")
    furniture_visible.save(OUT / "furniture_visible_source.png")
    motion_mask = Image.new("L", source.size)
    for name, spans_by_row in (("writing_hand_pen_visibility_mask", WRITING_HAND_PEN), ("right_forearm_visibility_mask", RIGHT_FOREARM)):
        part = Image.new("L", source.size)
        part_draw = ImageDraw.Draw(part)
        for y, spans in spans_by_row.items():
            for left, right in spans:
                for x in range(left, right + 1):
                    if mask.getpixel((x, y)):
                        part_draw.point((x, y), fill=255)
                        motion_mask.putpixel((x, y), 255)
        part.convert("RGB").save(OUT / f"{name}.png")
    motion_mask.convert("RGB").save(OUT / "writing_motion_visibility_mask.png")
    body_mask = Image.new("L", source.size)
    for y in range(64):
        for x in range(64):
            if mask.getpixel((x, y)) and not motion_mask.getpixel((x, y)):
                body_mask.putpixel((x, y), 255)
    body_mask.convert("RGB").save(OUT / "character_static_body_mask.png")
    # 红色覆层只用于逐像素目检，正式mask仍是无抗锯齿的黑白图。
    preview = source.copy()
    tint = Image.new("RGBA", source.size, (255, 30, 30, 125))
    tint.putalpha(mask.point(lambda value: 125 if value else 0))
    preview.alpha_composite(tint)
    preview.resize((768, 768), Image.Resampling.NEAREST).save(OUT / "mask_review_12x.png")
    (OUT / "mask_geometry.json").write_text(json.dumps({
        "source": str(SOURCE), "source_sha256": sha(SOURCE), "canvas": [64, 64],
        "coordinate_origin": [0, 0], "coordinate_transform": "无移动、无缩放",
        "character_spans_inclusive": SPANS, "character_visible_pixels": sum(v > 0 for v in mask.get_flattened_data()),
        "includes": ["头发", "脸", "校服", "手臂", "裤腿", "鞋", "手持笔"],
        "writing_hand_pen_spans_inclusive": WRITING_HAND_PEN,
        "right_forearm_spans_inclusive": RIGHT_FOREARM,
        "excludes": ["桌面纸张", "可见桌椅", "椅背遮住的人体，不推测补画"],
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    return mask


def count_diff(first, second):
    """统计完整RGBA差异；透明像素的RGB也纳入比较，不隐藏边缘脏色。"""
    assert first.size == second.size
    return sum(a != b for a, b in zip(first.get_flattened_data(), second.get_flattened_data()))


def checker(size):
    """生成检查底纹，便于同时查看透明轮廓和深色像素。"""
    canvas = Image.new("RGBA", size, (229, 227, 218, 255))
    draw = ImageDraw.Draw(canvas)
    for y in range(0, size[1], 8):
        for x in range(0, size[0], 8):
            if (x // 8 + y // 8) % 2:
                draw.rectangle((x, y, x + 7, y + 7), fill=(201, 202, 197, 255))
    return canvas


def review_layers(images):
    """输出原生倍率、分层和完整重组对照，不对像素作平滑缩放。"""
    font = ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", 18)
    title_font = ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", 22)
    labels = {"source_seed": "批准原稿", "all_furniture": "真实空桌椅", "reconstructed_seed": "四层重组"}
    comparison = Image.new("RGB", (3 * 300, 630), (247, 245, 237))
    draw = ImageDraw.Draw(comparison)
    for column, (name, label) in enumerate(labels.items()):
        draw.text((column * 300 + 20, 12), label, font=title_font, fill=(30, 38, 41))
        for scale, top in ((1, 58), (2, 162), (4, 330)):
            draw.text((column * 300 + 20, top - 25), f"{scale}倍 / 最近邻", font=font, fill=(60, 68, 70))
            tile = checker((64 * scale, 64 * scale))
            tile.alpha_composite(images[name].resize(tile.size, Image.Resampling.NEAREST))
            comparison.paste(tile.convert("RGB"), (column * 300 + 20, top))
    comparison.save(OUT / "comparison_1x_2x_4x.png")
    layer_names = ["desk_back", "chair_base", "character_seed", "chair_front", "all_furniture", "reconstructed_seed"]
    sheet = Image.new("RGB", (6 * 280, 330), (247, 245, 237))
    layer_draw = ImageDraw.Draw(sheet)
    for column, name in enumerate(layer_names):
        layer_draw.text((column * 280 + 12, 10), name, font=font, fill=(30, 38, 41))
        tile = checker((256, 256))
        tile.alpha_composite(images[name].resize(tile.size, Image.Resampling.NEAREST))
        sheet.paste(tile.convert("RGB"), (column * 280 + 12, 52))
    sheet.save(OUT / "layer_review_4x.png")


def build_furniture():
    """拆分真实空座位并验证像素复原，遇到来源或遮挡错误立即报错。"""
    source = Image.open(SOURCE).convert("RGBA")
    initial_empty = Image.open(OUT / "inpaint_empty_raw.png").convert("RGBA")
    empty = Image.open(OUT / "inpaint_empty_refined_raw.png").convert("RGBA")
    cleanup_mask = Image.open(OUT / "inpaint_edge_cleanup_mask.png").convert("L")
    person_mask = Image.open(OUT / "character_visibility_mask.png").convert("L")
    source_furniture_mask = Image.open(OUT / "furniture_visibility_mask.png").convert("L")
    assert source.size == empty.size == (64, 64)
    layers = {name: Image.new("RGBA", (64, 64)) for name in ("desk_back", "chair_base", "chair_front")}
    masks = {name: Image.new("L", (64, 64)) for name in layers}
    hidden_repair_mask = Image.new("L", (64, 64))
    removed_person_mask = Image.new("L", (64, 64))
    changed_inside = 0
    for y in range(64):
        for x in range(64):
            point = (x, y)
            before, after = source.getpixel(point), empty.getpixel(point)
            if not cleanup_mask.getpixel(point):
                assert initial_empty.getpixel(point) == after, ("轮廓清理越出3像素mask", point)
            # 外部模型必须仅修改明确授权的人物mask，任何越界变化都会阻止产出验收稿。
            if not person_mask.getpixel(point):
                assert before == after, ("遮罩外像素被改动", point, before, after)
            elif before != after:
                changed_inside += 1
                (hidden_repair_mask if after[3] else removed_person_mask).putpixel(point, 255)
            if not after[3]:
                assert after == (0, 0, 0, 0), ("透明像素含脏色", point, after)
                continue
            is_chair = y in CHAIR_RIGHT and x <= CHAIR_RIGHT[y]
            is_front = (is_chair and source_furniture_mask.getpixel(point) and
                        any(left <= x <= right for left, right in CHAIR_FRONT.get(y, [])))
            name = "chair_front" if is_front else "chair_base" if is_chair else "desk_back"
            layers[name].putpixel(point, after)
            masks[name].putpixel(point, 255)
    for name, layer in layers.items():
        layer.save(OUT / f"{name}.png")
        masks[name].convert("RGB").save(OUT / f"{name}_visibility_mask.png")
    hidden_repair_mask.convert("RGB").save(OUT / "hidden_furniture_repair_mask.png")
    removed_person_mask.convert("RGB").save(OUT / "removed_person_to_transparency_mask.png")
    # 空座位保留外部返回文件的原始字节，各层则以原生64像素画布独立保存。
    shutil.copy2(OUT / "inpaint_empty_refined_raw.png", OUT / "all_furniture.png")
    reassembled = Image.new("RGBA", (64, 64))
    for name in ("desk_back", "chair_base", "chair_front"):
        reassembled.alpha_composite(layers[name])
    assert count_diff(reassembled, empty) == 0, "家具拆层无法还原空座位"
    character = Image.open(OUT / "character_seed.png").convert("RGBA")
    reconstructed = Image.new("RGBA", (64, 64))
    for layer in (layers["desk_back"], layers["chair_base"], character, layers["chair_front"]):
        reconstructed.alpha_composite(layer)
    assert count_diff(reconstructed, source) == 0, "四层重组与批准原稿不一致"
    reconstructed.save(OUT / "reconstructed_seed.png")
    Image.new("RGBA", (64, 64)).save(OUT / "reconstruction_diff.png")
    front_intersection = sum(bool(masks["chair_front"].getpixel((x, y)) and person_mask.getpixel((x, y)))
                             for y in range(64) for x in range(64))
    assert front_intersection == 0, "椅背前景覆盖了原稿人物"
    images = {**layers, "character_seed": character, "all_furniture": empty,
              "source_seed": source, "reconstructed_seed": reconstructed}
    review_layers(images)
    outputs = [f"{name}.png" for name in images] + [
        "character_visibility_mask.png", "character_static_body_mask.png", "writing_motion_visibility_mask.png",
        "writing_hand_pen_visibility_mask.png", "right_forearm_visibility_mask.png"]
    manifest = {
        "canvas": [64, 64], "direction": "northeast_three_quarter",
        "coordinate_origin": [0, 0], "coordinate_transform": "无移动、无缩放、无镜像",
        "layer_alignment": "所有64×64图层按同一左上角[0,0]叠加",
        "ground_reference": {"lowest_opaque_row": 60, "ground_line_exclusive": 61},
        "production_world_anchor": None,
        "production_world_anchor_note": "未替生产场景决定世界锚点；所有图层必须共享同一原点和缩放。",
        "occupied_draw_order": ["desk_back.png", "chair_base.png", "character_seed.png", "chair_front.png"],
        "empty_draw_order": ["desk_back.png", "chair_base.png", "chair_front.png"],
        "source": {"path": str(SOURCE), "sha256": sha(SOURCE)},
        "inpaint": {"tool": "mcp__pixellab__inpaint_image_pro_flash",
                    "job_id": "27b80127-5f4b-437d-ab59-477c34aa8632", "seed": 261111,
                    "charged_generations": 5, "raw_sha256": sha(OUT / "inpaint_empty_raw.png"),
                    "description": "仅重绘人物mask，恢复真实空桌椅；mask外逐像素保持原样。",
                    "edge_cleanup": {"job_id": "efdf7f09-ae99-4cd1-a17d-28693364b89e", "seed": 261112,
                                     "charged_generations": 5, "mask_pixels": [[36, 13], [36, 14], [36, 15]],
                                     "reason": "首次人物mask漏了3个头部右沿像素，已修正人物mask并用真实局部重绘清理空桌面。",
                                     "raw_sha256": sha(OUT / "inpaint_empty_refined_raw.png")},
                    "total_charged_generations": 10},
        "validation": {"unmasked_rgba_changed_pixels": 0,
                       "masked_rgba_changed_pixels": changed_inside,
                       "hidden_furniture_repaired_pixels": sum(v > 0 for v in hidden_repair_mask.get_flattened_data()),
                       "person_removed_to_transparency_pixels": sum(v > 0 for v in removed_person_mask.get_flattened_data()),
                       "furniture_reassembly_rgba_diff_pixels": count_diff(reassembled, empty),
                       "occupied_reconstruction_rgba_diff_pixels": count_diff(reconstructed, source),
                       "chair_front_person_intersection_pixels": front_intersection,
                       "alpha_values": sorted(set(empty.getchannel("A").get_flattened_data())),
                       "all_canvases": [64, 64]},
        "furniture_partition": {"chair_right_inclusive_by_row": CHAIR_RIGHT,
                                "chair_front_spans_inclusive": CHAIR_FRONT,
                                "visible_pixels_by_layer": {name: sum(v > 0 for v in mask.get_flattened_data())
                                                            for name, mask in masks.items()}},
        "scope_limits": [
            "character_seed只包含原稿可见人体；被椅背遮住的躯干、臀部和远侧腿未猜测补画。",
            "chair_front只包含原稿可见椅背与立柱；局部重绘新补家具全部放在人后。",
            "当前适用于固定坐姿与小幅前臂、手、笔运动；大幅起身、转身或移位需另做完整人体和遮挡验收。",
            "桌面纸张属于desk_back；手持笔属于character_seed和writing_hand_pen_visibility_mask。",
            "空家具恢复包含被头遮住桌面及被身体遮住椅面；原可见家具逐像素保留。",
            "这些素材尚未替换生产资源或变更正式路由。"],
        "files": {name: {"sha256": sha(OUT / name), "size": list(Image.open(OUT / name).size)}
                  for name in outputs},
    }
    (OUT / "layer_manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(manifest["validation"], ensure_ascii=False))


def main():
    """按明确命令准备mask或构建已返回的家具分层，缺失真实来源时直接失败。"""
    parser = argparse.ArgumentParser()
    parser.add_argument("--mask-payload", action="store_true", help="只准备人物mask并输出PixelLab输入")
    args = parser.parse_args()
    prepare_masks()
    if args.mask_payload:
        print(json.dumps({"image_base64": base64.b64encode(SOURCE.read_bytes()).decode(),
                          "mask_image_base64": base64.b64encode((OUT / "inpaint_person_mask.png").read_bytes()).decode()}))
    else:
        build_furniture()


if __name__ == "__main__":
    main()
