#!/usr/bin/env python3
"""按配置结构严格读取 Excel，并在全部校验通过后原子导出游戏 JSON。"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import math
import os
from pathlib import Path
import posixpath
import re
import sys
import tempfile
from typing import Any
import xml.etree.ElementTree as ET
import zipfile


class ConfigError(ValueError):
    """表示配置结构、单元格内容或业务引用存在明确错误。"""


@dataclass(frozen=True)
class Cell:
    """保留单元格原始类型，避免将空白误读成零或使用公式缓存。"""

    value: Any
    has_formula: bool = False


@dataclass
class Record:
    """关联一条配置数据及其 Excel 行号，便于定位校验失败。"""

    values: dict[str, Any]
    row: int


@dataclass
class Table:
    """保存导出表结构与数据，不包含非导出工作表。"""

    key: str
    sheet: str
    columns: list[dict[str, Any]]
    records: list[Record]

    def fail(self, record: Record, field: str, message: str) -> None:
        """抛出包含工作表、行号和字段名称的业务错误。"""
        fail(self.sheet, record.row, field, message)


def fail(sheet: str, row: int, field: str, message: str) -> None:
    """统一生成能够直接定位到单元格的错误信息。"""
    raise ConfigError(f'工作表“{sheet}”第 {row} 行，字段“{field}”：{message}')


def local_name(tag: str) -> str:
    """提取 XML 本地名称，兼容工作簿使用的命名空间前缀。"""
    return tag.rsplit("}", 1)[-1]


def nonblank(value: Any) -> bool:
    """判断是否含有实际数据，明确保留零和 False。"""
    return value is not None and not (isinstance(value, str) and not value.strip())


def column_number(letters: str) -> int:
    """将 Excel 列字母转换为从一开始的列号。"""
    result = 0
    for letter in letters:
        result = result * 26 + ord(letter) - ord("A") + 1
    return result


def column_letters(number: int) -> str:
    """将从一开始的列号转换为 Excel 列字母。"""
    result = ""
    while number:
        number, remainder = divmod(number - 1, 26)
        result = chr(ord("A") + remainder) + result
    return result


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    """拒绝 JSON 对象中的重复键，防止后值静默覆盖前值。"""
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ConfigError(f'配置结构中存在重复 JSON 键“{key}”')
        result[key] = value
    return result


def read_schema(path: Path) -> dict[str, Any]:
    """读取并检查导出结构，不为缺失的类型或列信息补默认值。"""
    with path.open(encoding="utf-8-sig") as stream:
        schema = json.load(stream, object_pairs_hook=unique_object)
    if not isinstance(schema, dict) or not isinstance(schema.get("version"), str):
        raise ConfigError("配置结构必须包含字符串 version")
    if not isinstance(schema.get("tables"), list) or not schema["tables"]:
        raise ConfigError("配置结构必须包含非空 tables 数组")
    table_keys: set[str] = set()
    sheet_names: set[str] = set()
    for table in schema["tables"]:
        if not isinstance(table, dict):
            raise ConfigError("tables 中的每个元素必须是对象")
        for name in ("key", "sheet"):
            if not isinstance(table.get(name), str) or not table[name].strip():
                raise ConfigError(f"表结构缺少有效的 {name}")
        if table["key"] in table_keys or table["sheet"].casefold() in sheet_names:
            raise ConfigError(f'配置结构存在重复表键或工作表名称：“{table["key"]}”')
        table_keys.add(table["key"])
        sheet_names.add(table["sheet"].casefold())
        if type(table.get("header_row")) is not int or table["header_row"] < 1:
            raise ConfigError(f'表“{table["key"]}”的 header_row 必须是正整数')
        if not isinstance(table.get("columns"), list) or not table["columns"]:
            raise ConfigError(f'表“{table["key"]}”必须声明非空 columns')
        fields: set[str] = set()
        for column in table["columns"]:
            if not isinstance(column, dict) or not isinstance(column.get("key"), str):
                raise ConfigError(f'表“{table["key"]}”包含无效列定义')
            if not column["key"] or column["key"] in fields:
                raise ConfigError(f'表“{table["key"]}”包含空字段或重复字段')
            fields.add(column["key"])
            if column.get("type") not in {"string", "number", "boolean", "any"}:
                raise ConfigError(f'字段“{table["key"]}.{column["key"]}”类型无效')
            if type(column.get("nullable")) is not bool:
                raise ConfigError(f'字段“{table["key"]}.{column["key"]}”必须声明 nullable')
    return schema


class Workbook:
    """仅使用标准库读取工作簿需要导出的工作表。"""

    def __init__(self, archive: zipfile.ZipFile) -> None:
        """读取工作簿关系与共享字符串，保留额外工作表而不导出。"""
        self.archive = archive
        relationships = self.xml("xl/_rels/workbook.xml.rels")
        # 内部关系是工作表路径的唯一来源，不猜测缺失部件的位置。
        self.relationships: dict[str, str] = {}
        shared_path: str | None = None
        for item in relationships:
            if local_name(item.tag) != "Relationship":
                continue
            if item.get("TargetMode") == "External":
                continue
            target = item.get("Target")
            relation_id = item.get("Id")
            if not target or not relation_id:
                raise ConfigError("工作簿关系缺少 Id 或 Target")
            resolved = target.lstrip("/") if target.startswith("/") else posixpath.normpath(posixpath.join("xl", target))
            if relation_id in self.relationships:
                raise ConfigError(f'工作簿关系标识重复：“{relation_id}”')
            self.relationships[relation_id] = resolved
            if item.get("Type", "").endswith("/sharedStrings"):
                shared_path = resolved
        # 只解析结构声明的工作表，额外验算页可以保留公式。
        self.sheets: dict[str, str] = {}
        for item in self.xml("xl/workbook.xml").iter():
            if local_name(item.tag) != "sheet":
                continue
            name = item.get("name")
            relation_id = next((v for k, v in item.attrib.items() if local_name(k) == "id"), None)
            if not name or relation_id not in self.relationships:
                raise ConfigError("工作表缺少名称或有效的内部工作簿关系")
            if name in self.sheets:
                raise ConfigError(f'工作簿含有重复工作表名称“{name}”')
            self.sheets[name] = self.relationships[relation_id]
        # 未提供共享字符串表时保留 None，遇到共享字符串引用再明确报错。
        self.shared_strings: list[str] | None = None
        if shared_path is not None:
            self.shared_strings = [self.text(item) for item in self.xml(shared_path) if local_name(item.tag) == "si"]

    def xml(self, path: str) -> ET.Element:
        """读取指定 XML 部件，缺少部件时直接报告损坏的工作簿。"""
        try:
            return ET.fromstring(self.archive.read(path))
        except KeyError as error:
            raise ConfigError(f'工作簿缺少 XML 部件“{path}”') from error

    @staticmethod
    def text(element: ET.Element) -> str:
        """合并普通与富文本字符串，不把拼音注释拼入单元格内容。"""
        parts: list[str] = []
        for child in element:
            if local_name(child.tag) == "t":
                parts.append(child.text or "")
            elif local_name(child.tag) == "r":
                parts.extend(node.text or "" for node in child if local_name(node.tag) == "t")
        return "".join(parts)

    def cell(self, element: ET.Element, sheet: str, row: int, field: str) -> Cell:
        """读取实际单元格类型，公式只标记而不读取其缓存结果。"""
        if any(local_name(child.tag) == "f" for child in element):
            return Cell(None, True)
        kind = element.get("t", "n")
        value_node = next((child for child in element if local_name(child.tag) == "v"), None)
        raw = value_node.text if value_node is not None else None
        if kind == "inlineStr":
            inline = next((child for child in element if local_name(child.tag) == "is"), None)
            return Cell(self.text(inline) if inline is not None else None)
        if raw is None or raw == "":
            return Cell(None)
        if kind == "s":
            if self.shared_strings is None or not re.fullmatch(r"\d+", raw):
                fail(sheet, row, field, "共享字符串索引无效或缺少共享字符串表")
            index = int(raw)
            if index >= len(self.shared_strings):
                fail(sheet, row, field, "共享字符串索引超出字符串表范围")
            return Cell(self.shared_strings[index])
        if kind == "b":
            if raw not in {"0", "1"}:
                fail(sheet, row, field, "布尔单元格必须存储 0 或 1")
            return Cell(raw == "1")
        if kind in {"str", "d"}:
            return Cell(raw)
        if kind == "e":
            fail(sheet, row, field, f"Excel 错误单元格：{raw}")
        if kind != "n":
            fail(sheet, row, field, f"不支持的 Excel 单元格类型：{kind}")
        try:
            number = float(raw)
        except ValueError:
            fail(sheet, row, field, f"无效数字：{raw}")
        if not math.isfinite(number):
            fail(sheet, row, field, "数字必须是有限值")
        return Cell(int(number) if number.is_integer() else number)

    def table(self, spec: dict[str, Any]) -> Table:
        """按固定表头逐列读取数据，拒绝未知列、公式与错误类型。"""
        sheet, columns = spec["sheet"], spec["columns"]
        if sheet not in self.sheets:
            raise ConfigError(f'工作簿缺少导出工作表“{sheet}”')
        rows: dict[int, dict[int, Cell]] = {}
        header_row = spec["header_row"]
        for node in self.xml(self.sheets[sheet]).iter():
            if local_name(node.tag) != "row":
                continue
            row_raw = node.get("r")
            if row_raw is None or not re.fullmatch(r"[1-9]\d*", row_raw):
                raise ConfigError(f'工作表“{sheet}”存在缺失或无效的行号')
            row = int(row_raw)
            if row < header_row:
                continue
            if row in rows:
                fail(sheet, row, "行号", "存在重复行")
            cells: dict[int, Cell] = {}
            for element in node:
                if local_name(element.tag) != "c":
                    continue
                coordinate = element.get("r", "")
                match = re.fullmatch(r"([A-Z]+)([1-9]\d*)", coordinate)
                if match is None or int(match.group(2)) != row:
                    fail(sheet, row, coordinate or "坐标", "单元格坐标缺失或与行号不一致")
                number = column_number(match.group(1))
                field = columns[number - 1]["key"] if number <= len(columns) else match.group(1)
                if number in cells:
                    fail(sheet, row, field, "存在重复单元格")
                cells[number] = self.cell(element, sheet, row, field)
            rows[row] = cells
        if header_row not in rows:
            fail(sheet, header_row, "表头", "缺少英文键表头行")
        header = rows[header_row]
        for number, column in enumerate(columns, 1):
            cell = header.get(number, Cell(None))
            if cell.has_formula:
                fail(sheet, header_row, column["key"], "英文键表头禁止使用公式")
            if cell.value != column["key"]:
                fail(sheet, header_row, column["key"], f'第 {column_letters(number)} 列应为英文键“{column["key"]}”，实际为 {cell.value!r}')
        result = Table(spec["key"], sheet, columns, [])
        for row, cells in sorted(rows.items()):
            for number, cell in cells.items():
                if number > len(columns) and (cell.has_formula or nonblank(cell.value)):
                    fail(sheet, row, column_letters(number), "存在结构未定义的未知字段或数据")
            if row == header_row:
                continue
            if not any(cell.has_formula or nonblank(cell.value) for cell in cells.values()):
                continue
            values: dict[str, Any] = {}
            for number, column in enumerate(columns, 1):
                cell = cells.get(number, Cell(None))
                if cell.has_formula:
                    fail(sheet, row, column["key"], "导出输入禁止使用公式，请填写明确值")
                values[column["key"]] = typed_value(cell.value, column, sheet, row)
            result.records.append(Record(values, row))
        return result


def typed_value(value: Any, column: dict[str, Any], sheet: str, row: int) -> Any:
    """按字段类型校验原值，只有明确的 TRUE/FALSE 字符串可转为布尔值。"""
    key, expected = column["key"], column["type"]
    if not nonblank(value):
        if column["nullable"]:
            return None
        fail(sheet, row, key, "必填字段为空，不能用零或默认值替代")
    if expected == "boolean" and isinstance(value, str) and value.strip().casefold() in {"true", "false"}:
        value = value.strip().casefold() == "true"
    valid = (expected == "any" and type(value) in {str, int, float, bool}) or (expected == "string" and isinstance(value, str)) or (expected == "number" and type(value) in {int, float}) or (expected == "boolean" and type(value) is bool)
    if not valid:
        fail(sheet, row, key, f"要求 {expected}，实际为 {type(value).__name__}：{value!r}")
    if type(value) in {int, float} and not math.isfinite(value):
        fail(sheet, row, key, "数字必须是有限值")
    if "enum" in column and value not in column["enum"]:
        fail(sheet, row, key, f'未知枚举值 {value!r}；允许值：{column["enum"]!r}')
    return value


# 枚举对应首版运行时能够解释的分型，未知值不能静默当成其他类型。
ENUMS = {
    "actions": {"kind": {"instant", "duration"}, "source": {"player", "auto", "both"}, "target": {"self", "pair", "group"}, "scene": {"any", "classroom", "playground", "canteen", "dorm", "course"}, "violation": {"none", "distraction"}, "completion_route": {"schedule", "study", "previous"}, "knowledge_source": {"school", "dorm", "none"}, "knowledge_mode": {"course", "selected_subject", "fixed_subject", "none"}, "eligible_period": {"any", "dorm_free"}},
    "effects": {"phase": {"start", "tick", "complete", "instant"}, "recipient": {"self", "target", "both", "ally", "winner", "loser"}, "type": {"resource", "apply_buff", "consume_item", "start_action", "event"}, "resource": {"focus", "stamina"}, "mode": {"flat", "max_ratio"}, "max_basis": {"current"}, "condition": {"always", "natural_entry", "selected_variant", "course_active", "winner", "loser", "tie"}, "event": {"forced_entry", "natural_entry", "close_violation", "deliver_note", "resolve_answer_challenge", "resolve_arm_wrestle", "interrupt_reading"}},
    "buffs": {"lifecycle": {"action", "timed"}, "stacking": {"refresh", "replace", "independent"}, "knowledge_redirect": {"none", "selected_subject"}},
    "globals": {"type": {"string", "number", "boolean"}},
    "subjects": {"kind": {"knowledge", "recovery", "exam"}},
    "periods": {"kind": {"lesson", "break", "exercise", "eye_exercise", "lunch", "rest"}},
    "auto_pool": {"eligible_period": {"knowledge_course", "dorm_free"}},
    "interrupt_policies": {"remaining_participants_route": {"schedule"}},
}


def validate_tables(tables: dict[str, Table]) -> None:
    """检查枚举、主键、引用和游戏配置之间的业务一致性。"""
    indexes: dict[str, dict[str, dict[Any, Record]]] = {}
    for key, table in tables.items():
        fields = {column["key"] for column in table.columns}
        indexes[key] = {field: {} for field in ("id", "key") if field in fields}
        for record in table.records:
            row = record.values
            for field, index in indexes[key].items():
                value = row[field]
                if not isinstance(value, str) or not value.strip() or value != value.strip():
                    table.fail(record, field, "主键必须是没有首尾空白的非空字符串")
                if value in index:
                    table.fail(record, field, f'重复主键 {value!r}；首次出现于第 {index[value].row} 行')
                index[value] = record
            for field, allowed in ENUMS.get(key, {}).items():
                if field in row and row[field] is not None and row[field] not in allowed:
                    table.fail(record, field, f"未知枚举值 {row[field]!r}；允许值：{', '.join(sorted(allowed))}")

    def reference(table: Table, record: Record, field: str, target: str, identity: str = "id") -> Record:
        """校验非空引用，引用表缺失也必须显式失败。"""
        value = record.values[field]
        if target not in indexes or identity not in indexes[target] or value not in indexes[target][identity]:
            table.fail(record, field, f"引用了未定义的 {target}.{identity}：{value!r}")
        return indexes[target][identity][value]

    references = {"action_id": "actions", "default_action_id": "actions", "interrupt_policy_id": "interrupt_policies", "buff_id": "buffs", "item_id": "items", "subject_id": "subjects", "knowledge_subject_id": "subjects", "period_id": "periods"}
    for key, table in tables.items():
        for record in table.records:
            row = record.values
            for field, target in references.items():
                if field in row and row[field] is not None:
                    if key == "periods" and field == "default_action_id" and row[field] == "current_course":
                        continue
                    reference(table, record, field, target)
            if "next_action_id" in row and row["next_action_id"] is not None and row["next_action_id"] != "current_course":
                reference(table, record, "next_action_id", "actions")
            for column in table.columns:
                target = column.get("ref")
                if target and row[column["key"]] is not None:
                    pieces = target.split(".")
                    if len(pieces) != 2:
                        raise ConfigError(f'字段“{key}.{column["key"]}”的 ref 必须形如 actions.id')
                    reference(table, record, column["key"], pieces[0], pieces[1])

    def number(table: Table, record: Record, field: str, positive: bool = False) -> float:
        """检查业务必需的数字，不接受布尔值、空白或隐式转换。"""
        value = record.values.get(field)
        if type(value) not in {int, float} or not math.isfinite(value):
            table.fail(record, field, "必须填写明确的有限数字")
        if positive and value <= 0:
            table.fail(record, field, "必须大于零")
        return value

    def integer(table: Table, record: Record, field: str, positive: bool = False) -> int:
        """检查离散数量与顺序字段，禁止使用小数。"""
        value = number(table, record, field, positive)
        if value != int(value):
            table.fail(record, field, "必须是整数")
        return int(value)

    def require_null(table: Table, record: Record, fields: tuple[str, ...]) -> None:
        """拒绝对当前动作或效果类型没有语义的额外参数。"""
        for field in fields:
            if record.values.get(field) is not None:
                table.fail(record, field, "当前类型必须留空，不得填写无效参数")

    if "globals" in tables:
        table = tables["globals"]
        for record in table.records:
            expected = record.values["type"]
            record.values["value"] = typed_value(record.values["value"], {"key": "value", "type": expected, "nullable": False}, table.sheet, record.row)
        # 与运行时使用同一概率契约；非法配表必须在导出边界明确失败。
        ai_keys = (
            "personality_ref_attr", "dorm_weight_floor", "social_auto_base",
            "g_study", "g_game", "g_workout", "g_playful", "g_weak", "g_lead",
            "k_threshold",
        )
        ai: dict[str, float] = {}
        for key in ai_keys:
            record = indexes["globals"]["key"].get(key)
            if record is None:
                raise ConfigError(f'工作表“{table.sheet}”缺少AI必需参数“{key}”')
            if record.values["type"] != "number":
                table.fail(record, "type", f"AI参数{key}必须声明为number")
            ai[key] = number(table, record, "value")
        if ai["personality_ref_attr"] <= 0:
            table.fail(indexes["globals"]["key"]["personality_ref_attr"], "value", "AI加权参考值必须大于零")
        if not 0 <= ai["dorm_weight_floor"] <= 1 / 6:
            table.fail(indexes["globals"]["key"]["dorm_weight_floor"], "value", "六项活动的保底概率必须在0至1/6之间")
        for key in ("g_study", "g_game", "g_workout", "g_playful", "g_weak", "g_lead"):
            if ai[key] < 0:
                table.fail(indexes["globals"]["key"][key], "value", "AI增益必须是非负有限数")
        if not 0 <= ai["k_threshold"] <= 1:
            table.fail(indexes["globals"]["key"]["k_threshold"], "value", "开小差阈值调节必须在0至1之间")
        social_probability = ai["social_auto_base"] * (1 + ai["g_game"])
        if ai["social_auto_base"] < 0 or not math.isfinite(social_probability) or social_probability > 1:
            table.fail(indexes["globals"]["key"]["social_auto_base"], "value", "必须非负，且与g_game组合后的发起概率不得超过1")
        if not math.isfinite(3 * (1 + ai["g_weak"])) or not math.isfinite(18 * (1 + ai["g_lead"])):
            raise ConfigError(f'工作表“{table.sheet}”的AI选科或竞争目标权重合计超出有限数字范围')
        gains = {
            "dorm_study": "g_study", "dorm_practice": "g_study",
            "dorm_game": "g_game", "dorm_workout": "g_workout",
            "playground_play": "g_workout", "daydream": "g_playful", "read_comic": "g_playful",
        }
        totals = {"dorm_free": 0.0, "knowledge_course": 0.0}
        for record in tables["auto_pool"].records:
            row = record.values
            if not row["enabled"]:
                continue
            gain = ai[gains[row["action_id"]]] if row["action_id"] in gains else 0
            maximum_weight = number(tables["auto_pool"], record, "weight") * (1 + gain)
            totals[row["eligible_period"]] += maximum_weight
            if not math.isfinite(maximum_weight) or not math.isfinite(totals[row["eligible_period"]]):
                tables["auto_pool"].fail(record, "weight", "AI属性加权或权重合计超出有限数字范围")

    if "npc_attributes" in tables:
        table = tables["npc_attributes"]
        if set(indexes["npc_attributes"]["id"]) != {"student_1", "student_2", "student_3"}:
            raise ConfigError("占位加点表必须完整包含student_1、student_2、student_3")
        initial = number(tables["globals"], indexes["globals"]["key"]["initial_attribute_points"], "value")
        for record in table.records:
            total = 0
            for attribute in ("attention", "discipline", "health", "intelligence"):
                value = integer(table, record, attribute)
                if value < 0:
                    table.fail(record, attribute, "占位初始属性必须为非负整数")
                total += value
            if total != initial:
                table.fail(record, "id", "每名占位角色必须恰好消耗初始属性点")

    if "actions" in tables:
        table = tables["actions"]
        for record in table.records:
            row = record.values
            if row["kind"] == "instant":
                require_null(table, record, ("duration_min_s", "duration_max_s"))
            else:
                low = number(table, record, "duration_min_s", True)
                high = number(table, record, "duration_max_s", True)
                if low > high:
                    table.fail(record, "duration_min_s", "持续时间最小值不能大于最大值")
            multiplier = number(table, record, "knowledge_multiplier")
            if multiplier < 0:
                table.fail(record, "knowledge_multiplier", "知识倍率不得为负数")
            source, mode = row["knowledge_source"], row["knowledge_mode"]
            if (source == "none") != (mode == "none") or (mode == "none") != (multiplier == 0):
                table.fail(record, "knowledge_source", "知识来源、方式与零知识倍率必须一致")
            if mode == "fixed_subject":
                subject = reference(table, record, "knowledge_subject_id", "subjects").values
                if subject["kind"] != "knowledge":
                    table.fail(record, "knowledge_subject_id", "固定知识归属必须引用知识科目")
            else:
                require_null(table, record, ("knowledge_subject_id",))
            if source == "school" and mode != "course":
                table.fail(record, "knowledge_mode", "在校知识必须使用当前知识课程")
            if source == "dorm" and (mode not in {"selected_subject", "fixed_subject"} or row["eligible_period"] != "dorm_free"):
                table.fail(record, "knowledge_mode", "宿舍知识必须显式选科或固定科目，并限定宿舍自由时段")
            if row["eligible_period"] == "dorm_free" and (row["scene"] != "dorm" or row["target"] != "self" or row["kind"] != "duration"):
                table.fail(record, "eligible_period", "宿舍自由活动必须是宿舍内的个人持续动作")

    if "effects" in tables:
        table, sequences = tables["effects"], set()
        for record in table.records:
            row = record.values
            action = reference(table, record, "action_id", "actions").values
            sequence = integer(table, record, "sequence")
            identity = (row["action_id"], row["phase"], sequence)
            if identity in sequences:
                table.fail(record, "sequence", f"同一 action/phase 下存在重复执行顺序：{identity!r}")
            sequences.add(identity)
            if action["kind"] == "instant" and row["phase"] != "instant":
                table.fail(record, "phase", "瞬时动作只允许 instant 阶段，不允许 tick 或持续阶段")
            if action["kind"] == "duration" and row["phase"] == "instant":
                table.fail(record, "phase", "持续动作应使用 start、tick 或 complete 阶段")
            if row["phase"] == "tick":
                number(table, record, "period_s", True)
            else:
                require_null(table, record, ("period_s",))
            if row["type"] == "resource":
                if row["resource"] not in {"focus", "stamina"} or row["mode"] not in {"flat", "max_ratio"}:
                    table.fail(record, "resource", "资源效果必须指定 focus/stamina 及 flat/max_ratio")
                number(table, record, "value")
                if row["mode"] == "max_ratio" and row["max_basis"] != "current":
                    table.fail(record, "max_basis", "上限百分比必须按 current 当前上限结算")
                if row["mode"] == "flat":
                    require_null(table, record, ("max_basis",))
                require_null(table, record, ("buff_id", "item_id", "next_action_id", "event"))
            else:
                require_null(table, record, ("resource", "mode", "max_basis"))
            if row["type"] == "apply_buff":
                reference(table, record, "buff_id", "buffs")
                require_null(table, record, ("value", "item_id", "next_action_id", "event"))
            elif row["type"] == "consume_item":
                reference(table, record, "item_id", "items")
                integer(table, record, "value", True)
                require_null(table, record, ("buff_id", "next_action_id", "event"))
            elif row["type"] == "start_action":
                if row["next_action_id"] != "current_course":
                    reference(table, record, "next_action_id", "actions")
                require_null(table, record, ("value", "buff_id", "item_id"))
                if row["event"] not in {"natural_entry", "forced_entry"}:
                    table.fail(record, "event", "启动下一动作必须明确 natural_entry 或 forced_entry 入段方式")
                if row["action_id"] == "focus_command" and row["condition"] != "course_active":
                    table.fail(record, "condition", "专注指令的课程启动效果必须明确限制为 course_active 课程时段")
            elif row["type"] == "event":
                if not nonblank(row["event"]):
                    table.fail(record, "event", "事件效果必须声明事件名称")
                require_null(table, record, ("value", "buff_id", "item_id", "next_action_id"))

    if "buffs" in tables:
        table, stack_groups = tables["buffs"], {}
        for record in table.records:
            if record.values["lifecycle"] == "timed":
                number(table, record, "duration_s", True)
            else:
                require_null(table, record, ("duration_s",))
            group = record.values.get("stack_group")
            if not isinstance(group, str) or not group.strip():
                table.fail(record, "stack_group", "必须填写明确的状态叠加组")
            strategy = record.values["stacking"]
            if group in stack_groups and stack_groups[group] != strategy:
                table.fail(record, "stacking", f"同一状态组 {group!r} 不能使用不同叠加策略")
            stack_groups[group] = strategy

    for pool_key in ("drop_pool", "auto_pool"):
        if pool_key not in tables:
            continue
        table, total_weight = tables[pool_key], 0.0
        for record in table.records:
            weight = number(table, record, "weight")
            if weight < 0:
                table.fail(record, "weight", "抽取权重不能为负数")
            if record.values["enabled"]:
                total_weight += weight
            if pool_key == "drop_pool":
                integer(table, record, "quantity", True)
        if total_weight <= 0:
            raise ConfigError(f'工作表“{table.sheet}”的启用项权重总和必须大于零')

    # 宿舍与课堂候选按时段隔离，六项使用等权基线，再由运行时按属性修正。
    if "auto_pool" in tables:
        table = tables["auto_pool"]
        expected = {"dorm_study", "dorm_practice", "dorm_game", "dorm_workout", "dorm_wash", "dorm_rest"}
        candidates: dict[str, float] = {}
        for record in table.records:
            row = record.values
            if row["eligible_period"] != "dorm_free":
                continue
            action = reference(table, record, "action_id", "actions").values
            if action["eligible_period"] != "dorm_free" or not action["enabled"] or row["requires_same_scene_target"] or not row["requires_affordable_start"]:
                table.fail(record, "action_id", "宿舍候选必须是已启用、可支付且无需同伴的宿舍个人活动")
            if not row["enabled"]:
                table.fail(record, "enabled", "已确认的宿舍六项候选必须启用")
            if row["action_id"] in candidates:
                table.fail(record, "action_id", "宿舍候选动作不得重复")
            weight = number(table, record, "weight", True)
            candidates[row["action_id"]] = weight
        if set(candidates) != expected or len(set(candidates.values())) != 1:
            raise ConfigError(f'工作表“{table.sheet}”的宿舍候选必须完整包含六项活动且使用相等的正权重')

    if "subjects" in tables:
        table = tables["subjects"]
        for record in table.records:
            row = record.values
            if row["kind"] == "knowledge":
                for field in ("base_rate_per_min", "max_score", "score_scale"):
                    number(table, record, field, True)
            elif row["kind"] == "recovery":
                if row["base_rate_per_min"] not in (None, 0):
                    table.fail(record, "base_rate_per_min", "恢复课程不得积累科目知识")
                require_null(table, record, ("knowledge_subject_id",))
                action = reference(table, record, "default_action_id", "actions").values
                if action["knowledge_multiplier"] != 0:
                    table.fail(record, "default_action_id", "恢复课程对应动作的 knowledge_multiplier 必须为零")
            elif row["kind"] == "exam":
                subject = reference(table, record, "knowledge_subject_id", "subjects").values
                if subject["kind"] != "knowledge":
                    table.fail(record, "knowledge_subject_id", "考试必须引用实际积累知识的科目")

    if "periods" in tables:
        table = tables["periods"]
        for record in table.records:
            for field in ("start_time", "end_time"):
                raw = record.values[field]
                if type(raw) not in {int, float} or not math.isfinite(raw) or not 0 <= raw <= 1:
                    table.fail(record, field, "时间必须是 Excel 原生时间数字，即一天的比例，范围为0至1")
            if record.values["start_time"] >= record.values["end_time"]:
                table.fail(record, "end_time", "时段结束必须晚于开始")

    if "schedule" in tables:
        table = tables["schedule"]
        if "periods" not in tables:
            raise ConfigError("导出课表时必须同时提供 periods 表")
        lessons = sorted((record.values for record in tables["periods"].records if record.values["kind"] == "lesson"), key=lambda row: row["start_time"])
        if len(lessons) != 7:
            raise ConfigError(f'工作表“{tables["periods"].sheet}”必须声明7个 lesson 时间槽')
        occupied: set[tuple[int, int]] = set()
        for record in table.records:
            day, slot = integer(table, record, "day", True), integer(table, record, "slot", True)
            if day not in range(1, 8) or slot not in range(1, 8):
                table.fail(record, "day/slot", "七天课表的 day 和 slot 必须在1至7之间")
            if (day, slot) in occupied:
                table.fail(record, "day/slot", f"第 {day} 天第 {slot} 节重复配置")
            occupied.add((day, slot))
            if record.values["period_id"] != lessons[slot - 1]["id"]:
                table.fail(record, "period_id", "引用时段必须与 slot 对应的第几节课一致")
        missing = {(day, slot) for day in range(1, 8) for slot in range(1, 8)} - occupied
        if missing:
            raise ConfigError(f'工作表“{table.sheet}”缺少七天课表位置：{sorted(missing)!r}')


def atomic_write(path: Path, payload: dict[str, Any]) -> None:
    """校验完成后写临时文件并原子替换，写入失败不修改已有 JSON。"""
    content = json.dumps(payload, ensure_ascii=False, indent=2, allow_nan=False) + "\n"
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", newline="\n", dir=path.parent, prefix=f".{path.name}.", suffix=".tmp", delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def main(argv: list[str] | None = None) -> int:
    """执行命令行导出，已知输入错误明确打印并返回非零退出码。"""
    parser = argparse.ArgumentParser(description="严格校验 Excel 游戏配置并导出 JSON")
    parser.add_argument("xlsx", type=Path, help="需要导出的 Excel 工作簿")
    parser.add_argument("--schema", type=Path, required=True, help="JSON 配置结构定义")
    parser.add_argument("--output", type=Path, required=True, help="输出 JSON 文件")
    args = parser.parse_args(argv)
    try:
        schema = read_schema(args.schema)
        with zipfile.ZipFile(args.xlsx) as archive:
            workbook = Workbook(archive)
            tables = {spec["key"]: workbook.table(spec) for spec in schema["tables"]}
        validate_tables(tables)
        payload = {"version": schema["version"], "schema_version": 1, "tables": {key: [record.values for record in table.records] for key, table in tables.items()}}
        atomic_write(args.output, payload)
    except (ConfigError, OSError, zipfile.BadZipFile, ET.ParseError, json.JSONDecodeError) as error:
        print(f"导出失败：{error}", file=sys.stderr)
        return 1
    print(f"已导出 {len(tables)} 张表、{sum(len(table.records) for table in tables.values())} 条配置：{args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
