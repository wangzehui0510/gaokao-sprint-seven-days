"""合成贴墙讲台版预览，并核对讲桌后方老师站位与旧素材冻结情况。"""
from pathlib import Path
import hashlib
import json
import numpy as np
from PIL import Image, ImageDraw, ImageFont

OUT = Path(__file__).resolve().parent
ROOT = OUT.parent
V2 = ROOT / "classroom_v2_podium"
BASE = ROOT.parent
LAYER_ORDER = ["desk_back", "chair_base", "student", "chair_front"]


def sha(path):
    """记录真实PNG字节摘要，避免误用旧版或临时预览。"""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_png(path, size):
    """边界统一检查原生尺寸，错误时直接失败，不自动缩放。"""
    image = Image.open(path).convert("RGBA")
    assert image.size == size, f"资源尺寸不符：{path}"
    return image


def compose_station(layers, student=None):
    """保持桌、椅面、人物、椅背的既定遮挡顺序。"""
    result = Image.new("RGBA", (64, 64))
    for name in LAYER_ORDER:
        layer = student if name == "student" else layers[name]
        if layer is not None:
            result.alpha_composite(layer)
    return result


def compose_room(background, station, stations):
    """按新的贴墙讲台版工位坐标合成场景。"""
    result = background.copy()
    for entry in stations:
        result.alpha_composite(station, tuple(entry["origin"]))
    return result


def intersects(first, second):
    """检查半开矩形是否相交；老师预留框可与讲桌重叠，因为站位在讲桌后方。"""
    x, y, w, h = first
    ox, oy, ow, oh = second
    return x < ox + ow and ox < x + w and y < oy + oh and oy < y + h


def reserve_preview(scene, geometry):
    """输出带中文说明的站位图，标记不写入正式背景。"""
    scale = 3
    result = Image.new("RGB", (1152, 868), "#edf0e6")
    result.paste(scene.resize((1152, 768), Image.Resampling.NEAREST).convert("RGB"), (0, 50))
    draw = ImageDraw.Draw(result)
    font = ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", 22)
    draw.text((18, 12), "贴墙讲台：平台接墙，讲桌前移，老师站在讲桌后方", font=font, fill="#24372e")
    x, y, w, h = geometry["teacher_reserve_rect"]
    draw.rectangle((x * scale, y * scale + 50, (x + w) * scale - 1, (y + h) * scale + 49), outline="#bd367c", width=3)
    fx, fy = geometry["teacher_foot_anchor"]
    draw.ellipse((fx * scale - 4, fy * scale + 46, fx * scale + 4, fy * scale + 54), fill="#bd367c")
    draw.text((690, 225), "老师后方预留区", font=font, fill="#9c2b65")
    draw.text((18, 823), "紫框为40×56预留画布，圆点为脚点；本图不代表教师素材已完成。", font=font, fill="#24372e")
    return result


def build():
    """采用局部真实返回、重建新背景和四工位预览，并输出验收清单。"""
    geometry = json.loads((OUT / "layout_geometry.json").read_text(encoding="utf-8"))
    source_path = Path(geometry["source_room"])
    source = read_png(source_path, (384, 256))
    assert sha(source_path) == geometry["source_room_sha256"]
    crop = read_png(OUT / "source_crop.png", (160, 128))
    generated = read_png(OUT / "generated_crop_raw.png", (160, 128))
    mask = np.asarray(Image.open(OUT / "wall_connection_crop_mask.png").convert("L")) == 255
    crop_pixels = np.asarray(crop)
    raw_pixels = np.asarray(generated)
    adopted_pixels = crop_pixels.copy()
    adopted_pixels[mask] = raw_pixels[mask]
    adopted = Image.fromarray(adopted_pixels)
    adopted.save(OUT / "adopted_crop.png")
    raw_outside_difference = int(np.count_nonzero(np.any(crop_pixels[~mask] != raw_pixels[~mask], axis=1)))
    adopted_outside_difference = int(np.count_nonzero(np.any(crop_pixels[~mask] != adopted_pixels[~mask], axis=1)))
    assert adopted_outside_difference == 0
    background = source.copy()
    x, y, width, height = geometry["crop"]
    assert source.crop((x, y, x + width, y + height)).tobytes() == crop.tobytes()
    background.paste(adopted, (x, y))
    background.save(OUT / "classroom_with_wall_connected_podium.png")
    source_pixels = np.asarray(source)
    background_pixels = np.asarray(background)
    changed = np.any(source_pixels != background_pixels, axis=2)
    overlay_pixels = np.zeros((256, 384, 4), dtype=np.uint8)
    overlay_pixels[changed] = background_pixels[changed]
    overlay = Image.fromarray(overlay_pixels)
    overlay.save(OUT / "wall_connected_podium_overlay.png")
    rebuilt = source.copy()
    rebuilt.alpha_composite(overlay)
    assert rebuilt.tobytes() == background.tobytes()

    curation = json.loads((ROOT / "animation_v1/curation.json").read_text(encoding="utf-8"))
    durations = curation["duration_ms"]
    frames = [read_png(Path(row["path"]), (64, 64)) for row in curation["frames"]]
    layer_paths = {name: ROOT / "layers_v1" / f"{name}.png" for name in LAYER_ORDER if name != "student"}
    layers = {name: read_png(path, (64, 64)) for name, path in layer_paths.items()}
    old_checks = json.loads((V2 / "build_checks.json").read_text(encoding="utf-8"))
    for path in [*layer_paths.values(), *(Path(row["path"]) for row in curation["frames"])]:
        assert sha(path) == old_checks["sources_sha256"][str(path)]
    empty_station = compose_station(layers)
    station = compose_station(layers, frames[0])
    assert empty_station.tobytes() == read_png(ROOT / "layers_v1/all_furniture.png", (64, 64)).tobytes()
    assert station.tobytes() == read_png(ROOT / "seated_write_northeast_v1.png", (64, 64)).tobytes()

    stations = geometry["stations"]
    visible = np.asarray(station)[:, :, 3] > 0
    collisions = []
    for entry in stations:
        sx, sy = entry["origin"]
        assert 0 <= sx and sx + 64 <= 384 and 0 <= sy and sy + 64 <= 256
        collisions.append({"station": entry["id"], "visible_pixels_on_changed_podium": int(np.count_nonzero(visible & changed[sy:sy + 64, sx:sx + 64]))})
        assert collisions[-1]["visible_pixels_on_changed_podium"] == 0
    for index, entry in enumerate(stations):
        for other in stations[index + 1:]:
            assert not intersects([*entry["origin"], 64, 64], [*other["origin"], 64, 64])
    assert not intersects([*stations[0]["origin"], 64, 64], geometry["teacher_reserve_rect"])
    teacher_foot = geometry["teacher_foot_anchor"]
    # 脚点应位于平台顶面四边形包围范围内，便于后续教师精灵挂接。
    px = [point[0] for point in geometry["platform_top_polygon"]]
    py = [point[1] for point in geometry["platform_top_polygon"]]
    assert min(px) <= teacher_foot[0] <= max(px) and min(py) <= teacher_foot[1] <= max(py)

    empty_room = compose_room(background, empty_station, stations)
    rooms = [compose_room(background, compose_station(layers, frame), stations) for frame in frames]
    for scale in [1, 2]:
        size = (384 * scale, 256 * scale)
        empty_room.resize(size, Image.Resampling.NEAREST).save(OUT / f"classroom_four_desks_{scale}x.png")
        rooms[0].resize(size, Image.Resampling.NEAREST).save(OUT / f"classroom_four_students_{scale}x.png")
    frame_dir = OUT / "composed_frames"
    frame_dir.mkdir(exist_ok=True)
    for index, room in enumerate(rooms):
        room.save(frame_dir / f"frame_{index:02d}.png")
    gif_frames = [room.resize((768, 512), Image.Resampling.NEAREST).convert("RGB") for room in rooms]
    gif_frames[0].save(OUT / "classroom_writing_2x.gif", save_all=True, append_images=gif_frames[1:], duration=durations, disposal=2, loop=0)
    reserve_preview(rooms[0], geometry).save(OUT / "teacher_behind_lectern_layout_3x.png")

    entries = [
        {"id": "room", "scope": "scene", "canvas": [384, 256], "frame_paths": [str(source_path)], "duration_ms": [sum(durations)]},
        {"id": "wall_connected_podium_overlay", "scope": "scene", "canvas": [384, 256], "frame_paths": [str(OUT / "wall_connected_podium_overlay.png")], "duration_ms": [sum(durations)]},
    ]
    for name in LAYER_ORDER:
        entries.append({"id": name, "scope": "station", "canvas": [64, 64], "frame_paths": [str(path) for path in (Path(row["path"]) for row in curation["frames"])] if name == "student" else [str(layer_paths[name])], "duration_ms": durations if name == "student" else [sum(durations)]})
    manifest = {"schema_version": 1, "status": "ready", "canvas": [384, 256], "station_canvas": [64, 64], "station_anchor": [32, 60], "facing": "north-east", "stations": stations, "teacher_reserve_rect": geometry["teacher_reserve_rect"], "teacher_foot_anchor": teacher_foot, "teacher_position": "behind_lectern", "podium_floor_polygon": geometry["podium_floor_polygon"], "lectern_rect": geometry["lectern_rect"], "layers": entries, "animation_layer_id": "student", "production_integration": False, "overlay_coordinate_binding": "覆盖层与classroom_v2_podium/classroom_with_podium.png共用384×256画布原点，不可独立挪动。", "note": "本轮为平台贴墙与讲桌后方站位美术预览，正式游戏与教师动画尚未适配。"}
    (OUT / "scene_manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    sources = [source_path, OUT / "source_crop.png", OUT / "generated_crop_raw.png", OUT / "adopted_crop.png", OUT / "wall_connection_crop_mask.png", OUT / "classroom_with_wall_connected_podium.png", OUT / "wall_connected_podium_overlay.png", *layer_paths.values(), *(Path(row["path"]) for row in curation["frames"])]
    checks = {"status": "pixel_checks_passed_visual_review_pending", "source_sha256": {str(path): sha(path) for path in sources}, "raw_edit_outside_mask_changed_pixels": raw_outside_difference, "adopted_outside_mask_changed_pixels": adopted_outside_difference, "changed_scene_pixels": int(np.count_nonzero(changed)), "room_overlay_reconstruction": True, "frozen_station_sources_unchanged": True, "station_podium_visible_collisions": collisions, "teacher_position": "behind_lectern", "teacher_foot_anchor": teacher_foot, "station_count": len(stations), "duration_ms": durations, "loop_duration_ms": sum(durations), "limitations": ["老师仅预留在讲桌后方，没有教师精灵或动画。", "覆盖层含局部背景，与v2背景坐标绑定，不能自由移动。", "四人共用学生01外观和相位；正式游戏未切换。"]}
    (OUT / "build_checks.json").write_text(json.dumps(checks, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": checks["status"], "raw_outside_mask_changed_pixels": raw_outside_difference, "adopted_outside_mask_changed_pixels": adopted_outside_difference, "changed_scene_pixels": checks["changed_scene_pixels"], "station_collisions": collisions}, ensure_ascii=False))


if __name__ == "__main__":
    build()
