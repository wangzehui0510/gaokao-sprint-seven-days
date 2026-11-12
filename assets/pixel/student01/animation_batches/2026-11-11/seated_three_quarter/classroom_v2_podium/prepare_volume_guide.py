"""为PixelLab第二次编辑准备明确体块引导，体块本身不作为交付美术。"""
from pathlib import Path
import json
from PIL import Image, ImageDraw

OUT = Path(__file__).resolve().parent


def prepare_guide():
    """按确认几何画出平台厚度和讲桌体积，避免模型将新增物体误判为空地。"""
    geometry = json.loads((OUT / "layout_geometry.json").read_text(encoding="utf-8"))
    source = Image.open(geometry["source_room"]).convert("RGBA")
    draw = ImageDraw.Draw(source)
    platform_top = [tuple(point) for point in geometry["platform_top_polygon"]]
    platform_floor = [tuple(point) for point in geometry["podium_floor_polygon"]]
    outline = "#535e51"
    # 平台仅高4像素，侧面配色与地砖协调，右半平台不放物体。
    for index in [1, 2]:
        following = (index + 1) % 4
        draw.polygon([platform_top[index], platform_top[following], platform_floor[following], platform_floor[index]], fill="#8b9177", outline=outline)
    draw.polygon(platform_top, fill="#c4bb92", outline=outline)
    lectern_top = [tuple(point) for point in geometry["lectern_top_polygon"]]
    lectern_floor = [tuple(point) for point in geometry["lectern_floor_polygon"]]
    # 讲桌顶面抬高19像素，两个实心木前脸形成完整体积。
    for index, fill in [(1, "#8b7755"), (2, "#a18a61")]:
        following = (index + 1) % 4
        draw.polygon([lectern_top[index], lectern_top[following], lectern_floor[following], lectern_floor[index]], fill=fill, outline="#625a46")
    draw.polygon(lectern_top, fill="#d0ba85", outline="#625a46")
    x, y, width, height = geometry["crop"]
    source.crop((x, y, x + width, y + height)).save(OUT / "volume_guide_crop.png")
    source.save(OUT / "volume_guide_scene.png")


if __name__ == "__main__":
    prepare_guide()
