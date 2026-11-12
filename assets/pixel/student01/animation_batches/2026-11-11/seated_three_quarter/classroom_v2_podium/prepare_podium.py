"""按已确认布局准备讲台局部重绘输入，冻结教室其他区域。"""
from pathlib import Path
import hashlib
import json
from PIL import Image, ImageDraw, ImageFilter

OUT = Path(__file__).resolve().parent
BASE = OUT.parent
# 截取原生像素区域，模型仅能修改讲台和讲桌的明确遮罩，不缩放整间教室。
CROP = [172, 32, 160, 128]
PLATFORM_TOP = [[211, 83], [317, 136], [287, 151], [181, 98]]
PLATFORM_FLOOR = [[x, y + 4] for x, y in PLATFORM_TOP]
LECTERN_TOP = [[240, 84], [268, 98], [250, 107], [222, 93]]
LECTERN_FOOT = [[x, y + 19] for x, y in LECTERN_TOP]
# 预留矩形覆盖未来老师完整画布；脚点位于平台内，讲桌在老师左侧。
TEACHER_RECT = [272, 80, 40, 56]
TEACHER_FOOT = [292, 132]
STATIONS = [
    {"id": "S1_front_left", "origin": [124, 93]},
    {"id": "S2_back_left", "origin": [60, 125]},
    {"id": "S3_front_right", "origin": [208, 135]},
    {"id": "S4_back_right", "origin": [144, 167]},
]


def sha(path):
    """记录输入字节摘要，保持前一版素材可追溯。"""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare():
    """输出同尺寸黑白mask、未改教室裁片及明确的授课区几何。"""
    OUT.mkdir(parents=True, exist_ok=True)
    source_path = BASE / "classroom_v1/classroom_empty.png"
    source = Image.open(source_path).convert("RGBA")
    assert source.size == (384, 256)
    x, y, width, height = CROP
    crop = source.crop((x, y, x + width, y + height))
    crop.save(OUT / "source_crop.png")
    mask = Image.new("L", source.size)
    draw = ImageDraw.Draw(mask)
    # 平台包括顶面与4像素的低矮前沿；讲桌遮罩允许桌面向上高出平台。
    draw.polygon(PLATFORM_TOP, fill=255)
    draw.polygon(PLATFORM_FLOOR, fill=255)
    for index in range(4):
        following = (index + 1) % 4
        draw.polygon([PLATFORM_TOP[index], PLATFORM_TOP[following], PLATFORM_FLOOR[following], PLATFORM_FLOOR[index]], fill=255)
    draw.rectangle((222, 84, 268, 126), fill=255)
    # 轮廓额外留1像素供模型绘制硬边，原生二值mask不添加抗锯齿。
    mask = mask.filter(ImageFilter.MaxFilter(3))
    mask.convert("RGB").save(OUT / "podium_scene_mask.png")
    mask.crop((x, y, x + width, y + height)).convert("RGB").save(OUT / "podium_crop_mask.png")
    geometry = {"canvas": [384, 256], "source_room": str(source_path), "source_room_sha256": sha(source_path),
                "crop": CROP, "platform_top_polygon": PLATFORM_TOP, "podium_floor_polygon": PLATFORM_FLOOR,
                "platform_height_px": 4, "lectern_top_polygon": LECTERN_TOP, "lectern_floor_polygon": LECTERN_FOOT,
                "lectern_rect": [222, 84, 47, 43], "lectern_height_px": 19,
                "teacher_reserve_rect": TEACHER_RECT, "teacher_foot_anchor": TEACHER_FOOT,
                "teacher_facing": "south-west", "stations": STATIONS,
                "user_choice": "矮平台＋讲桌，老师站桌旁（推荐）",
                "scope": "固定坐姿四工位美术预览，老师预留区不等于新教师动画已完成。"}
    (OUT / "layout_geometry.json").write_text(json.dumps(geometry, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"crop": CROP, "mask_bbox": mask.getbbox(), "teacher_reserve_rect": TEACHER_RECT}))


if __name__ == "__main__":
    prepare()
