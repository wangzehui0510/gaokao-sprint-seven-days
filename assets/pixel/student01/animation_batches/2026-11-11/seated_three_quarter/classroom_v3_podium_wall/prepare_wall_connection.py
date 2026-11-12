"""为平台贴墙和讲桌后方站位准备第二版体块引导。"""
from pathlib import Path
import hashlib
import json
from PIL import Image, ImageDraw

OUT = Path(__file__).resolve().parent
SOURCE = OUT.parent / "classroom_v2_podium" / "classroom_with_podium.png"
CROP = [172, 32, 160, 128]
# 平台后沿向墙面延伸，前沿保留学生通道；讲桌向前移，后方形成站位。
PLATFORM_TOP = [[199, 76], [326, 140], [287, 160], [181, 101]]
PLATFORM_FLOOR = [[x, y + 4] for x, y in PLATFORM_TOP]
LECTERN_TOP = [[232, 92], [260, 106], [242, 115], [214, 101]]
LECTERN_FLOOR = [[x, y + 19] for x, y in LECTERN_TOP]
LECTERN_RECT = [214, 92, 47, 43]
# 老师改为站在讲桌后方；真实教师仍待后续单独生成，本轮只记录预留画布。
TEACHER_RECT = [236, 78, 40, 56]
TEACHER_FOOT = [260, 126]
STATIONS = [
    {"id": "S1_front_left", "origin": [124, 93]},
    {"id": "S2_back_left", "origin": [60, 125]},
    {"id": "S3_front_right", "origin": [208, 135]},
    {"id": "S4_back_right", "origin": [144, 167]},
]


def sha(path):
    """记录冻结背景来源摘要，防止误用其他教室版本。"""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare():
    """输出原生裁片、二值遮罩、体块引导和本轮几何清单。"""
    OUT.mkdir(parents=True, exist_ok=True)
    source = Image.open(SOURCE).convert("RGBA")
    assert source.size == (384, 256)
    x, y, width, height = CROP
    crop = source.crop((x, y, x + width, y + height))
    crop.save(OUT / "source_crop.png")

    # 白色区域覆盖旧平台、旧讲桌和新增贴墙区域；其余房间保持冻结。
    mask = Image.new("L", source.size, 0)
    draw = ImageDraw.Draw(mask)
    draw.polygon(PLATFORM_TOP, fill=255)
    draw.polygon(PLATFORM_FLOOR, fill=255)
    for index in range(4):
        following = (index + 1) % 4
        draw.polygon([PLATFORM_TOP[index], PLATFORM_TOP[following], PLATFORM_FLOOR[following], PLATFORM_FLOOR[index]], fill=255)
    draw.rectangle((LECTERN_RECT[0], LECTERN_RECT[1], LECTERN_RECT[0] + LECTERN_RECT[2] - 1, LECTERN_RECT[1] + LECTERN_RECT[3] - 1), fill=255)
    # 只扩硬边1像素，保持PixelLab要求的纯黑白mask。
    from PIL import ImageFilter
    mask = mask.filter(ImageFilter.MaxFilter(3))
    mask.convert("RGB").save(OUT / "wall_connection_scene_mask.png")
    mask.crop((x, y, x + width, y + height)).convert("RGB").save(OUT / "wall_connection_crop_mask.png")

    # 在当前裁片上绘制清晰体块，作为编辑输入，不直接作为交付素材。
    guide = crop.copy()
    guide_draw = ImageDraw.Draw(guide)
    local_platform = [(px - x, py - y) for px, py in PLATFORM_TOP]
    local_floor = [(px - x, py - y) for px, py in PLATFORM_FLOOR]
    local_lectern = [(px - x, py - y) for px, py in LECTERN_TOP]
    local_lectern_floor = [(px - x, py - y) for px, py in LECTERN_FLOOR]
    # 平台后沿贴墙，侧面保持4像素；讲桌向前移，后方留出完整站位。
    guide_draw.polygon(local_platform, fill="#c4bb92", outline="#535e51")
    for index in [1, 2]:
        following = (index + 1) % 4
        guide_draw.polygon([local_platform[index], local_platform[following], local_floor[following], local_floor[index]], fill="#8b9177", outline="#535e51")
    guide_draw.polygon(local_lectern, fill="#d0ba85", outline="#625a46")
    for index, fill in [(1, "#8b7755"), (2, "#a18a61")]:
        following = (index + 1) % 4
        guide_draw.polygon([local_lectern[index], local_lectern[following], local_lectern_floor[following], local_lectern_floor[index]], fill=fill, outline="#625a46")
    guide.save(OUT / "wall_connection_volume_guide.png")

    geometry = {
        "canvas": [384, 256], "source_room": str(SOURCE), "source_room_sha256": sha(SOURCE), "crop": CROP,
        "platform_top_polygon": PLATFORM_TOP, "podium_floor_polygon": PLATFORM_FLOOR, "platform_height_px": 4,
        "lectern_top_polygon": LECTERN_TOP, "lectern_floor_polygon": LECTERN_FLOOR,
        "lectern_rect": LECTERN_RECT, "lectern_height_px": 19,
        "teacher_reserve_rect": TEACHER_RECT, "teacher_foot_anchor": TEACHER_FOOT,
        "teacher_facing": "south-west", "teacher_position": "behind_lectern",
        "stations": STATIONS, "user_change": "平台连接墙边，讲桌前移并为后方老师保留站位",
        "scope": "讲台版美术预览，老师预留区不等于新教师动画已完成。"
    }
    (OUT / "layout_geometry.json").write_text(json.dumps(geometry, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"crop": CROP, "source_sha256": geometry["source_room_sha256"], "teacher_reserve_rect": TEACHER_RECT}, ensure_ascii=False))


if __name__ == "__main__":
    prepare()
