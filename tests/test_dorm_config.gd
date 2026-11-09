extends SceneTree
## 用生产加载入口验证宿舍配表，全部变更只写独占缓存，不修改正式数值与存档。

const CONFIG = preload("res://scripts/core/game_config.gd")
const CONFIG_PATH: String = "res://config/game_config.json"
const SCHEMA_PATH: String = "res://config/config_schema.json"
const DORM_ACTIONS: Array[String] = ["dorm_study", "dorm_practice", "dorm_game", "dorm_workout", "dorm_wash", "dorm_rest"]

# 配置副本与完整结果由本组独立持有，避免多个测试互相覆盖。
var baseline: Dictionary = {}
var fixture_root: String = ""
var checks: int = 0
var failures: Array[String] = []
var config_source: String = ""
var schema_source: String = ""


## 等场景树就绪后从正式JSON读取真实基线。
func _initialize() -> void:
	call_deferred("_run")


## 同时检查正式六项配置及入口拒绝，不以执行到部分用例代替整组完成。
func _run() -> void:
	config_source = FileAccess.get_file_as_string(CONFIG_PATH)
	schema_source = FileAccess.get_file_as_string(SCHEMA_PATH)
	baseline = JSON.parse_string(config_source)
	fixture_root = OS.get_cache_dir().path_join("ClassroomDormConfig_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	_check(DirAccess.make_dir_recursive_absolute(fixture_root) == OK, "创建独占配置目录")
	var original := CONFIG.new()
	if not _check(original.load_file() == OK, "正式配表加载：" + original.error_message):
		_finish()
		return
	for id: String in DORM_ACTIONS:
		var definition: Dictionary = original.actions[id]
		_check(definition.eligible_period == "dorm_free", id + "限定宿舍自由时段")
		_check(definition.source == "both" and definition.scene == "dorm" and definition.target == "self", id + "开放双方来源的宿舍个人入口")
	_check(is_equal_approx(original.actions.dorm_workout.knowledge_multiplier * original.subjects.physical.base_rate_per_min, 0.12), "健身基础体育速度0.12每分钟")
	_test_fields()
	_test_knowledge()
	_test_pool()
	_test_tuning()
	_check(FileAccess.get_file_as_string(CONFIG_PATH) == config_source, "正式JSON逐字保持不变")
	_check(FileAccess.get_file_as_string(SCHEMA_PATH) == schema_source, "正式结构逐字保持不变")
	_finish()


## 缺字段、未知枚举和非法类型必须在权威入口可见失败。
func _test_fields() -> void:
	for field: String in ["knowledge_source", "knowledge_mode", "knowledge_subject_id", "eligible_period"]:
		var missing: Dictionary = baseline.duplicate(true)
		_action(missing, "dorm_study").erase(field)
		_load_fixture(missing, "缺少字段" + field, false, field)
	for field: String in ["knowledge_source", "knowledge_mode", "eligible_period"]:
		for invalid: Variant in ["unknown", true, null]:
			var changed: Dictionary = baseline.duplicate(true)
			_action(changed, "dorm_study")[field] = invalid
			_load_fixture(changed, "%s非法值%s" % [field, invalid], false, field)


## 来源、科目方式、倍率与固定科目必须一致，禁止把恢复课当成宿舍知识。
func _test_knowledge() -> void:
	var cases: Array = [
		["knowledge_source", "none"], ["knowledge_source", "school"],
		["knowledge_mode", "none"], ["knowledge_mode", "course"],
		["knowledge_multiplier", -0.1], ["knowledge_multiplier", 0.0],
		["knowledge_subject_id", "math"], ["eligible_period", "any"],
		["scene", "classroom"], ["target", "pair"], ["kind", "instant"],
	]
	for change: Array in cases:
		var changed: Dictionary = baseline.duplicate(true)
		_action(changed, "dorm_study")[change[0]] = change[1]
		_load_fixture(changed, "自习契约%s=%s" % [change[0], change[1]], false)
	for invalid: Variant in [null, "music", "unknown_subject"]:
		var changed: Dictionary = baseline.duplicate(true)
		_action(changed, "dorm_workout").knowledge_subject_id = invalid
		_load_fixture(changed, "健身固定知识科目%s" % invalid, false)


## 课堂池不能混进宿舍候选，六项等权和资格在读表时统一保证。
func _test_pool() -> void:
	for change: Array in [["weight", 0], ["weight", -1], ["weight", 2], ["enabled", false], ["requires_same_scene_target", true], ["requires_affordable_start", false], ["eligible_period", "knowledge_course"], ["action_id", "study"]]:
		var changed: Dictionary = baseline.duplicate(true)
		_pool(changed, "dorm_study")[change[0]] = change[1]
		_load_fixture(changed, "宿舍候选%s=%s" % [change[0], change[1]], false)
	var duplicate: Dictionary = baseline.duplicate(true)
	var row: Dictionary = _pool(duplicate, "dorm_study").duplicate(true)
	row.id = "duplicate_dorm_study"
	duplicate.tables.auto_pool.append(row)
	_load_fixture(duplicate, "重复宿舍候选动作", false)
	var disabled: Dictionary = baseline.duplicate(true)
	_action(disabled, "dorm_game").enabled = false
	_load_fixture(disabled, "停用宿舍候选对应动作", false)


## 数值仍可调优，不把本次草案变成未经要求的业务上限或固定费率。
func _test_tuning() -> void:
	var changed: Dictionary = baseline.duplicate(true)
	_action(changed, "dorm_study").knowledge_multiplier = 0.25
	_action(changed, "dorm_study").duration_min_s = 900
	_action(changed, "dorm_study").duration_max_s = 1500
	for row: Dictionary in changed.tables.auto_pool:
		if row.eligible_period == "dorm_free":
			row.weight = 7.5
	_load_fixture(changed, "等权整体调优与时长倍率热改合法", true)


## 只定位测试副本的已有权威行，不为缺失行制造默认配置。
func _action(payload: Dictionary, id: String) -> Dictionary:
	for row: Dictionary in payload.tables.actions:
		if row.id == id:
			return row
	assert(false, "测试基线缺少动作：" + id)
	return {}


## 候选定位使用原动作ID，修改后不再次隐式寻找另一条候选。
func _pool(payload: Dictionary, id: String) -> Dictionary:
	for row: Dictionary in payload.tables.auto_pool:
		if row.action_id == id and row.eligible_period == "dorm_free":
			return row
	assert(false, "测试基线缺少宿舍候选：" + id)
	return {}


## 配置副本必须实际写盘并经生产加载器验证，失败须包含可定位原因。
func _load_fixture(payload: Dictionary, label: String, expected: bool, text: String = "") -> void:
	var path: String = fixture_root.path_join("fixture.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not _check(file != null, label + "写入副本"):
		return
	file.store_string(JSON.stringify(payload))
	file.close()
	var loaded := CONFIG.new()
	var result: Error = loaded.load_file(path)
	_check((result == OK) == expected, label + "加载结果：" + loaded.error_message)
	if not expected:
		_check(not loaded.error_message.is_empty(), label + "失败原因可见")
		if not text.is_empty():
			_check(text in loaded.error_message, label + "标明字段：" + loaded.error_message)


## 每项断言累计到最终退出结果，不能只打印PASS而吞掉失败。
func _check(condition: bool, label: String) -> bool:
	checks += 1
	if not condition:
		failures.append(label)
		printerr("FAIL：" + label)
	return condition


## 只清理本组明确创建的文件，退出码对应完整测试结果。
func _finish() -> void:
	var path: String = fixture_root.path_join("fixture.json")
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	if DirAccess.dir_exists_absolute(fixture_root):
		DirAccess.remove_absolute(fixture_root)
	print("宿舍配置检查：%d项，失败%d项" % [checks, failures.size()])
	if failures.is_empty():
		print("PASS test_dorm_config")
	quit(0 if failures.is_empty() else 1)
