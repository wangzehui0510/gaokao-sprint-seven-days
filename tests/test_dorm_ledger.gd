extends SceneTree
## 宿舍来源使用真实活动积分；迁移和坏档仅操作独占缓存，不修改正式用户进度。

# 所有临时配置与存档均归当前进程独占，失败时保留证据供定位。
var fixture_root: String = ""
var fixture_files: Array[String] = []
var configuration: GameConfig
var controllers: Array[ClassroomBehaviorController] = []
var checks: int = 0
var failures: Array[String] = []


## 等待场景树就绪后开始生产规则验证。
func _initialize() -> void:
	call_deferred("_run")


## 每项场景真实执行并检查返回值，脚本异常不能绕过完整结束标记。
func _run() -> void:
	configuration = GameConfig.new()
	if not _result(configuration.load_file(), "正式配置加载", configuration.error_message):
		_finish()
		return
	fixture_root = OS.get_cache_dir().path_join("ClassroomDormLedger_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	if not _result(DirAccess.make_dir_recursive_absolute(fixture_root), "建立独占宿舍账本目录"):
		_finish()
		return
	_check(_test_real_sources(), "真实宿舍增量与在校日榜分流场景完整执行")
	_check(_test_roundtrip_and_offline(), "宿舍明细往返与离线冻结场景完整执行")
	_check(_test_legacy_migration(), "原版v4来源口径与缺失宿舍历史迁移完整执行")
	_check(_test_config_history(), "真实宿舍历史拒绝来源变更但允许倍率费率热改")
	_check(_test_corruption(), "损坏宿舍明细原子拒绝场景完整执行")
	_finish()


## 建立尚未自主决策的四人局，避免读档前多消耗一份随机流。
func _empty() -> ClassroomSimulation:
	var simulation := ClassroomSimulation.new()
	if not _result(simulation.setup(configuration, 261109), "创建真实四人局", simulation.error_message):
		return null
	var controller := ClassroomBehaviorController.new()
	root.add_child(controller)
	controller.setup(simulation)
	simulation.decision_handler = controller.decide
	controllers.append(controller)
	return simulation


## 首次定位沿用开发时钟语义，知识、资源和结果均由之后的真实推进产生。
func _at(at_day: int, seconds: float) -> ClassroomSimulation:
	var simulation := _empty()
	if simulation == null:
		return null
	if not _result(simulation.set_debug_time(at_day, seconds), "定位隔离开发时钟", simulation.error_message):
		return null
	if not _result(simulation.advance(0.0), "真实行为树开始当前时段", simulation.error_message):
		return null
	return simulation


## 三类产知识宿舍活动只记选定科目，知识由执行器增加一次且不进入在校日榜。
func _test_real_sources() -> bool:
	var simulation := _at(1, 45000.0)
	if simulation == null:
		return false
	var cases: Array[Dictionary] = [
		{"action": "dorm_study", "subject": "math"},
		{"action": "dorm_practice", "subject": "english"},
		{"action": "dorm_workout", "subject": "physical"},
	]
	for entry: Dictionary in cases:
		var total_before: float = simulation.students[0].knowledge[entry.subject]
		var daily_before: float = simulation.round_progression.data.daily_days["1"].gains.student_0[entry.subject]
		var dorm_before: float = simulation.round_progression.dorm_summary(1, "student_0").totals[entry.subject]
		var selected: String = "" if entry.action == "dorm_workout" else entry.subject
		if not _result(simulation.start_action(0, entry.action, false, -1, "宿舍账本真实验证", selected), "开始真实宿舍活动：" + entry.action, simulation.error_message):
			return false
		if not _result(simulation.advance(60.0), "真实执行宿舍活动一分钟", simulation.error_message):
			return false
		var gained: float = simulation.students[0].knowledge[entry.subject] - total_before
		var summary: Dictionary = simulation.round_progression.dorm_summary(1, "student_0")
		_check(gained > 0.0, "宿舍实际得到知识：" + entry.action)
		_close(summary.totals[entry.subject] - dorm_before, gained, "宿舍明细只记录实际到账一次：" + entry.action)
		_close(simulation.round_progression.data.daily_days["1"].gains.student_0[entry.subject], daily_before, "宿舍增量不进入午休当日在校榜")
		_check(summary.status == "partial" and summary.start_seconds == 45000.0, "首次定位真实记录起点且不声称此前全天完整")
		_check(_has_row(summary.rows, entry.action, entry.subject, gained), "真实来源含动作和所选科目")
	var authority: Dictionary = simulation.round_progression.data.duplicate(true)
	var rng_before: String = str(simulation.rng.state)
	var future: Dictionary = simulation.round_progression.dorm_summary(2, "student_0")
	_check(future.status == "unrecorded" and not future.reason.is_empty() and future.rows.is_empty(), "未来日期不能被查询成已经记录的零收益")
	var queried: Dictionary = simulation.round_progression.dorm_summary(1, "student_0")
	queried.totals.math += 1000.0
	queried.rows.clear()
	_check(simulation.round_progression.data == authority and str(simulation.rng.state) == rng_before, "修改查询副本不改变权威账本与随机流")
	if not _result(simulation.advance(60000.0 - simulation.clock_seconds), "真实经过下午课程至16:40出榜", simulation.error_message):
		return false
	var published: Dictionary = simulation.get_daily_board(1, "math")
	_check(published.status == "published" and published.knowledge_scope == "school", "16:40公布明确在校口径的榜单")
	var dorm_before: float = simulation.round_progression.dorm_summary(1, "student_0").totals.math
	if not _result(simulation.start_action(0, "dorm_study", false, -1, "出榜后真实自习", "math"), "晚间继续数学自习", simulation.error_message):
		return false
	if not _result(simulation.advance(60.0), "出榜后真实自习一分钟", simulation.error_message):
		return false
	_check(simulation.round_progression.dorm_summary(1, "student_0").totals.math > dorm_before, "出榜后宿舍收益继续进入当天独立明细")
	_check(simulation.get_daily_board(1, "math") == published, "晚间宿舍活动不改写已发布在校榜")
	return true


## 生产保存恢复明细与选科，真正退出不补宿舍知识、资源或在线时长。
func _test_roundtrip_and_offline() -> bool:
	var source := _at(1, 61200.0)
	if source == null:
		return false
	if not _result(source.start_action(0, "dorm_study", false, -1, "真实宿舍存档", "chinese"), "开始在途语文自习", source.error_message) or not _result(source.advance(120.0), "在途执行两分钟", source.error_message):
		return false
	var saved: Dictionary = _save(source, "dorm_active.json")
	if saved.is_empty():
		return false
	_check(saved.save_version == 5 and saved.round_progression.schema_version == 2, "顶层v5与内部新来源契约均明确保存")
	var before: Dictionary = source.round_progression.dorm_summary(1, "student_0")
	var restored := _empty()
	if restored == null or not _result(restored.load_file(_path("dorm_active.json"), false), "生产原时刻恢复真实宿舍局", restored.error_message):
		return false
	_check(_same(restored.round_progression.dorm_summary(1, "student_0"), before), "宿舍动作科目收益与接入起点完整往返")
	_check(restored.students[0].current_action.subject_id == "chinese", "在途恢复保留玩家实际选科")
	_check(str(restored.rng.state) == str(source.rng.state), "读取在途活动不重新抽随机数")
	var knowledge: Dictionary = source.students[0].knowledge.duplicate()
	var offline := _empty()
	if offline == null or not _result(offline.load_file_at_time(_path("dorm_active.json"), 1, 72000.0), "同课外时段恢复至20:00", offline.error_message):
		return false
	_check(_same(offline.students[0].knowledge, knowledge) and _same(offline.round_progression.dorm_summary(1, "student_0"), before), "退出近三小时不补宿舍收益")
	_close(offline.elapsed_s, source.elapsed_s, "真正退出不增加在线执行时长")
	return true


## 原版账本先通过原验证再迁移，已公布历史数值原样保留且不猜测拆分。
func _test_legacy_migration() -> bool:
	var source := _at(1, 57300.0)
	if source == null or not _result(source.advance(2700.0), "真实最后一节课执行至出榜", source.error_message):
		return false
	var saved: Dictionary = _save(source, "legacy_source.json")
	if saved.is_empty():
		return false
	var original: Dictionary = source.get_daily_board(1, "math")
	saved.round_progression.schema_version = 1
	saved.round_progression.erase("dorm_days")
	saved.round_progression.erase("dorm_tracking_start")
	for daily: Dictionary in saved.round_progression.daily_days.values():
		daily.erase("knowledge_scope")
	if not _write("legacy_v4.json", saved):
		return false
	var restored := _empty()
	if restored == null or not _result(restored.load_file(_path("legacy_v4.json"), false), "读取原版v4真实历史结构", restored.error_message):
		return false
	var after: Dictionary = restored.get_daily_board(1, "math")
	_check(after.knowledge_scope == "legacy_mixed", "旧已发布日榜保留原统计口径标识")
	after.erase("knowledge_scope")
	original.erase("knowledge_scope")
	_check(_same(after, original), "旧榜单增量、排名、参数与来源原样保留")
	_check(restored.get_daily_board(2, "math").knowledge_scope == "school", "旧档未来空白日期采用新在校口径")
	var partial: Dictionary = restored.round_progression.dorm_summary(1, "student_0")
	_check(partial.status == "partial" and partial.start_seconds == 60000.0 and not partial.reason.is_empty() and partial.rows.is_empty(), "迁移日宿舍收益从接入时记录，不猜旧收益")
	var resaved: Dictionary = _save(restored, "migrated_v4.json")
	if resaved.is_empty():
		return false
	var reloaded := _empty()
	if reloaded == null or not _result(reloaded.load_file(_path("migrated_v4.json"), false), "迁移后schema2可再度真实读取", reloaded.error_message):
		return false
	_check(_same(reloaded.round_progression.dorm_summary(1, "student_0"), partial), "重复恢复不改变历史接入起点")
	return true


## 历史来源的配置契约需要保留，已经结束的活动也不能因热改而变成无法读取的存档。
func _test_config_history() -> bool:
	var simulation := _at(1, 61200.0)
	if simulation == null:
		return false
	if not _result(simulation.start_action(0, "dorm_study", false, -1, "历史热改真实自习", "math"), "建立真实数学自习", simulation.error_message) or not _result(simulation.advance(60.0), "真实数学自习一分钟", simulation.error_message):
		return false
	if not _result(simulation.start_action(0, "dorm_workout", false), "建立真实健身来源", simulation.error_message) or not _result(simulation.advance(60.0), "真实健身一分钟", simulation.error_message):
		return false
	if not _result(simulation.start_action(0, "dorm_rest", false), "结束学习实例后保留真实历史", simulation.error_message):
		return false
	var ledger: Dictionary = simulation.round_progression.data.duplicate(true)
	var original_config: RefCounted = simulation.round_progression.configuration
	var variants: Array[Dictionary] = [
		{"dorm_study": {"knowledge_source": "school", "knowledge_mode": "course"}},
		{"dorm_study": {"knowledge_mode": "fixed_subject", "knowledge_subject_id": "math"}},
		{"dorm_workout": {"knowledge_subject_id": "english"}},
	]
	for index in variants.size():
		var changed := _config_variant("history_incompatible_%d.json" % index, variants[index])
		if changed == null:
			return false
		var outcome: Error = simulation.round_progression.apply_config(changed, simulation._round_participants())
		_check(outcome != OK and not simulation.round_progression.error_message.is_empty(), "已有宿舍来源的知识语义热改明确拒绝：%d" % index)
		_check(simulation.round_progression.data == ledger and simulation.round_progression.configuration == original_config, "拒绝来源热改不部分修改账本或配置引用：%d" % index)
	var allowed := _config_variant("history_rates_allowed.json", {"dorm_study": {"knowledge_multiplier": 0.25}}, true)
	if allowed == null or not _result(simulation.apply_config(allowed), "相同来源身份允许倍率和资源费率热改", simulation.error_message):
		return false
	_check(simulation.round_progression.data == ledger, "合法费率热改不重算既有知识来源")
	if not _result(simulation.start_action(0, "dorm_study", false, -1, "新费率真实自习", "math"), "使用新费率启动自习", simulation.error_message):
		return false
	var focus_before: float = simulation.students[0].focus
	var math_before: float = simulation.students[0].knowledge.math
	if not _result(simulation.advance(60.0), "真实按新费率执行一分钟", simulation.error_message):
		return false
	_close(simulation.students[0].focus - focus_before, -1.2, "持续专注费率热改立即生效")
	_close(simulation.students[0].knowledge.math - math_before, allowed.subjects.math.base_rate_per_min * 0.25, "知识倍率热改立即生效且不回写历史")
	var saved: Dictionary = _save(simulation, "history_allowed_save.json")
	if saved.is_empty():
		return false
	var restored := ClassroomSimulation.new()
	if not _result(restored.setup(allowed, 261109), "建立新配置读档目标", restored.error_message) or not _result(restored.load_file(_path("history_allowed_save.json"), false), "合法热改后的真实来源仍能保存重读", restored.error_message):
		return false
	_check(_same(restored.round_progression.dorm_summary(1, "student_0"), simulation.round_progression.dorm_summary(1, "student_0")), "费率热改后的来源明细原样往返")
	return true


## 缺字段、错误选科、重复来源与超额收益在覆盖有效局之前拒绝，不静默迁移为旧档。
func _test_corruption() -> bool:
	var source := _at(1, 61200.0)
	if source == null or not _result(source.start_action(0, "dorm_study", false, -1, "真实坏档来源", "math"), "开始用于保存的真实自习", source.error_message) or not _result(source.advance(60.0), "获得真实数学收益", source.error_message):
		return false
	var saved: Dictionary = _save(source, "corrupt_source.json")
	if saved.is_empty():
		return false
	var cases: Array[Dictionary] = []
	var changed: Dictionary = saved.duplicate(true)
	changed.round_progression.erase("dorm_days")
	cases.append(changed)
	changed = saved.duplicate(true)
	changed.round_progression.erase("dorm_tracking_start")
	cases.append(changed)
	changed = saved.duplicate(true)
	changed.round_progression.daily_days["1"].erase("knowledge_scope")
	cases.append(changed)
	changed = saved.duplicate(true)
	changed.round_progression.dorm_days.erase("2")
	cases.append(changed)
	changed = saved.duplicate(true)
	changed.round_progression.schema_version = 1
	cases.append(changed)
	var row_index: int = -1
	for index in saved.round_progression.dorm_days["1"].rows.size():
		if saved.round_progression.dorm_days["1"].rows[index].student_id == "student_0":
			row_index = index
	if not _check(row_index >= 0, "坏档变体仅修改真实存在的本人收益行"):
		return false
	changed = saved.duplicate(true)
	changed.round_progression.dorm_days["1"].rows.append(changed.round_progression.dorm_days["1"].rows[row_index].duplicate())
	cases.append(changed)
	changed = saved.duplicate(true)
	changed.round_progression.dorm_days["1"].rows[row_index].subject_id = "physical"
	cases.append(changed)
	changed = saved.duplicate(true)
	changed.round_progression.dorm_days["1"].rows[row_index].knowledge = source.students[0].knowledge.math + 1.0
	cases.append(changed)
	changed = saved.duplicate(true)
	changed.round_progression.dorm_days["1"].rows[row_index].knowledge = -1.0
	cases.append(changed)
	changed = saved.duplicate(true)
	changed.round_progression.dorm_days["1"].rows[row_index].action_id = "study"
	cases.append(changed)
	changed = saved.duplicate(true)
	changed.round_progression.dorm_days["2"].rows = changed.round_progression.dorm_days["1"].rows.duplicate(true)
	cases.append(changed)
	changed = saved.duplicate(true)
	changed.round_progression.dorm_tracking_start.day = 9999
	cases.append(changed)
	changed = saved.duplicate(true)
	changed.round_progression.dorm_days["1"].rows[row_index].knowledge = null
	cases.append(changed)
	changed = saved.duplicate(true)
	# 其余时间证据同步改成上课，单独验证宿舍在途状态不能在不允许的时段恢复。
	changed.clock_seconds = 28860.0
	changed.context_key = source._context_at(1, 28860.0).context_key
	changed.round_progression.last_position.clock_seconds = 28860.0
	changed.round_progression.recorded_through.clock_seconds = 28860.0
	changed.round_progression.frozen.clock_seconds = 28860.0
	changed.round_progression.dorm_tracking_start.clock_seconds = 28800.0
	cases.append(changed)
	var target := _at(1, 28800.0)
	if target == null:
		return false
	var protected_students: Array = target.students.duplicate(true)
	var protected_ledger: Dictionary = target.round_progression.data.duplicate(true)
	var protected_rng: String = str(target.rng.state)
	for index in cases.size():
		if not _write("corrupt_case.json", cases[index]):
			return false
		_check(target.load_file(_path("corrupt_case.json"), false) != OK and not target.error_message.is_empty(), "损坏来源明确拒绝：%d" % index)
		_check(target.students == protected_students and target.round_progression.data == protected_ledger and str(target.rng.state) == protected_rng, "拒绝坏档不覆盖有效人物、账本和随机流：%d" % index)
	return true


## 只改缓存中的明确字段；每个变体都必须通过真实配置读取，拒绝问题由被测账本负责暴露。
func _config_variant(filename: String, action_changes: Dictionary, double_study_rates: bool = false) -> GameConfig:
	var source: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://config/game_config.json"))
	for action: Dictionary in source.tables.actions:
		if action_changes.has(action.id):
			action.merge(action_changes[action.id], true)
	if double_study_rates:
		for effect: Dictionary in source.tables.effects:
			if effect.action_id == "dorm_study" and effect.phase == "tick" and effect.type == "resource":
				effect.value *= 2.0
	if not _write(filename, source):
		return null
	var loaded := GameConfig.new()
	if not _result(loaded.load_file(_path(filename)), "历史热改配置副本合法", loaded.error_message):
		return null
	return loaded


## 按动作及科目查找真实来源行，不依赖AI其他角色的明细顺序。
func _has_row(rows: Array, action_id: String, subject_id: String, amount: float) -> bool:
	for row: Dictionary in rows:
		if row.action_id == action_id and row.subject_id == subject_id:
			return absf(row.knowledge - amount) < 0.000001
	return false


## 保存只调用生产入口，冻结来源随保存正常更新。
func _save(simulation: ClassroomSimulation, filename: String) -> Dictionary:
	var path: String = _path(filename)
	if path not in fixture_files:
		fixture_files.append(path)
		fixture_files.append(path + ".tmp")
	if not _result(simulation.save_file(path), "保存独占真实宿舍局", simulation.error_message):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not _check(parsed is Dictionary, "生产保存内容可解析"):
		return {}
	return parsed


## 迁移与坏档夹具显式写入缓存，写入失败停止依赖场景。
func _write(filename: String, data: Dictionary) -> bool:
	var path: String = _path(filename)
	if path not in fixture_files:
		fixture_files.append(path)
	var output := FileAccess.open(path, FileAccess.WRITE)
	if not _check(output != null, "独占夹具可写"):
		return false
	output.store_string(JSON.stringify(data, "", true, true))
	var result: Error = output.get_error()
	output.close()
	return _result(result, "独占夹具完整写入")


## 测试路径始终限定在本进程创建的缓存目录。
func _path(filename: String) -> String:
	return fixture_root.path_join(filename)


## JSON普通数字仅允许机器表示误差，角色ID和容器结构保持精确比较。
func _same(left: Variant, right: Variant) -> bool:
	if left is Dictionary and right is Dictionary:
		if left.size() != right.size():
			return false
		for key: Variant in left:
			if not right.has(key) or not _same(left[key], right[key]):
				return false
		return true
	if left is Array and right is Array:
		if left.size() != right.size():
			return false
		for index in left.size():
			if not _same(left[index], right[index]):
				return false
		return true
	if (left is int or left is float) and (right is int or right is float):
		return absf(float(left) - float(right)) <= maxf(1.0, maxf(absf(left), absf(right))) * 0.000000000001
	return typeof(left) == typeof(right) and left == right


## 每次断言均计数，失败保留原始原因。
func _check(condition: bool, message: String) -> bool:
	checks += 1
	if not condition:
		failures.append(message)
	return condition


## 业务入口错误包含原始错误码与执行器原因。
func _result(result: Error, message: String, detail: String = "") -> bool:
	return _check(result == OK, "%s：%s %s" % [message, result, detail])


## 数值比较只容许普通积分误差，不修改被测知识。
func _close(actual: float, expected: float, message: String) -> void:
	_check(absf(actual - expected) < 0.000001, "%s：实际%s，预期%s" % [message, actual, expected])


## 释放真实行为树；成功仅清理登记文件，失败保留独占目录与非零退出码。
func _finish() -> void:
	for controller in controllers:
		controller.free()
	if failures.is_empty():
		for path: String in fixture_files:
			if FileAccess.file_exists(path):
				_result(DirAccess.remove_absolute(path), "清理当前验证文件")
		if not fixture_root.is_empty():
			_result(DirAccess.remove_absolute(fixture_root), "清理当前验证目录")
	if failures.is_empty():
		print("DORM_LEDGER_TEST_PASS checks=%d" % checks)
		quit(0)
	else:
		for message: String in failures:
			push_error(message)
		print("DORM_LEDGER_TEST_FAIL checks=%d failures=%d fixtures=%s" % [checks, failures.size(), fixture_root])
		quit(1)
