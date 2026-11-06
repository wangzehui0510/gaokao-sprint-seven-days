"""检查原生像素素材，并导出最近邻预览和可追溯的验收记录。"""

import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


# 所有输入都来自本项目的真实素材，不生成缺失方向的替代图。
PROJECT = Path(__file__).resolve().parents[1]
ASSETS = PROJECT / "assets" / "pixel"
PREVIEWS = ASSETS / "previews"
LABELS = {"south": "南 SOUTH", "east": "东 EAST", "north": "北 NORTH", "west": "西 WEST"}


def image_record(path):
    """读取真实图像尺寸、透明轮廓、颜色数和文件摘要。"""
    with Image.open(path) as source:
        image = source.convert("RGBA")
        bounds = image.getchannel("A").getbbox()
        return {
            "file": path.relative_to(ASSETS).as_posix(),
            "size": list(image.size),
            "visible_bbox": list(bounds) if bounds else None,
            "rgba_colors": len(image.getcolors(image.width * image.height)),
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        }


def character_sheet(directions):
    """将指定方向逐一放大，中文标签仅出现在预览图中。"""
    scale, cell_width, header, footer = 6, 208, 40, 24
    sheet = Image.new("RGB", (cell_width * len(directions), header + 48 * scale + footer), "#edf0ed")
    draw = ImageDraw.Draw(sheet)
    font = ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", 18)
    records = []
    for index, direction in enumerate(directions):
        path = ASSETS / "student01" / f"{direction}.png"
        sprite = Image.open(path).convert("RGBA")
        assert sprite.size == (32, 48), f"角色画布不符：{path} {sprite.size}"
        record = image_record(path)
        assert record["visible_bbox"] is not None, f"角色方向为空：{path}"
        raw_path = ASSETS / "student01" / "pixellab_raw" / "Idle" / "rotations" / f"{direction}.png"
        original = Image.open(raw_path).convert("RGBA")
        # 北向只做一像素下移；其余方向必须保留生成像素，禁止隐式缩放或重绘。
        offset_y = 1 if direction == "north" else 0
        expected = Image.new("RGBA", (32, 48))
        expected.paste(original, (0, offset_y))
        assert sprite.tobytes() == expected.tobytes(), f"方向像素与记录的对齐方式不符：{direction}"
        record["source_file"] = raw_path.relative_to(ASSETS).as_posix()
        record["source_offset"] = [0, offset_y]
        record["pixel_copy_verified"] = True
        records.append(record)
        x = index * cell_width + (cell_width - 32 * scale) // 2
        for row in range(12):
            for column in range(8):
                color = "#d5ded9" if (row + column) % 2 else "#e5ebe7"
                left, top = x + column * 24, header + row * 24
                draw.rectangle((left, top, left + 23, top + 23), fill=color)
        enlarged = sprite.resize((32 * scale, 48 * scale), Image.Resampling.NEAREST)
        sheet.paste(enlarged, (x, header), enlarged)
        draw.text((index * cell_width + 12, 8), LABELS[direction], font=font, fill="#263d36")
    sheet.save(PREVIEWS / "student01_directions_6x.png")
    return records


def scene_preview():
    """只合成一名站立角色，用真实脚点检验人物与教室的比例。"""
    scene = Image.open(ASSETS / "classroom" / "classroom.png").convert("RGBA")
    student = Image.open(ASSETS / "student01" / "south.png").convert("RGBA")
    assert scene.size == (384, 256), f"教室画布不符：{scene.size}"
    assert student.getchannel("A").getbbox() == (6, 4, 26, 44), "南向角色未满足40像素轮廓规范"
    # 脚点位于中央空旷通道；此图不替代坐姿或运行时排序实现。
    foot = (192, 152)
    scene.alpha_composite(student, (foot[0] - 16, foot[1] - 44))
    scene.save(PREVIEWS / "classroom_with_student.png")
    scene.resize((1152, 768), Image.Resampling.NEAREST).save(PREVIEWS / "classroom_with_student_3x.png")
    native = Image.open(ASSETS / "classroom" / "classroom.png")
    native.resize((1152, 768), Image.Resampling.NEAREST).save(PREVIEWS / "classroom_3x.png")
    student.resize((256, 384), Image.Resampling.NEAREST).save(PREVIEWS / "student_south_8x.png")


def main():
    """在明确指定方向后执行验收，任何缺失输入直接报错。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directions", nargs="+", choices=LABELS, default=list(LABELS))
    args = parser.parse_args()
    PREVIEWS.mkdir(parents=True, exist_ok=True)
    records = character_sheet(args.directions)
    scene_preview()
    layout = json.loads((ASSETS / "classroom" / "layout.json").read_text(encoding="utf-8"))
    assert len(layout["furniture"]) == 4, "教室学生座位必须为4个"
    assert layout["north_wall_height"] == 48, "教室北墙必须高48像素"
    assert layout["grid"] == {"width": 16, "height": 16}, "地砖网格必须为16像素"
    records.extend(image_record(path) for path in sorted((ASSETS / "classroom").glob("*.png")))
    report = {
        "version": "0.1.0",
        "date": "2026-11-06",
        "bbox_convention": "left_top_inclusive_right_bottom_exclusive",
        "directions_checked": args.directions,
        "student_foot_anchor": [16, 44],
        "classroom_student_desks": 4,
        "preview_character_count": 1,
        "preview_resampling": "nearest_neighbor_integer_scale",
        "files": records,
    }
    destination = ASSETS / "validation.json"
    destination.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"validation": str(destination), "directions": args.directions, "images_checked": len(records)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
