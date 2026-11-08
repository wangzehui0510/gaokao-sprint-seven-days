extends SceneTree
## 仅用独占缓存中的真实配置副本验证每日奖励入口，不改源JSON、Excel或正式存档。

const CONFIG = preload("res://scripts/core/game_config.gd")
const CONFIG_PATH: String = "res://config/game_config.json"
const SCHEMA_PATH: String = "res://config/config_schema.json"

# 每次运行独占目录及其文件列表，清理只作用于本次创建的配置副本。
var fixture_root: String = ""
var fixture_files: Array[String] = []
var baseline: Dictionary = {}
var config_source: String = ""
var schema_source: String = ""
# 参数行索引只从真实原始配置定位，不以测试默认值补造缺失参数。
var draw_count_index: int = -1
var replacement_index: int = -1
var checks: int = 0
var failures: Array[String] = []


## 等待场景树就绪后执行真实文件加载专项。
func _initialize() -> void:
	call_deferred("_run")


## 错误场景必须经过生产配置入口，并同时验证成功配置原样保留数值。
func _run() -> void:
	var original := CONFIG.new()
	if not _check(original.load_file() == OK, "正式配置应通过每日奖励校验：%s" % original.error_message):
		_finish()
		return
	config_source = FileAccess.get_file_as_string(CONFIG_PATH)
	schema_source = FileAccess.get_file_as_string(SCHEMA_PATH)
	var parsed: Variant = JSON.parse_string(config_source)
	if not _check(parsed is Dictionary, "正式配置JSON完整解析"):
		_finish()
		return
	baseline = parsed
	for index in baseline.tables.globals.size():
		var row: Dictionary = baseline.tables.globals[index]
		if row.key == "daily_item_draw_count":
			draw_count_index = index
		elif row.key == "daily_item_with_replacement":
			replacement_index = index
	if not _check(draw_count_index >= 0 and replacement_index >= 0, "真实配置包含两个每日奖励参数"):
		_finish()
		return
	fixture_root = OS.get_cache_dir().path_join("ClassroomDailyRewardConfig_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	if not _check(DirAccess.make_dir_recursive_absolute(fixture_root) == OK, "建立本次独占配置目录"):
		_finish()
		return
	_test_draw_count()
	_test_replacement_parameter()
	_test_quantities()
	_test_weight_boundaries()
	_test_without_replacement()
	_check(FileAccess.get_file_as_string(CONFIG_PATH) == config_source, "源JSON逐字保持不变")
	_check(FileAccess.get_file_as_string(SCHEMA_PATH) == schema_source, "字段契约逐字保持不变")
	_finish()


## 抽取次数必须显式声明为数字正整数，合法次数不写死为三或附加人为上限。
func _test_draw_count() -> void:
	var missing: Dictionary = baseline.duplicate(true)
	missing.tables.globals.remove_at(draw_count_index)
	_load_fixture(missing, "缺少每日抽取次数", false, "daily_item_draw_count")
	for invalid: Variant in [0, -1, 0.5, 3.1, true, "3", null]:
		var changed: Dictionary = baseline.duplicate(true)
		changed.tables.globals[draw_count_index].value = invalid
		_load_fixture(changed, "非法抽取次数%s" % str(invalid), false, "value" if invalid == null else "daily_item_draw_count")
	var wrong_declaration: Dictionary = baseline.duplicate(true)
	wrong_declaration.tables.globals[draw_count_index].type = "string"
	wrong_declaration.tables.globals[draw_count_index].value = "3"
	_load_fixture(wrong_declaration, "抽取次数错误声明为字符串", false, "daily_item_draw_count")
	for count_value: Variant in [1, 2, 4, 1000000, 1000000000000]:
		var changed: Dictionary = baseline.duplicate(true)
		changed.tables.globals[draw_count_index].value = count_value
		var loaded: GameConfig = _load_fixture(changed, "合法次数%s" % count_value, true)
		if loaded != null:
			_check(loaded.global_value("daily_item_draw_count") == count_value, "合法抽取次数原样保留")


## 放回策略必须显式存在并声明为布尔类型，不强制把合法false改为true。
func _test_replacement_parameter() -> void:
	var missing: Dictionary = baseline.duplicate(true)
	missing.tables.globals.remove_at(replacement_index)
	_load_fixture(missing, "缺少每日放回开关", false, "daily_item_with_replacement")
	for invalid: Variant in [0, 1, "true", null]:
		var changed: Dictionary = baseline.duplicate(true)
		changed.tables.globals[replacement_index].value = invalid
		_load_fixture(changed, "非法放回开关%s" % str(invalid), false, "value" if invalid == null else "daily_item_with_replacement")
	var wrong_declaration: Dictionary = baseline.duplicate(true)
	wrong_declaration.tables.globals[replacement_index].type = "number"
	wrong_declaration.tables.globals[replacement_index].value = 1
	_load_fixture(wrong_declaration, "放回开关错误声明为数字", false, "daily_item_with_replacement")
	for replacement: bool in [true, false]:
		var changed: Dictionary = baseline.duplicate(true)
		changed.tables.globals[replacement_index].value = replacement
		var loaded: GameConfig = _load_fixture(changed, "合法放回开关%s" % str(replacement), true)
		if loaded != null:
			_check(loaded.global_value("daily_item_with_replacement") == replacement, "放回开关原样保留")


## 所有奖池行的发放数量必须为正整数，停用行也不能保留损坏数量。
func _test_quantities() -> void:
	for invalid: Variant in [0, -1, 0.5, 2.5, true, "2", null]:
		var changed: Dictionary = baseline.duplicate(true)
		changed.tables.drop_pool[0].quantity = invalid
		_load_fixture(changed, "非法物品数量%s" % str(invalid), false, "quantity")
	var disabled: Dictionary = baseline.duplicate(true)
	disabled.tables.drop_pool[0].enabled = false
	disabled.tables.drop_pool[0].quantity = 1.5
	_load_fixture(disabled, "停用行小数数量仍拒绝", false, "quantity")
	var large: Dictionary = baseline.duplicate(true)
	large.tables.drop_pool[0].quantity = 1000000000000
	var loaded: GameConfig = _load_fixture(large, "大整数数量无额外上限", true)
	if loaded != null:
		_check(loaded.tables.drop_pool[0].quantity == 1000000000000, "大整数数量原样保留")


## 有效奖池只由启用正权重行构成，既拒绝空池也拒绝有限权重相加溢出。
func _test_weight_boundaries() -> void:
	var empty: Dictionary = baseline.duplicate(true)
	empty.tables.drop_pool = []
	_load_fixture(empty, "空奖池", false, "权重")
	for mode: String in ["disabled", "zero", "mixed"]:
		var changed: Dictionary = baseline.duplicate(true)
		for row: Dictionary in changed.tables.drop_pool:
			row.enabled = mode == "zero"
			row.weight = 0.0 if mode == "zero" else 10.0
		if mode == "mixed":
			changed.tables.drop_pool[0].enabled = true
			changed.tables.drop_pool[0].weight = 0.0
		_load_fixture(changed, "有效正权重奖池为空%s" % mode, false, "权重")
	for invalid: Variant in [-1, true, "30", null]:
		var changed: Dictionary = baseline.duplicate(true)
		changed.tables.drop_pool[0].weight = invalid
		_load_fixture(changed, "非法权重%s" % str(invalid), false)
	var overflow: Dictionary = baseline.duplicate(true)
	for row: Dictionary in overflow.tables.drop_pool:
		row.weight = 1.0e308
	_load_fixture(overflow, "每项有限但有效权重和溢出", false, "权重")
	var disabled_overflow: Dictionary = baseline.duplicate(true)
	for row: Dictionary in disabled_overflow.tables.drop_pool:
		row.weight = 1.0e308
		row.enabled = false
	disabled_overflow.tables.drop_pool[0].enabled = true
	disabled_overflow.tables.drop_pool[0].weight = 1.0
	_load_fixture(disabled_overflow, "停用行不计入有效权重和", true)
	var very_small: Dictionary = baseline.duplicate(true)
	for row: Dictionary in very_small.tables.drop_pool:
		row.weight = 0.0
	# 引擎序列化极小浮点数会输出零；此处显式写入合法JSON数字字面量验证真实读取能力。
	very_small.tables.drop_pool[0].weight = "TINY_POSITIVE_WEIGHT"
	var tiny_source: String = JSON.stringify(very_small).replace('"TINY_POSITIVE_WEIGHT"', "1e-300")
	_load_fixture_source(tiny_source, "极小正权重不设置人为下限", true)
	var very_large: Dictionary = baseline.duplicate(true)
	for row: Dictionary in very_large.tables.drop_pool:
		row.weight = 1.0e300
	_load_fixture(very_large, "巨大但总和有限的权重", true)


## 无放回检查的是有效奖池行数，零权重、停用和同物品多行均按明确语义处理。
func _test_without_replacement() -> void:
	var exact: Dictionary = baseline.duplicate(true)
	exact.tables.globals[draw_count_index].value = 3
	exact.tables.globals[replacement_index].value = false
	exact.tables.drop_pool[3].enabled = false
	exact.tables.drop_pool[4].weight = 0.0
	_load_fixture(exact, "三条有效行无放回抽三次", true)
	var insufficient: Dictionary = exact.duplicate(true)
	insufficient.tables.globals[draw_count_index].value = 4
	_load_fixture(insufficient, "停用和零权重不补足无放回行数", false, "无放回")
	var replacement: Dictionary = insufficient.duplicate(true)
	replacement.tables.globals[replacement_index].value = true
	_load_fixture(replacement, "有放回允许次数超过有效行数", true)
	var duplicate_items: Dictionary = baseline.duplicate(true)
	duplicate_items.tables.globals[draw_count_index].value = duplicate_items.tables.drop_pool.size()
	duplicate_items.tables.globals[replacement_index].value = false
	for row: Dictionary in duplicate_items.tables.drop_pool:
		row.item_id = duplicate_items.tables.drop_pool[0].item_id
	_load_fixture(duplicate_items, "同物品多条有效池行仍各占一次机会", true)


## 普通副本保留浮点完整精度后交给实际文件读取入口。
func _load_fixture(data: Dictionary, label: String, accepted: bool, error_fragment: String = "") -> GameConfig:
	return _load_fixture_source(JSON.stringify(data, "", true, true), label, accepted, error_fragment)


## 将明确JSON文本真正写盘并交给生产入口，失败必须有明确错误且不产生配置指纹。
func _load_fixture_source(source: String, label: String, accepted: bool, error_fragment: String = "") -> GameConfig:
	var path: String = fixture_root.path_join("case_%03d.json" % fixture_files.size())
	var output := FileAccess.open(path, FileAccess.WRITE)
	if not _check(output != null, "%s配置副本可写入" % label):
		return null
	fixture_files.append(path)
	output.store_string(source)
	var write_result: Error = output.get_error()
	output.close()
	if not _check(write_result == OK, "%s配置副本写入完整" % label):
		return null
	var loaded := CONFIG.new()
	var result: Error = loaded.load_file(path, SCHEMA_PATH)
	if accepted:
		if not _check(result == OK, "%s应加载成功：%s" % [label, loaded.error_message]):
			return null
		_check(loaded.error_message.is_empty(), "%s成功不遗留错误" % label)
		_check(not loaded.fingerprint.is_empty(), "%s成功建立真实指纹" % label)
	else:
		_check(result != OK, "%s必须明确拒绝" % label)
		_check(not loaded.error_message.is_empty(), "%s拒绝原因可见" % label)
		_check(loaded.fingerprint.is_empty(), "%s拒绝不产生成功指纹" % label)
		if not error_fragment.is_empty():
			_check(loaded.error_message.contains(error_fragment), "%s错误应指向%s，实际：%s" % [label, error_fragment, loaded.error_message])
	return loaded


## 只统计实际执行的断言，失败保留到最终退出码。
func _check(condition: bool, message: String) -> bool:
	checks += 1
	if not condition:
		failures.append(message)
	return condition


## 清理本次独占副本并输出唯一结果，不访问任何正式用户数据。
func _finish() -> void:
	for path: String in fixture_files:
		_check(DirAccess.remove_absolute(path) == OK, "删除本次配置副本")
	if not fixture_root.is_empty() and DirAccess.dir_exists_absolute(fixture_root):
		_check(DirAccess.remove_absolute(fixture_root) == OK, "删除本次独占缓存目录")
	if failures.is_empty():
		print("DAILY_REWARD_CONFIG_TEST_PASS checks=%s" % checks)
		quit(0)
	else:
		for message: String in failures:
			push_error(message)
		print("DAILY_REWARD_CONFIG_TEST_FAIL checks=%s failures=%s" % [checks, failures.size()])
		quit(1)
