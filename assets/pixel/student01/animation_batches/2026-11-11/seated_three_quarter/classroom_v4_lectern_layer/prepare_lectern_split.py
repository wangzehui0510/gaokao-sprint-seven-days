"""准备讲桌独立层拆分：清理背景中讲桌区域，并生成严格矩形mask。"""
from pathlib import Path
import hashlib
import json
from PIL import Image, ImageDraw, ImageFilter

OUT = Path(__file__).resolve().parent
SOURCE = OUT.parent / "classroom_v3_podium_wall" / "classroom_with_wall_connected_podium.png"
CROP = [172, 32, 160, 128]
# 遮罩覆盖讲桌完整包围区域，平台和黑板外的房间不参与重绘。
LECTERN_CLEAR_RECT = [209, 88, 58, 52]


def sha(path):
    """记录v3完整场景摘要，防止从旧版本拆分讲桌。"""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare():
    """输出v3裁片与严格二值清理遮罩。"""
    OUT.mkdir(parents=True, exist_ok=True)
    source = Image.open(SOURCE).convert("RGBA")
    assert source.size == (384, 256)
    x, y, width, height = CROP
    source.crop((x, y, x + width, y + height)).save(OUT / "source_crop.png")
    mask = Image.new("L", source.size, 0)
    draw = ImageDraw.Draw(mask)
    rx, ry, rw, rh = LECTERN_CLEAR_RECT
    draw.rectangle((rx, ry, rx + rw - 1, ry + rh - 1), fill=255)
    # 清理区域向外留1像素硬边，避免旧讲桌轮廓留在平台上。
    mask = mask.filter(ImageFilter.MaxFilter(3))
    mask.convert("RGB").save(OUT / "lectern_clear_scene_mask.png")
    mask.crop((x, y, x + width, y + height)).convert("RGB").save(OUT / "lectern_clear_crop_mask.png")
    geometry = {
        "canvas": [384, 256], "source_room": str(SOURCE), "source_room_sha256": sha(SOURCE), "crop": CROP,
        "lectern_clear_rect": LECTERN_CLEAR_RECT,
        "lectern_layer_scope": "仅讲桌本体，透明区域不含平台和墙面",
        "teacher_reserve_rect": [236, 78, 40, 56], "teacher_foot_anchor": [260, 126],
        "teacher_position": "behind_lectern", "production_integration": False,
        "note": "本轮将讲桌拆为独立透明层，背景仅保留贴墙平台。"
    }
    (OUT / "split_geometry.json").write_text(json.dumps(geometry, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"source_sha256": geometry["source_room_sha256"], "crop": CROP, "clear_rect": LECTERN_CLEAR_RECT}, ensure_ascii=False))


if __name__ == "__main__":
    prepare()
