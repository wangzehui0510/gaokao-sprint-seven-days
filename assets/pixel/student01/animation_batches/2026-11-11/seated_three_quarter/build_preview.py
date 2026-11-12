"""重建四工位的真实图层合成、动画预览和可供引擎读取的清单。"""
from pathlib import Path
import hashlib
import json
from PIL import Image, ImageDraw, ImageFont

BASE = Path(__file__).resolve().parent
OUT = BASE / "classroom_v1"
# 工位保持64像素原生画布，坐标是画布左上角；锚点是统一的局部地面参考。
STATIONS = [
    {"id": "S1_back", "origin": [160, 63]},
    {"id": "S2_left", "origin": [72, 107]},
    {"id": "S3_right", "origin": [248, 107]},
    {"id": "S4_front", "origin": [160, 151]},
]
LAYER_ORDER = ["desk_back", "chair_base", "student", "chair_front"]


def sha(path):
    """对每个使用的真实PNG保存文件摘要。"""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_png(path, size):
    """在边界统一检查画布尺寸，错误资源不自动缩放或降级。"""
    image = Image.open(path).convert("RGBA")
    assert image.size == size, f"资源尺寸不符：{path}"
    return image


def font(size):
    """使用系统中文字体绘制美术检查标签。"""
    return ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", size)


def compose_station(layers, student=None):
    """按后景桌、椅面、人物、前景椅背的顺序合成一个工位。"""
    result = Image.new("RGBA", (64, 64))
    for layer_id in LAYER_ORDER:
        layer = student if layer_id == "student" else layers[layer_id]
        if layer is not None:
            result.alpha_composite(layer)
    return result


def compose_room(background, station):
    """使用同一套独立桌椅图层摆放四个工位，无烘焙或重复家具。"""
    result = background.copy()
    for row in STATIONS:
        result.alpha_composite(station, tuple(row["origin"]))
    return result


def build():
    """构建静态与动态预览、图层图和明确采用版本的资源清单。"""
    background_path = OUT / "classroom_empty.png"
    background = read_png(background_path, (384, 256))
    layer_paths = {name: BASE / "layers_v1" / f"{name}.png" for name in LAYER_ORDER if name != "student"}
    layers = {name: read_png(path, (64, 64)) for name, path in layer_paths.items()}
    curation = json.loads((BASE / "animation_v1/curation.json").read_text(encoding="utf-8"))
    frame_paths = [Path(row["path"]) for row in curation["frames"]]
    students = [read_png(path, (64, 64)) for path in frame_paths]
    seed = read_png(BASE / "seated_write_northeast_v1.png", (64, 64))
    reconstructed = compose_station(layers, students[0])
    assert reconstructed.tobytes() == seed.tobytes(), "最终分层首帧未能精确重建批准关键帧。"
    empty_station = compose_station(layers)
    all_furniture = read_png(BASE / "layers_v1/all_furniture.png", (64, 64))
    assert all_furniture.tobytes() == empty_station.tobytes(), "空桌椅与三层家具的合成不一致。"
    # 每套家具的64像素画布全部位于场景内，各套占用框不重叠。
    for index, row in enumerate(STATIONS):
        x, y = row["origin"]
        assert 0 <= x and x + 64 <= 384 and 0 <= y and y + 64 <= 256
        for other in STATIONS[:index]:
            ox, oy = other["origin"]
            assert x + 64 <= ox or ox + 64 <= x or y + 64 <= oy or oy + 64 <= y
    empty_room = compose_room(background, empty_station)
    occupied_stations = [compose_station(layers, frame) for frame in students]
    occupied_rooms = [compose_room(background, station) for station in occupied_stations]
    for scale in [1, 2]:
        empty_room.resize((384 * scale, 256 * scale), Image.Resampling.NEAREST).save(OUT / f"classroom_four_desks_{scale}x.png")
        occupied_rooms[0].resize((384 * scale, 256 * scale), Image.Resampling.NEAREST).save(OUT / f"classroom_four_students_{scale}x.png")
    room_frames_dir = OUT / "composed_frames"
    room_frames_dir.mkdir(exist_ok=True)
    for index, room in enumerate(occupied_rooms):
        room.save(room_frames_dir / f"frame_{index:02d}.png")
    room_gif_frames = [im.resize((768, 512), Image.Resampling.NEAREST).convert("RGB") for im in occupied_rooms]
    room_gif_frames[0].save(OUT / "classroom_writing_2x.gif", save_all=True, append_images=room_gif_frames[1:],
                            duration=curation["duration_ms"], disposal=2, loop=0)
    # 图层分解只说明真实素材顺序，不把透明检查底色保存到正式PNG中。
    tiles = [("桌子 / 后层", layers["desk_back"]), ("椅面与后腿", layers["chair_base"]),
             ("人物 / 写字", students[0]), ("椅背 / 前层", layers["chair_front"]),
             ("分层重组", reconstructed), ("空桌椅", empty_station)]
    diagram = Image.new("RGB", (6 * 256, 320), "#e5eee8")
    draw = ImageDraw.Draw(diagram)
    for index, (label, tile) in enumerate(tiles):
        x0 = index * 256
        for y in range(40, 296, 16):
            for x in range(x0, x0 + 256, 16):
                draw.rectangle((x, y, x + 15, y + 15), fill="#d8e1da" if (x // 16 + y // 16) % 2 else "#c6d2c9")
        scaled = tile.resize((256, 256), Image.Resampling.NEAREST)
        diagram.paste(scaled, (x0, 40), scaled)
        draw.text((x0 + 14, 9), label, font=font(20), fill="#29433a")
    diagram.save(OUT / "layer_breakdown.png")
    entries = [{"id": "room", "scope": "scene", "canvas": [384, 256], "frame_paths": [str(background_path)], "duration_ms": [1100]}]
    for name in LAYER_ORDER:
        entries.append({"id": name, "scope": "station", "canvas": [64, 64],
                        "frame_paths": [str(p) for p in frame_paths] if name == "student" else [str(layer_paths[name])],
                        "duration_ms": curation["duration_ms"] if name == "student" else [sum(curation["duration_ms"])]})
    manifest = {"schema_version": 1, "status": "ready", "canvas": [384, 256], "station_canvas": [64, 64],
                "station_anchor": [32, 60], "facing": "north-east", "stations": STATIONS, "animation_layer_id": "student",
                "layers": entries, "production_integration": False,
                "note": "真实PNG资产与隔离美术预览，正式游戏的教师、其他动作和双人站位尚未适配。"}
    (OUT / "scene_manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    sources = {str(path.relative_to(BASE)): sha(path) for path in [background_path, *layer_paths.values(), *frame_paths]}
    checks = {"status": "pixel_checks_passed_gpu_review_pending", "sources_sha256": sources,
              "exact_approved_seed_reconstruction": True, "empty_station_layer_reconstruction": True,
              "station_count": 4, "station_canvas_non_overlapping": True, "integer_scales": [1, 2],
              "duration_ms": curation["duration_ms"], "loop_duration_ms": sum(curation["duration_ms"]),
              "limits": ["静态与逐帧美术合成不是正式游戏接入验收。", "四个学生暂共用学生01的外观和动作相位。"]}
    (OUT / "build_checks.json").write_text(json.dumps(checks, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"stations": 4, "frames": len(students), "manifest": str(OUT / "scene_manifest.json"), "pixel_checks": "passed"}, ensure_ascii=False))


if __name__ == "__main__":
    build()
