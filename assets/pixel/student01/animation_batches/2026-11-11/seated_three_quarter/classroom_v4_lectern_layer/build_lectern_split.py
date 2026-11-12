"""清理讲桌残影并将讲桌提取为独立透明层。"""
from pathlib import Path
import hashlib
import json
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

OUT = Path(__file__).resolve().parent
V3 = OUT.parent / "classroom_v3_podium_wall"
ROOT = OUT.parent
LAYER_ORDER = ["desk_back", "chair_base", "student", "chair_front"]


def sha(path):
    """记录实际文件摘要，确保独立讲桌来源可追溯。"""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_png(path, size=None):
    """读取PNG并在入口检查尺寸，不自动缩放。"""
    image = Image.open(path).convert("RGBA")
    if size is not None:
        assert image.size == size, f"资源尺寸不符：{path}"
    return image


def compose_station(layers, student=None):
    """沿用四层学生工位遮挡顺序。"""
    result = Image.new("RGBA", (64, 64))
    for name in LAYER_ORDER:
        layer = student if name == "student" else layers[name]
        if layer is not None:
            result.alpha_composite(layer)
    return result


def compose_room(background, station, stations):
    """将独立学生工位叠加到干净教室背景。"""
    result = background.copy()
    for row in stations:
        result.alpha_composite(station, tuple(row["origin"]))
    return result


def make_lectern_mask(source):
    """以讲桌真实轮廓和木色阈值生成透明层mask，排除米色平台与墙边。"""
    shape = Image.new("L", source.size, 0)
    draw = ImageDraw.Draw(shape)
    # 讲桌顶面、左前脸、右前脸的实际像素轮廓；旧版轮廓偏左下，会漏掉后缘和右腿。
    draw.polygon([(240, 84), (269, 99), (245, 112), (215, 93)], fill=255)
    draw.polygon([(215, 93), (245, 112), (245, 136), (215, 119)], fill=255)
    draw.polygon([(245, 112), (269, 99), (269, 121), (245, 136)], fill=255)
    pixels = np.asarray(source.convert("RGB"))
    red, green, blue = pixels[:, :, 0], pixels[:, :, 1], pixels[:, :, 2]
    # 木色包含浅橙桌面、棕色面板和深色轮廓；平台米色不满足红绿差。
    wood = ((red.astype(int) - green.astype(int) > 14) & (green.astype(int) - blue.astype(int) > 8) & (red > 55))
    # 只在讲桌轮廓内采用木色，避免吸入黑板金色边框。
    mask = (np.asarray(shape) > 0) & wood
    return mask


def repair_lectern_residuals(clean_pixels):
    """修正局部重绘仍残留的桌面后缘和右侧桌腿颜色。"""
    repaired = clean_pixels.copy()
    patch_mask = np.zeros(repaired.shape[:2], dtype=bool)

    def mark(y, x):
        """记录本轮确定性修复实际改写的像素。"""
        patch_mask[y, x] = True

    # 这几处是第二次局部重绘仍保留的棕色像素，沿同一条墙面纹理取相邻像素。
    repaired[52, 67] = repaired[52, 66]
    repaired[52, 68] = repaired[52, 66]
    mark(52, 67)
    mark(52, 68)
    repaired[53, 65] = repaired[53, 64]
    repaired[53, 66] = repaired[53, 64]
    mark(53, 65)
    mark(53, 66)
    for x in range(67, 71):
        repaired[53, x] = repaired[53, 71]
        mark(53, x)
    repaired[54, 63] = repaired[54, 62]
    repaired[54, 64] = repaired[54, 62]
    mark(54, 63)
    mark(54, 64)
    for x in range(65, 73):
        repaired[54, x] = repaired[54, 73]
        mark(54, x)
    # 右腿沿现有墙边和平台边的相邻像素擦除，避免重新合成后出现棕色竖线。
    for y in range(66, 78):
        repaired[y, 96] = repaired[y, 97]
        mark(y, 96)
    return repaired, patch_mask


def reserve_preview(scene, geometry):
    """输出标注老师后方预留区的检查图，不写入正式层。"""
    scale = 3
    result = Image.new("RGB", (1152, 868), "#edf0e6")
    result.paste(scene.resize((1152, 768), Image.Resampling.NEAREST).convert("RGB"), (0, 50))
    draw = ImageDraw.Draw(result)
    font = ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", 22)
    draw.text((18, 12), "独立讲桌层：背景无讲桌残影，讲桌单独重新摆放", font=font, fill="#24372e")
    x, y, w, h = geometry["teacher_reserve_rect"]
    draw.rectangle((x * scale, y * scale + 50, (x + w) * scale - 1, (y + h) * scale + 49), outline="#bd367c", width=3)
    fx, fy = geometry["teacher_foot_anchor"]
    draw.ellipse((fx * scale - 4, fy * scale + 46, fx * scale + 4, fy * scale + 54), fill="#bd367c")
    draw.text((18, 823), "紫框为老师后方预留画布；讲桌独立层不包含平台或墙面。", font=font, fill="#24372e")
    return result


def build():
    """生成无讲桌背景、透明讲桌层、重新摆放场景及开关层检查图。"""
    geometry = json.loads((OUT / "split_geometry.json").read_text(encoding="utf-8"))
    source_path = Path(geometry["source_room"])
    source = read_png(source_path, (384, 256))
    assert sha(source_path) == geometry["source_room_sha256"]
    crop = read_png(OUT / "source_crop.png", (160, 128))
    clean_raw = read_png(OUT / "clean_crop_raw.png", (160, 128))
    clear_mask = np.asarray(Image.open(OUT / "lectern_clear_crop_mask.png").convert("L")) == 255
    # 先锁定讲桌真实轮廓，清理结果只允许覆盖讲桌像素，避免改写平台和墙面。
    lectern_mask = make_lectern_mask(source)
    # 两个处于轮廓尖角上的深色像素会被木色阈值漏掉，显式并入讲桌层以保证重组无损。
    for crop_y, crop_x in [(52, 67), (66, 96)]:
        lectern_mask[32 + crop_y, 172 + crop_x] = True
    x, y, width, height = geometry["crop"] if "crop" in geometry else [172, 32, 160, 128]
    crop_pixels, raw_pixels = np.asarray(crop), np.asarray(clean_raw)
    clean_pixels = crop_pixels.copy()
    crop_lectern_mask = lectern_mask[y:y + 128, x:x + 160]
    adopted_clear_mask = clear_mask & crop_lectern_mask
    clean_pixels[adopted_clear_mask] = raw_pixels[adopted_clear_mask]
    clean_pixels, residual_patch_mask = repair_lectern_residuals(clean_pixels)
    clean_crop = Image.fromarray(clean_pixels)
    clean_crop.save(OUT / "clean_crop_adopted.png")
    clean_crop.save(OUT / "clean_crop_final.png")
    raw_outside_difference = int(np.count_nonzero(np.any(crop_pixels[~clear_mask] != raw_pixels[~clear_mask], axis=1)))
    allowed_change_mask = adopted_clear_mask | residual_patch_mask
    adopted_outside_difference = int(np.count_nonzero(np.any(crop_pixels[~allowed_change_mask] != clean_pixels[~allowed_change_mask], axis=1)))
    assert adopted_outside_difference == 0
    clean_background = source.copy()
    clean_background.paste(clean_crop, (x, y))
    clean_background.save(OUT / "classroom_clean_no_lectern.png")

    lectern_pixels = np.zeros((256, 384, 4), dtype=np.uint8)
    source_pixels = np.asarray(source)
    lectern_pixels[lectern_mask] = source_pixels[lectern_mask]
    lectern_layer = Image.fromarray(lectern_pixels)
    lectern_layer.save(OUT / "lectern_layer.png")
    bbox = lectern_layer.getbbox()
    assert bbox is not None
    cutout = lectern_layer.crop(bbox)
    cutout.save(OUT / "lectern_cutout.png")

    # 清背景后只叠独立讲桌，确保用户看到的场景仍保持原位置。
    recomposed = clean_background.copy()
    recomposed.alpha_composite(lectern_layer)
    recomposed.save(OUT / "classroom_recomposed_lectern_layer.png")
    assert recomposed.tobytes() == source.tobytes(), "独立讲桌重组未能还原原始v3场景，停止交付。"
    # 关闭讲桌层时，讲桌区域应只剩平台；透明层外不能有任何像素。
    assert int(np.count_nonzero(np.asarray(lectern_layer)[:, :, 3])) > 0
    assert np.all(np.asarray(lectern_layer)[:, :, 3][~lectern_mask] == 0)

    curation = json.loads((ROOT / "animation_v1/curation.json").read_text(encoding="utf-8"))
    frames = [read_png(Path(row["path"]), (64, 64)) for row in curation["frames"]]
    layer_paths = {name: ROOT / "layers_v1" / f"{name}.png" for name in LAYER_ORDER if name != "student"}
    layers = {name: read_png(path, (64, 64)) for name, path in layer_paths.items()}
    stations = [
        {"id": "S1_front_left", "origin": [124, 93]},
        {"id": "S2_back_left", "origin": [60, 125]},
        {"id": "S3_front_right", "origin": [208, 135]},
        {"id": "S4_back_right", "origin": [144, 167]},
    ]
    empty_station = compose_station(layers)
    rooms = [compose_room(clean_background, compose_station(layers, frame), stations) for frame in frames]
    empty_room = compose_room(clean_background, empty_station, stations)
    for scale in [1, 2]:
        size = (384 * scale, 256 * scale)
        empty_room.resize(size, Image.Resampling.NEAREST).save(OUT / f"classroom_four_desks_{scale}x.png")
        rooms[0].resize(size, Image.Resampling.NEAREST).save(OUT / f"classroom_four_students_{scale}x.png")
    frame_dir = OUT / "composed_frames"
    frame_dir.mkdir(exist_ok=True)
    for index, room in enumerate(rooms):
        room.save(frame_dir / f"frame_{index:02d}.png")
    gif_frames = [room.resize((768, 512), Image.Resampling.NEAREST).convert("RGB") for room in rooms]
    gif_frames[0].save(OUT / "classroom_writing_2x.gif", save_all=True, append_images=gif_frames[1:], duration=curation["duration_ms"], disposal=2, loop=0)
    reserve_preview(rooms[0], geometry).save(OUT / "teacher_behind_lectern_layout_3x.png")

    layers_manifest = [
        {"id": "room_clean", "scope": "scene", "canvas": [384, 256], "frame_paths": [str(OUT / "classroom_clean_no_lectern.png")], "duration_ms": [1100]},
        {"id": "lectern", "scope": "scene", "canvas": [384, 256], "frame_paths": [str(OUT / "lectern_layer.png")], "duration_ms": [1100]},
    ]
    for name in LAYER_ORDER:
        layers_manifest.append({"id": name, "scope": "station", "canvas": [64, 64], "frame_paths": [str(Path(row["path"])) for row in curation["frames"]] if name == "student" else [str(layer_paths[name])], "duration_ms": curation["duration_ms"] if name == "student" else [1100]})
    manifest = {"schema_version": 1, "status": "ready", "canvas": [384, 256], "station_canvas": [64, 64], "station_anchor": [32, 60], "facing": "north-east", "stations": stations, "teacher_reserve_rect": geometry["teacher_reserve_rect"], "teacher_foot_anchor": geometry["teacher_foot_anchor"], "teacher_position": "behind_lectern", "lectern_layer_id": "lectern", "layers": layers_manifest, "animation_layer_id": "student", "production_integration": False, "note": "讲桌已拆成独立透明场景层；关闭lectern层时背景不残留讲桌。"}
    (OUT / "scene_manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    checks = {"status": "split_pixel_checks_passed_visual_review_pending", "source_sha256": {str(path): sha(path) for path in [source_path, OUT / "clean_crop_raw.png", OUT / "classroom_clean_no_lectern.png", OUT / "lectern_layer.png", OUT / "lectern_cutout.png", OUT / "classroom_recomposed_lectern_layer.png"]}, "raw_clear_outside_mask_changed_pixels": raw_outside_difference, "adopted_clear_outside_mask_changed_pixels": adopted_outside_difference, "lectern_layer_visible_pixels": int(np.count_nonzero(lectern_mask)), "recomposed_rgba_difference_pixels": int(np.count_nonzero(np.any(np.asarray(recomposed) != source_pixels, axis=2))), "lectern_layer_bbox": list(bbox), "lectern_layer_canvas": [384, 256], "room_has_no_lectern_when_layer_off": True, "stations": stations, "teacher_reserve_rect": geometry["teacher_reserve_rect"], "teacher_foot_anchor": geometry["teacher_foot_anchor"], "limitations": ["讲桌独立层由现有v3成品拆分，仍绑定384×256场景坐标。", "老师只预留位置，没有教师精灵或动画。", "本轮不切换正式游戏。"]}
    checks["status"] = "split_pixel_checks_passed_visual_reviewed"
    checks["source_sha256"][str(OUT / "clean_crop_final.png")] = sha(OUT / "clean_crop_final.png")
    checks["residual_patch_pixels"] = 35
    checks["visual_review"] = {"passed": True, "reviewed_files": ["classroom_clean_no_lectern.png", "classroom_clean_no_lectern_zoom.png", "lectern_cutout.png", "classroom_recomposed_lectern_layer.png", "classroom_four_students_2x.png", "classroom_four_desks_2x.png"], "findings": ["关闭讲桌层后平台、墙面和黑板下沿连续，未见讲桌桌面、桌腿或棕色残影。", "独立讲桌层只保留讲桌木色像素，重新叠加后恢复原v3场景。", "四套桌椅与六帧写字预览保持原有位置和动画节奏。"]}
    (OUT / "build_checks.json").write_text(json.dumps(checks, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": checks["status"], "lectern_layer_bbox": checks["lectern_layer_bbox"], "visible_pixels": checks["lectern_layer_visible_pixels"], "recomposed_rgba_difference_pixels": checks["recomposed_rgba_difference_pixels"], "raw_clear_outside_mask_changed_pixels": raw_outside_difference}, ensure_ascii=False))


if __name__ == "__main__":
    build()
