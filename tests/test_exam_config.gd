extends SceneTree
## 用真实配置入口验证阶段5计分契约；副本只写独占缓存，不更改Excel、JSON或正式存档。

const CONFIG = preload("res://scripts/core/game_config.gd")
const CONFIG_PATH: String = "res://config/game_config.json"
const SCHEMA_PATH: String = "res://config/config_schema.json"

# 原始配置和本次文件清单用于复核权威源未改动，以及只清理自己创建的副本。
var baseline: Dictionary = {}
var fixture_root: String = ""
var fixture_files: Array[String] = []
var config_source: String = ""
var schema_source: String = ""
var checks: int = 0
var failures: Array[String] = []


## 等待场景树就绪后执行实际文件加载。
func _initialize() -> void:
	call_deferred("_run")


## 配置拒绝和接受场景必须经过生产加载器，并在结束时校验源文件未改变。
func _run() -> void:
	var configuration := CONFIG.new()
	if not _check(configuration.load_file() == OK, "正式计分参数应通过加载：" + configuration.error_message):
		_finish()
		return
	config_source = FileAccess.get_file_as_string(CONFIG_PATH)
	schema_source = FileAccess.get_file_as_string(SCHEMA_PATH)
	baseline = JSON.parse_string(config_source)
	fixture_root = OS.get_cache_dir().path_join("ClassroomExamConfig_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	if not _check(DirAccess.make_dir_recursive_absolute(fixture_root) == OK, "建立独占配置目录"):
		_finish()
		return
	_test_global_parameters()
	_test_subject_scores()
	_test_exam_mapping()
	_test_representation()
	_test_round_schedule()
	_check(FileAccess.get_file_as_string(CONFIG_PATH) == config_source, "权威JSON逐字保持不变")
	_check(FileAccess.get_file_as_string(SCHEMA_PATH) == schema_source, "字段契约逐字保持不变")
	_finish()


## 智力系数与小数位必须显式配置，不接受类型转换或默认数值。
func _test_global_parameters() -> void:
	for key: String in ["exam_intelligence_coefficient", "score_decimal_places"]:
		var missing: Dictionary = baseline.duplicate(true)
		missing.tables.globals.remove_at(_global_index(key))
		_load_fixture(missing, "缺失" + key, false, key)
		for invalid: Variant in [true, "1", null]:
			var changed: Dictionary = baseline.duplicate(true)
			changed.tables.globals[_global_index(key)].value = invalid
			_load_fixture(changed, "%s非法类型%s" % [key, invalid], false)
		var wrong_declaration: Dictionary = baseline.duplicate(true)
		wrong_declaration.tables.globals[_global_index(key)].type = "string"
		wrong_declaration.tables.globals[_global_index(key)].value = "1"
		_load_fixture(wrong_declaration, key + "错误声明", false, key)
	for invalid: Variant in [-1, -0.01]:
		var changed: Dictionary = baseline.duplicate(true)
		changed.tables.globals[_global_index("exam_intelligence_coefficient")].value = invalid
		_load_fixture(changed, "负智力系数%s" % invalid, false, "exam_intelligence_coefficient")
	for coefficient: float in [0.0, 0.03, 2.0, 1.0e300]:
		var changed: Dictionary = baseline.duplicate(true)
		changed.tables.globals[_global_index("exam_intelligence_coefficient")].value = coefficient
		_load_fixture(changed, "合法智力系数%s" % coefficient, true)
	for invalid: Variant in [-1, 0.5, 1.5]:
		var changed: Dictionary = baseline.duplicate(true)
		changed.tables.globals[_global_index("score_decimal_places")].value = invalid
		_load_fixture(changed, "非法小数位%s" % invalid, false, "score_decimal_places")
	for places: int in [0, 1, 2, 12]:
		var changed: Dictionary = baseline.duplicate(true)
		changed.tables.globals[_global_index("score_decimal_places")].value = places
		var loaded: GameConfig = _load_fixture(changed, "合法小数位%s" % places, true)
		if loaded != null:
			_check(loaded.global_value("score_decimal_places") == places, "小数位原样保留")


## 四个知识科目的曲线和满分均须有效，恢复课不要求不适用的分数字段。
func _test_subject_scores() -> void:
	for subject_id: String in ["chinese", "math", "english", "physical"]:
		for field: String in ["max_score", "score_scale"]:
			for invalid: Variant in [0, -1, true, "150", null]:
				var changed: Dictionary = baseline.duplicate(true)
				changed.tables.subjects[_subject_index(subject_id)][field] = invalid
				_load_fixture(changed, "%s.%s非法值%s" % [subject_id, field, invalid], false)
	var small: Dictionary = baseline.duplicate(true)
	small.tables.subjects[_subject_index("chinese")].max_score = 0.01
	small.tables.subjects[_subject_index("chinese")].score_scale = 0.000001
	_load_fixture(small, "正满分舍入为零仍是合法配表", true)
	var rounded: Dictionary = baseline.duplicate(true)
	rounded.tables.subjects[_subject_index("chinese")].max_score = 0.06
	_load_fixture(rounded, "舍入满分自然高于未舍入满分时不钳制", true)


## 考试只从真实知识科目取值，不把恢复课或另一场考试当知识来源。
func _test_exam_mapping() -> void:
	for exam_id: String in ["exam_chinese", "exam_math", "exam_english"]:
		for source: Variant in [null, "music", "art", "exam_chinese", "unknown_subject"]:
			var changed: Dictionary = baseline.duplicate(true)
			changed.tables.subjects[_subject_index(exam_id)].knowledge_subject_id = source
			_load_fixture(changed, "%s错误知识来源%s" % [exam_id, source], false)
		var changed: Dictionary = baseline.duplicate(true)
		changed.tables.subjects[_subject_index(exam_id)].knowledge_subject_id = "physical"
		_load_fixture(changed, exam_id + "不能替代体育的无课时结算或遗漏原科", false, "考试课程")
	var permuted: Dictionary = baseline.duplicate(true)
	permuted.tables.subjects[_subject_index("exam_chinese")].knowledge_subject_id = "math"
	permuted.tables.subjects[_subject_index("exam_math")].knowledge_subject_id = "english"
	permuted.tables.subjects[_subject_index("exam_english")].knowledge_subject_id = "chinese"
	_load_fixture(permuted, "三科完整置换保持每科唯一考试时可配置", true)


## 只拒绝真实数值表示溢出，不人为限定小数位、满分或曲线参数。
func _test_representation() -> void:
	for places: Variant in [20, 309, 1.0e30]:
		var changed: Dictionary = baseline.duplicate(true)
		changed.tables.globals[_global_index("score_decimal_places")].value = places
		_load_fixture(changed, "小数刻度超出表示%s" % places, false)
	var single_overflow: Dictionary = baseline.duplicate(true)
	single_overflow.tables.subjects[_subject_index("chinese")].max_score = 1.0e308
	_load_fixture(single_overflow, "单科满分缩放溢出", false, "表示范围")
	var total_overflow: Dictionary = baseline.duplicate(true)
	total_overflow.tables.globals[_global_index("score_decimal_places")].value = 0
	for subject: Dictionary in total_overflow.tables.subjects:
		if subject.kind == "knowledge":
			subject.max_score = 3.0e18
	_load_fixture(total_overflow, "每科可表示但相加溢出", false, "总分")
	var large: Dictionary = baseline.duplicate(true)
	large.tables.globals[_global_index("score_decimal_places")].value = 0
	large.tables.subjects[_subject_index("chinese")].max_score = 1.0e15
	large.tables.subjects[_subject_index("chinese")].score_scale = 1.0e300
	_load_fixture(large, "巨大但可表示的分数参数", true)
	# 小满分允许更多小数位；不把刻度因子本身错误地限制为int64。
	var many_places: Dictionary = baseline.duplicate(true)
	many_places.tables.globals[_global_index("score_decimal_places")].value = 19
	for subject: Dictionary in many_places.tables.subjects:
		if subject.kind == "knowledge":
			subject.max_score = 0.01
	_load_fixture(many_places, "小满分允许十九位小数", true)


## 真实课表必须能唯一定位日榜与考试，缺行、重复或重叠都不能由核心猜测补齐。
func _test_round_schedule() -> void:
	var missing_days: Dictionary = baseline.duplicate(true)
	missing_days.tables.globals.remove_at(_global_index("session_days"))
	_load_fixture(missing_days, "缺少本局天数", false, "session_days")
	for invalid: Variant in [0, -1, 1.5, true, "7"]:
		var changed: Dictionary = baseline.duplicate(true)
		changed.tables.globals[_global_index("session_days")].value = invalid
		_load_fixture(changed, "非法本局天数%s" % invalid, false)
	var missing_lesson: Dictionary = baseline.duplicate(true)
	missing_lesson.tables.schedule.remove_at(0)
	_load_fixture(missing_lesson, "缺少第一天真实课程", false, "缺少")
	var duplicate_lesson: Dictionary = baseline.duplicate(true)
	var duplicate: Dictionary = duplicate_lesson.tables.schedule[0].duplicate(true)
	duplicate.id = "duplicate_day1_period"
	duplicate_lesson.tables.schedule.append(duplicate)
	_load_fixture(duplicate_lesson, "同日时段重复不能发两份事件", false, "重复")
	var duplicate_slot: Dictionary = baseline.duplicate(true)
	duplicate_slot.tables.schedule[1].slot = duplicate_slot.tables.schedule[0].slot
	_load_fixture(duplicate_slot, "同日课时序号重复", false, "重复")
	var outside_round: Dictionary = baseline.duplicate(true)
	outside_round.tables.schedule[0].day = 8
	_load_fixture(outside_round, "课表不能越过本局日期", false, "局内日")
	var wrong_period: Dictionary = baseline.duplicate(true)
	wrong_period.tables.schedule[0].period_id = "break_1"
	_load_fixture(wrong_period, "课程不能排入普通课间", false, "上课时段")
	var overlapping: Dictionary = baseline.duplicate(true)
	overlapping.tables.periods[1].start_time = overlapping.tables.periods[0].start_time
	_load_fixture(overlapping, "时段重叠使边界歧义", false, "重叠")
	var missing_exam: Dictionary = baseline.duplicate(true)
	for row: Dictionary in missing_exam.tables.schedule:
		if row.subject_id == "exam_chinese":
			row.subject_id = "chinese"
	_load_fixture(missing_exam, "最后一天缺少语文考试", false, "缺少")
	var early_exam: Dictionary = baseline.duplicate(true)
	early_exam.tables.schedule[0].subject_id = "exam_chinese"
	_load_fixture(early_exam, "首日提前安排末日考试", false, "最后一天")


## 参数位置从真实源配置定位，找不到时保留可见失败。
func _global_index(key: String) -> int:
	for index in baseline.tables.globals.size():
		if baseline.tables.globals[index].key == key:
			return index
	_check(false, "源配置缺少参数" + key)
	return -1


## 科目位置从真实源配置定位，不用测试默认科目替代。
func _subject_index(subject_id: String) -> int:
	for index in baseline.tables.subjects.size():
		if baseline.tables.subjects[index].id == subject_id:
			return index
	_check(false, "源配置缺少科目" + subject_id)
	return -1


## 配置副本真实落盘并调用生产加载器，失败不能产生成功指纹。
func _load_fixture(data: Dictionary, label: String, accepted: bool, fragment: String = "") -> GameConfig:
	var path: String = fixture_root.path_join("case_%03d.json" % fixture_files.size())
	var output := FileAccess.open(path, FileAccess.WRITE)
	if not _check(output != null, label + "副本可写"):
		return null
	fixture_files.append(path)
	output.store_string(JSON.stringify(data, "", true, true))
	var write_error: Error = output.get_error()
	output.close()
	if not _check(write_error == OK, label + "完整落盘"):
		return null
	var loaded := CONFIG.new()
	var result: Error = loaded.load_file(path, SCHEMA_PATH)
	if accepted:
		if not _check(result == OK, label + "应通过：" + loaded.error_message):
			return null
		_check(loaded.error_message.is_empty(), label + "成功无错误")
	else:
		_check(result != OK, label + "必须拒绝")
		_check(not loaded.error_message.is_empty(), label + "原因可见")
		_check(loaded.fingerprint.is_empty(), label + "拒绝不产生指纹")
		if not fragment.is_empty():
			_check(loaded.error_message.contains(fragment), label + "错误定位：" + loaded.error_message)
	return loaded


## 只统计实际执行的检查，失败留到最终退出码。
func _check(condition: bool, message: String) -> bool:
	checks += 1
	if not condition:
		failures.append(message)
	return condition


## 清理范围仅含本次缓存副本，不访问正式用户目录。
func _finish() -> void:
	for path: String in fixture_files:
		_check(DirAccess.remove_absolute(path) == OK, "清理本次配置副本")
	if not fixture_root.is_empty():
		_check(DirAccess.remove_absolute(fixture_root) == OK, "清理独占配置目录")
	if failures.is_empty():
		print("EXAM_CONFIG_TEST_PASS checks=%s" % checks)
		quit(0)
	else:
		for message: String in failures:
			push_error(message)
		print("EXAM_CONFIG_TEST_FAIL checks=%s failures=%s" % [checks, failures.size()])
		quit(1)
