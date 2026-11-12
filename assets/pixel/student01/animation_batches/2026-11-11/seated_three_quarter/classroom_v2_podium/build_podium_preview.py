"""合成讲台版四工位预览，并核验真实局部重绘与冻结座位来源。"""
from pathlib import Path
import hashlib
import json
import numpy as np
from PIL import Image, ImageDraw, ImageFont

OUT = Path(__file__).resolve().parent
BASE = OUT.parent
# 六帧人物与三层家具沿用已通过的素材；本轮只改变授课区域和工位坐标。
LAYER_ORDER = ["desk_back", "chair_base", "student", "chair_front"]


def sha(path):
    """记录实际读取文件的字节摘要。"""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_png(path, size):
    """入口校验原生画布尺寸，拒绝隐式缩放资源。"""
    result = Image.open(path).convert("RGBA")
    assert result.size == size, f"资源尺寸不符：{path}"
    return result


def write_json(path, data):
    """将构建事实和明确来源写入可审阅清单。"""
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def compose_station(layers, student=None):
    """保持桌、椅面、人物、椅背的固定遮挡顺序。"""
    result = Image.new("RGBA", (64, 64))
    for name in LAYER_ORDER:
        layer = student if name == "student" else layers[name]
        if layer is not None:
            result.alpha_composite(layer)
    return result


def compose_room(background, station, stations):
    """在明确的四个整数坐标上合成独立家具与人物。"""
    result = background.copy()
    for entry in stations:
        result.alpha_composite(station, tuple(entry["origin"]))
    return result


def rectangles_intersect(first, second):
    """按半开矩形检查完整画布是否占用同一区域。"""
    x, y, w, h = first
    ox, oy, ow, oh = second
    return x < ox + ow and ox < x + w and y < oy + oh and oy < y + h


def annotated_layout(scene, geometry):
    """额外输出中文站位说明，标记不写入正式背景或图层。"""
    scale = 3
    result = Image.new("RGB", (384 * scale, 256 * scale + 100), "#edf0e6")
    result.paste(scene.resize((1152, 768), Image.Resampling.NEAREST).convert("RGB"), (0, 50))
    draw = ImageDraw.Draw(result)
    text_font = ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", 22)
    draw.text((18, 12), "讲台版布局：矮平台＋讲桌，右侧预留老师位置", font=text_font, fill="#24372e")
    x, y, w, h = geometry["teacher_reserve_rect"]
    draw.rectangle((x * scale, y * scale + 50, (x + w) * scale - 1, (y + h) * scale + 49), outline="#bd367c", width=3)
    fx, fy = geometry["teacher_foot_anchor"]
    draw.ellipse((fx * scale - 4, fy * scale + 46, fx * scale + 4, fy * scale + 54), fill="#bd367c")
    draw.text((760, 225), "老师预留区", font=text_font, fill="#9c2b65")
    draw.text((18, 823), "紫框为40×56预留画布，圆点为脚点；本图不代表教师素材已完成。", font=text_font, fill="#24372e")
    return result


def build():
    """冻结真实生成结果，构建完整预览并输出独立GPU检查所需资源清单。"""
    geometry = json.loads((OUT / "layout_geometry.json").read_text(encoding="utf-8"))
    source_path = Path(geometry["source_room"])
    source = read_png(source_path, (384, 256))
    assert sha(source_path) == geometry["source_room_sha256"], "原教室来源已变化。"
    crop_path = OUT / "source_crop.png"
    generated_path = OUT / "generated_crop_raw.png"
    mask_path = OUT / "podium_crop_mask.png"
    crop = read_png(crop_path, (160, 128))
    raw_generated = read_png(generated_path, crop.size)
    mask_rgb = np.asarray(Image.open(mask_path).convert("RGB"))
    assert set(np.unique(mask_rgb)).issubset({0, 255})
    assert np.all(mask_rgb[:, :, 0] == mask_rgb[:, :, 1]) and np.all(mask_rgb[:, :, 1] == mask_rgb[:, :, 2])
    mask = mask_rgb[:, :, 0] == 255
    crop_pixels, raw_pixels = np.asarray(crop), np.asarray(raw_generated)
    raw_outside_difference = int(np.count_nonzero(np.any(crop_pixels[~mask] != raw_pixels[~mask], axis=1)))
    # edit_image会编辑整个裁片；明确仅采用白mask内的真实像素，完整原稿另存，其他区域取回冻结源。
    generated_pixels = crop_pixels.copy()
    generated_pixels[mask] = raw_pixels[mask]
    generated = Image.fromarray(generated_pixels)
    generated.save(OUT / "adopted_crop.png")
    outside_difference = int(np.count_nonzero(np.any(crop_pixels[~mask] != generated_pixels[~mask], axis=1)))
    assert outside_difference == 0, "裁切合成改变了mask外像素，停止合成。"
    assert np.all(generated_pixels[:, :, 3] == 255), "讲台背景必须不透明。"
    x, y, width, height = geometry["crop"]
    assert source.crop((x, y, x + width, y + height)).tobytes() == crop.tobytes()
    background = source.copy()
    background.paste(generated, (x, y))
    background_path = OUT / "classroom_with_podium.png"
    background.save(background_path)
    # 覆盖层仅保存真实变化像素，绑定原教室坐标，不能当作可自由移动的纯物体贴图。
    changed = np.any(np.asarray(source) != np.asarray(background), axis=2)
    assert np.any(changed), "生成结果没有产生任何真实修改。"
    overlay_pixels = np.zeros((256, 384, 4), dtype=np.uint8)
    overlay_pixels[changed] = np.asarray(background)[changed]
    overlay = Image.fromarray(overlay_pixels)
    overlay_path = OUT / "podium_overlay.png"
    overlay.save(overlay_path)
    reconstructed_background = source.copy()
    reconstructed_background.alpha_composite(overlay)
    assert reconstructed_background.tobytes() == background.tobytes()

    curation = json.loads((BASE / "animation_v1/curation.json").read_text(encoding="utf-8"))
    durations = curation["duration_ms"]
    frame_paths = [Path(entry["path"]) for entry in curation["frames"]]
    students = [read_png(path, (64, 64)) for path in frame_paths]
    layer_paths = {name: BASE / "layers_v1" / f"{name}.png" for name in LAYER_ORDER if name != "student"}
    layers = {name: read_png(path, (64, 64)) for name, path in layer_paths.items()}
    frozen = json.loads((BASE / "classroom_v1/build_checks.json").read_text(encoding="utf-8"))["sources_sha256"]
    for path in [*layer_paths.values(), *frame_paths]:
        assert sha(path) == frozen[str(path.relative_to(BASE))], f"旧版已验收源发生变化：{path}"
    empty_station = compose_station(layers)
    assert empty_station.tobytes() == read_png(BASE / "layers_v1/all_furniture.png", (64, 64)).tobytes()
    assert compose_station(layers, students[0]).tobytes() == read_png(BASE / "seated_write_northeast_v1.png", (64, 64)).tobytes()
    stations = geometry["stations"]
    teacher_rect = geometry["teacher_reserve_rect"]
    collision_counts = []
    # 完整工位画布不能重叠老师预留区；真实可见像素也不能盖住新增授课家具。
    for index, entry in enumerate(stations):
        sx, sy = entry["origin"]
        rect = [sx, sy, 64, 64]
        assert 0 <= sx and sx + 64 <= 384 and 0 <= sy and sy + 64 <= 256
        assert not rectangles_intersect(rect, teacher_rect)
        for other in stations[:index]:
            assert not rectangles_intersect(rect, [*other["origin"], 64, 64])
        visible = np.asarray(compose_station(layers, students[0]))[:, :, 3] > 0
        count = int(np.count_nonzero(visible & changed[sy:sy + 64, sx:sx + 64]))
        assert count == 0, f"工位与真实讲台覆盖层相交：{entry['id']}"
        collision_counts.append({"station": entry["id"], "podium_changed_pixel_intersection": count})

    empty_room = compose_room(background, empty_station, stations)
    frames = [compose_room(background, compose_station(layers, student), stations) for student in students]
    for scale in [1, 2]:
        size = (384 * scale, 256 * scale)
        empty_room.resize(size, Image.Resampling.NEAREST).save(OUT / f"classroom_four_desks_{scale}x.png")
        frames[0].resize(size, Image.Resampling.NEAREST).save(OUT / f"classroom_four_students_{scale}x.png")
    frames_dir = OUT / "composed_frames"
    frames_dir.mkdir(exist_ok=True)
    for index, frame in enumerate(frames):
        frame.save(frames_dir / f"frame_{index:02d}.png")
    animated = [frame.resize((768, 512), Image.Resampling.NEAREST).convert("RGB") for frame in frames]
    animated[0].save(OUT / "classroom_writing_2x.gif", save_all=True, append_images=animated[1:], duration=durations, disposal=2, loop=0)
    annotated_layout(frames[0], geometry).save(OUT / "teacher_reserve_layout_3x.png")

    entries = [
        {"id": "room", "scope": "scene", "canvas": [384, 256], "frame_paths": [str(source_path)], "duration_ms": [sum(durations)]},
        {"id": "podium_overlay", "scope": "scene", "canvas": [384, 256], "frame_paths": [str(overlay_path)], "duration_ms": [sum(durations)]},
    ]
    for name in LAYER_ORDER:
        entries.append({"id": name, "scope": "station", "canvas": [64, 64],
                        "frame_paths": [str(path) for path in frame_paths] if name == "student" else [str(layer_paths[name])],
                        "duration_ms": durations if name == "student" else [sum(durations)]})
    manifest = {"schema_version": 1, "status": "ready", "canvas": [384, 256], "station_canvas": [64, 64],
                "station_anchor": [32, 60], "facing": "north-east", "stations": stations,
                "teacher_reserve_rect": teacher_rect, "teacher_foot_anchor": geometry["teacher_foot_anchor"],
                "podium_floor_polygon": geometry["podium_floor_polygon"], "lectern_rect": geometry["lectern_rect"],
                "animation_layer_id": "student", "layers": entries, "production_integration": False,
                "overlay_coordinate_binding": "覆盖层与classroom_v1/classroom_empty.png共用384×256画布原点，不可独立挪动。",
                "note": "本轮为讲台与老师预留区美术预览，正式游戏与教师动画尚未适配。"}
    write_json(OUT / "scene_manifest.json", manifest)
    paths = [source_path, crop_path, generated_path, OUT / "volume_guide_crop.png", OUT / "adopted_crop.png", mask_path, background_path, overlay_path, *layer_paths.values(), *frame_paths]
    checks = {"status": "pixel_checks_passed_gpu_review_pending", "sources_sha256": {str(path): sha(path) for path in paths},
              "raw_edit_outside_mask_changed_pixels": raw_outside_difference,
              "postprocess": "edit_image完整原稿不改，采用裁片仅保留白mask内真实返回像素；mask外取冻结源。",
              "mask_outside_changed_pixels": outside_difference, "changed_scene_pixels": int(np.count_nonzero(changed)),
              "exact_background_overlay_reconstruction": True, "frozen_station_sources_unchanged": True,
              "station_count": len(stations), "station_canvas_non_overlapping": True,
              "teacher_reserve_canvas_non_overlapping": True, "station_podium_checks": collision_counts,
              "duration_ms": durations, "loop_duration_ms": sum(durations),
              "limitations": ["老师只预留位置，没有生成新教师或动画。", "覆盖层包含平台、讲桌和局部地面，不能自由拆移。", "四人共用学生01外观与动作相位；正式游戏未切换。"]}
    write_json(OUT / "build_checks.json", checks)
    print(json.dumps({"status": checks["status"], "changed_pixels": checks["changed_scene_pixels"], "mask_outside_difference": outside_difference, "stations": len(stations), "frames": len(frames)}, ensure_ascii=False))


if __name__ == "__main__":
    build()
