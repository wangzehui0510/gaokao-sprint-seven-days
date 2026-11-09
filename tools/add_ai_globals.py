#!/usr/bin/env python3
"""向权威 Excel 的“参数”表追加 AI 升级所需的新全局参数（一次性迁移脚本）。

只读全部 zip 条目并替换 sheet11.xml（参数表），不触碰其他工作表。
文本沿用现有 x: 前缀与 t="str" 内联格式，数字用 t="n"。
默认只打印将追加的内容，传入 --apply 才实际写回工作簿。
"""
from __future__ import annotations

import shutil
import sys
import zipfile
from pathlib import Path

WORKBOOK = Path(r"d:\挂机上课\outputs\01a1aebc-daa9-7ca0-9b2c-d4652fa3194d\高考冲刺七天_配置_v0.2.xlsx")
SHEET_ENTRY = "xl/worksheets/sheet11.xml"

# 新增全局参数：key, name, value, unit, description（type 固定 number）
NEW_GLOBALS = [
    ("personality_ref_attr", "AI加权参考属性", 8, "点", "属性驱动行为加权的归一化参考值，默认取初始点上限。"),
    ("dorm_weight_floor", "宿舍活动保底概率", 0.05, "概率", "宿舍活动倾向加权后每项的最小概率下限，防止某项完全消失。"),
    ("social_auto_base", "自主互动基础概率", 0.08, "概率", "挂机角色在知识课决策点自主发起竞争互动的基础概率。"),
    ("g_study", "自律学习增益", 0.5, "系数", "自律性每点对自习、刷题、学习类候选权重的增益。"),
    ("g_game", "贪玩游戏增益", 0.5, "系数", "反向自律每点对宿舍打游戏候选权重的增益。"),
    ("g_workout", "好动健身增益", 0.5, "系数", "健康每点对健身、操场类候选权重的增益。"),
    ("g_playful", "贪玩开小差增益", 0.5, "系数", "反向自律每点对发呆、漫画等课堂开小差候选权重的增益。"),
    ("g_weak", "补弱科增益", 1.0, "系数", "选科时对知识量最低文化科的权重增益。"),
    ("g_lead", "领先目标增益", 1.0, "系数", "竞争互动选目标时对领先对手的权重增益。"),
    ("k_threshold", "开小差阈值调节", 0.4, "系数", "自律性对开小差专注阈值的下调幅度。"),
]


def cell(ref: str, style: int, kind: str, value: str) -> str:
    """生成与现有单元格一致的 XML 片段，文本走 t=str 内联、数字走 t=n。"""
    if kind == "n":
        return f'<x:c r="{ref}" s="{style}" t="n"><x:v>{value}</x:v></x:c>'
    return f'<x:c r="{ref}" s="{style}" t="str"><x:v>{value}</x:v></x:c>'


def build_rows(start_row: int) -> str:
    """按“参数”表六列（key/name/type/value/unit/description）生成新行。"""
    parts: list[str] = []
    row = start_row
    for key, name, value, unit, desc in NEW_GLOBALS:
        ref = lambda col: f"{col}{row}"
        value_text = repr(value) if isinstance(value, float) else str(value)
        cells = "".join([
            cell(ref("A"), 2, "str", key),
            cell(ref("B"), 2, "str", name),
            cell(ref("C"), 2, "str", "number"),
            cell(ref("D"), 18, "n", value_text),
            cell(ref("E"), 2, "str", unit),
            cell(ref("F"), 16, "str", desc),
        ])
        parts.append(f'<x:row r="{row}" ht="24" customHeight="1">{cells}</x:row>')
        row += 1
    return "".join(parts)


def main() -> int:
    if not WORKBOOK.exists():
        print(f"找不到工作簿：{WORKBOOK}", file=sys.stderr)
        return 1
    with zipfile.ZipFile(WORKBOOK) as archive:
        names = archive.namelist()
        if SHEET_ENTRY not in names:
            print(f"工作簿缺少参数表部件：{SHEET_ENTRY}", file=sys.stderr)
            return 1
        sheet_text = archive.read(SHEET_ENTRY).decode("utf-8")
        if "</x:sheetData>" not in sheet_text:
            print("参数表缺少 </x:sheetData> 结束标记，无法安全追加", file=sys.stderr)
            return 1
        rows_xml = build_rows(27)
        print("=== 将追加的新行 ===")
        print(rows_xml)

    if "--apply" not in sys.argv:
        print("\n（dry-run）未写回。追加 --apply 才实际修改工作簿。")
        return 0

    backup = WORKBOOK.with_suffix(".xlsx.bak")
    if not backup.exists():
        shutil.copy2(WORKBOOK, backup)
        print(f"已备份原工作簿到：{backup}")
    with zipfile.ZipFile(WORKBOOK) as archive:
        names = archive.namelist()
        sheet_text = archive.read(SHEET_ENTRY).decode("utf-8")
        new_text = sheet_text.replace("</x:sheetData>", rows_xml + "</x:sheetData>", 1)
        tmp = WORKBOOK.with_suffix(".xlsx.tmp")
        with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as out:
            for name in names:
                if name == SHEET_ENTRY:
                    out.writestr(name, new_text)
                else:
                    out.writestr(name, archive.read(name))
        shutil.move(str(tmp), str(WORKBOOK))
    print("已写回工作簿。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
