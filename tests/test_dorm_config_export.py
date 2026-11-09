"""验证宿舍和AI配置从真实权威Excel导出，拒绝破坏来源、基础权重及概率契约的输入。"""

from __future__ import annotations

import copy
import json
from pathlib import Path
import sys
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import export_game_config as exporter


class DormConfigExportTests(unittest.TestCase):
    """所有配置基线来自正式Excel，测试副本只在内存中变更。"""

    @classmethod
    def setUpClass(cls) -> None:
        """读取真实结构与工作簿，保留原始字节用于检查测试无副作用。"""
        cls.workbook = ROOT / "outputs/01a1aebc-daa9-7ca0-9b2c-d4652fa3194d/高考冲刺七天_配置_v0.2.xlsx"
        cls.config_path = ROOT / "config/game_config.json"
        cls.original_workbook = cls.workbook.read_bytes()
        cls.original_config = cls.config_path.read_bytes()
        cls.schema = exporter.read_schema(ROOT / "config/config_schema.json")
        with zipfile.ZipFile(cls.workbook) as archive:
            workbook = exporter.Workbook(archive)
            cls.tables = {spec["key"]: workbook.table(spec) for spec in cls.schema["tables"]}

    @classmethod
    def tearDownClass(cls) -> None:
        """验证整组测试没有写入权威Excel或正式JSON。"""
        assert cls.workbook.read_bytes() == cls.original_workbook
        assert cls.config_path.read_bytes() == cls.original_config

    def setUp(self) -> None:
        """每个用例只改自己的完整结构副本。"""
        self.changed = copy.deepcopy(self.tables)

    def action(self, identity: str) -> exporter.Record:
        """按真实主键定位测试动作，不返回替代的空行。"""
        return next(record for record in self.changed["actions"].records if record.values["id"] == identity)

    def pool(self, identity: str) -> exporter.Record:
        """定位指定动作的宿舍池记录。"""
        return next(record for record in self.changed["auto_pool"].records if record.values["action_id"] == identity and record.values["eligible_period"] == "dorm_free")

    def parameter(self, key: str) -> exporter.Record:
        """定位真实全局参数，缺失时不提供测试默认值。"""
        return next(record for record in self.changed["globals"].records if record.values["key"] == key)

    def test_authoritative_export_matches_json(self) -> None:
        """权威Excel经生产校验后必须与交付JSON内容一致。"""
        exporter.validate_tables(self.changed)
        actual = {key: [record.values for record in table.records] for key, table in self.changed.items()}
        self.assertEqual(json.loads(self.original_config)["tables"], actual)
        self.assertEqual(len(actual["actions"]), 57)
        self.assertEqual(len(actual["effects"]), 179)

    def test_new_rates_and_selected_sources(self) -> None:
        """宿舍基础倍率、消耗和选科方式均来自真实源表。"""
        self.assertEqual(self.action("dorm_study").values["knowledge_mode"], "selected_subject")
        self.assertEqual(self.action("dorm_practice").values["knowledge_multiplier"], 0.35)
        physical = next(record.values for record in self.changed["subjects"].records if record.values["id"] == "physical")
        self.assertAlmostEqual(self.action("dorm_workout").values["knowledge_multiplier"] * physical["base_rate_per_min"], 0.12)
        focus_cost = next(record.values for record in self.changed["effects"].records if record.values["id"] == "dorm_study_tick_1")
        self.assertEqual((focus_cost["value"], focus_cost["period_s"]), (-0.6, 60))

    def test_invalid_knowledge_contract(self) -> None:
        """来源、方式与固定科目不一致时显式抛出配置错误。"""
        for field, value in [("knowledge_source", "none"), ("knowledge_source", "school"), ("knowledge_mode", "course"), ("knowledge_multiplier", 0), ("eligible_period", "any"), ("knowledge_subject_id", "math")]:
            with self.subTest(field=field, value=value):
                self.changed = copy.deepcopy(self.tables)
                self.action("dorm_study").values[field] = value
                with self.assertRaises(exporter.ConfigError):
                    exporter.validate_tables(self.changed)

    def test_fixed_subject_rejects_recovery_or_missing(self) -> None:
        """健身的固定知识归属不能指向恢复课或空科目。"""
        for invalid in [None, "music", "unknown_subject"]:
            with self.subTest(subject=invalid):
                self.changed = copy.deepcopy(self.tables)
                self.action("dorm_workout").values["knowledge_subject_id"] = invalid
                with self.assertRaises(exporter.ConfigError):
                    exporter.validate_tables(self.changed)

    def test_dorm_pool_equal_unique_complete(self) -> None:
        """等权、唯一、完整的六活动池不能被不合法配置破坏。"""
        for field, value in [("weight", 0), ("weight", 2), ("enabled", False), ("requires_same_scene_target", True), ("requires_affordable_start", False), ("eligible_period", "knowledge_course")]:
            with self.subTest(field=field, value=value):
                self.changed = copy.deepcopy(self.tables)
                self.pool("dorm_study").values[field] = value
                with self.assertRaises(exporter.ConfigError):
                    exporter.validate_tables(self.changed)
        self.changed = copy.deepcopy(self.tables)
        duplicate = copy.deepcopy(self.pool("dorm_study"))
        duplicate.values["id"] = "duplicate_dorm_study"
        self.changed["auto_pool"].records.append(duplicate)
        with self.assertRaises(exporter.ConfigError):
            exporter.validate_tables(self.changed)

    def test_all_equal_weights_remain_tunable(self) -> None:
        """基础权重保持相等，不额外限制为固定数值；运行时再叠加属性倾向。"""
        for record in self.changed["auto_pool"].records:
            if record.values["eligible_period"] == "dorm_free":
                record.values["weight"] = 7.5
        exporter.validate_tables(self.changed)

    def test_ai_parameter_ranges(self) -> None:
        """负参考值、不可行保底、越界概率与负增益必须在导出前拒绝。"""
        invalid = [
            ("personality_ref_attr", 0), ("personality_ref_attr", -1),
            ("dorm_weight_floor", -0.01), ("dorm_weight_floor", 1 / 6 + 0.001),
            ("social_auto_base", -0.1), ("social_auto_base", 1),
            ("k_threshold", -0.1), ("k_threshold", 1.1),
        ]
        invalid.extend((key, -0.1) for key in ("g_study", "g_game", "g_workout", "g_playful", "g_weak", "g_lead"))
        for key, value in invalid:
            with self.subTest(key=key, value=value):
                self.changed = copy.deepcopy(self.tables)
                self.parameter(key).values["value"] = value
                with self.assertRaises(exporter.ConfigError):
                    exporter.validate_tables(self.changed)

    def test_ai_parameter_presence_and_type(self) -> None:
        """AI所需参数必须显式存在且声明为数字，不能靠旧默认值继续导出。"""
        for key in ("personality_ref_attr", "dorm_weight_floor", "social_auto_base", "g_study", "g_game", "g_workout", "g_playful", "g_weak", "g_lead", "k_threshold"):
            with self.subTest(key=key):
                self.changed = copy.deepcopy(self.tables)
                record = self.parameter(key)
                self.changed["globals"].records.remove(record)
                with self.assertRaises(exporter.ConfigError):
                    exporter.validate_tables(self.changed)
        self.changed = copy.deepcopy(self.tables)
        self.parameter("g_study").values.update(type="string", value="0.5")
        with self.assertRaises(exporter.ConfigError):
            exporter.validate_tables(self.changed)

    def test_ai_weight_overflow(self) -> None:
        """输入本身有限但组合溢出的增益和权重不能流入随机抽样。"""
        for key in ("g_study", "g_game", "g_workout", "g_playful", "g_weak", "g_lead"):
            with self.subTest(key=key):
                self.changed = copy.deepcopy(self.tables)
                self.parameter(key).values["value"] = 1.7e308
                with self.assertRaises(exporter.ConfigError):
                    exporter.validate_tables(self.changed)

    def test_ai_probability_boundaries(self) -> None:
        """零概率和可行保底上界允许显式配置，不擅自新增业务下限。"""
        for floor in (0, 1 / 6):
            for threshold in (0, 1):
                with self.subTest(floor=floor, threshold=threshold):
                    self.changed = copy.deepcopy(self.tables)
                    self.parameter("dorm_weight_floor").values["value"] = floor
                    self.parameter("k_threshold").values["value"] = threshold
                    self.parameter("social_auto_base").values["value"] = 0
                    exporter.validate_tables(self.changed)
        self.changed = copy.deepcopy(self.tables)
        self.parameter("social_auto_base").values["value"] = 1
        self.parameter("g_game").values["value"] = 0
        exporter.validate_tables(self.changed)

    def test_npc_builds_are_authoritative(self) -> None:
        """新局预设由源表导出，身份、整数点数和总额不合法时明确拒绝。"""
        rows = [record.values for record in self.changed["npc_attributes"].records]
        self.assertEqual(rows, [
            {"id": "student_1", "attention": 1, "discipline": 4, "health": 1, "intelligence": 2},
            {"id": "student_2", "attention": 2, "discipline": 1, "health": 3, "intelligence": 2},
            {"id": "student_3", "attention": 2, "discipline": 1, "health": 5, "intelligence": 0},
        ])
        for field, invalid in [("id", "student_0"), ("attention", -1), ("attention", 0.5), ("attention", 7)]:
            with self.subTest(field=field, invalid=invalid):
                self.changed = copy.deepcopy(self.tables)
                self.changed["npc_attributes"].records[0].values[field] = invalid
                with self.assertRaises(exporter.ConfigError):
                    exporter.validate_tables(self.changed)


if __name__ == "__main__":
    unittest.main(verbosity=2)
