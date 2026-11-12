extends SceneTree
## 课间磨蹭：课间开始按专注阈值与概率触发，四地点等权抽取现有动作，课间结束强制回课表。

# 临时存档全部写入本进程独占目录，失败时保留证据。
var fixture_root: String = ""
var configuration: GameConfig
var controllers: Array[ClassroomBehaviorController] = []
var checks: int = 0
var failures: Array[String] = []


## 等待场景树就绪后开始真实规则验证。
func _initialize() -> void:
	call_deferred("_run")


## 逐场景真实执行并检查返回值，脚本异常不能绕过结束标记。
func _run() -> void:
	configuration = GameConfig.new()
	if not _result(configuration.load_file(), "正式配置加载", configuration.error_message):
		_finish()
		return
	fixture_root = OS.get_cache_dir().path_join("LingerBreak_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	if not _result(DirAccess.make_dir_recursive_absolute(fixture_root), "建立独占磨蹭测试目录"):
		_finish()
		return
	# 本组验证磨蹭自身规则，不含每日发点；把起始日推到局外隔离每日属性点影响。
	configuration.globals["first_daily_attribute_day"] = 99
	if _empty() == null:
		_finish()
		return
	_check(_test_config_contract(), "磨蹭配置与动作契约完整")
	_check(_test_trigger_threshold_and_chance(), "专注阈值与概率边界场景完整执行")
	_check(_test_place_mapping_and_settlement(), "四地点抽取与结算场景完整执行")
	_check(_test_break_end_interrupt(), "课间结束强制回课表场景完整执行")
	_check(_test_once_per_break(), "同一课间只判定一次场景完整执行")
	_check(_test_roundtrip_and_legacy(), "存档往返与旧档拒绝场景完整执行")
	_check(_test_step_consistency(), "大步与小步推进一致性场景完整执行")
	_finish()


## 建立尚未自主决策的四人局；default_seed用于复现固定随机流。
func _empty(default_seed: int = 261109) -> ClassroomSimulation:
	var simulation := ClassroomSimulation.new()
	if not _result(simulation.setup(configuration, default_seed), "创建真实四人局", simulation.error_message):
		return null
	var controller := ClassroomBehaviorController.new()
	root.add_child(controller)
	controller.setup(simulation)
	simulation.decision_handler = controller.decide
	controllers.append(controller)
	return simulation


## 首次定位沿用开发时钟语义；断言以最终时刻的权威状态为准。
func _at(at_day: int, seconds: float) -> ClassroomSimulation:
	var simulation := _empty()
	if simulation == null:
		return null
	if not _result(simulation.set_debug_time(at_day, seconds), "定位隔离开发时钟", simulation.error_message):
		return null
	if not _result(simulation.advance(0.0), "真实行为树开始当前时段", simulation.error_message):
		return null
	return simulation


## 第一天真实课表中第 index 个课间时段（0起）。
func _break_period(index: int) -> Dictionary:
	var breaks: Array[Dictionary] = []
	for period: Dictionary in configuration.periods:
		if String(period.kind) == "break":
			breaks.append(period)
	if index < 0 or index >= breaks.size():
		return {}
	return breaks[index]


## 定位到课间开始前60秒的真实课内，返回已就位的模拟器；角色专注在返回后由用例设置。
func _before_break(break_index: int) -> ClassroomSimulation:
	var period: Dictionary = _break_period(break_index)
	if period.is_empty():
		_check(false, "课表存在课间时段")
		return null
	var entry_seconds: float = float(period.start_time) * 86400.0 - 1.0
	var simulation := _at(1, entry_seconds)
	if simulation == null:
		return null
	var context: Dictionary = simulation.course_context()
	if not _check(context.kind == "lesson", "课间前1秒处于上一节课内"):
		return null
	return simulation


## 从课间前的日志里筛选磨蹭触发日志。
func _linger_logs(simulation: ClassroomSimulation) -> Array:
	return simulation.logs.filter(func(entry: Dictionary): return entry.type == "linger_break")


## 配置契约：宿舍磨蹭动作、参数、效果表与玩家入口不开放。
func _test_config_contract() -> bool:
	var action: Dictionary = configuration.actions.get("linger_dorm_rest", {})
	if not _check(not action.is_empty(), "权威配置存在宿舍磨蹭动作"):
		return false
	_check(String(action.scene) == "dorm" and String(action.eligible_period) == "break", "宿舍磨蹭只在课间且真实位于宿舍")
	_check(String(action.source) == "auto", "宿舍磨蹭保持auto来源，玩家入口不开放")
	_check(String(config_actions_source("linger_break")) == "auto", "课间磨蹭本体保持auto来源，玩家入口不开放")
	# 效果表与dorm_rest逐字段一致：复用宿舍休息的恢复数值。
	var dorm_effects: Array = configuration.phase_effects("dorm_rest", "tick")
	var linger_effects: Array = configuration.phase_effects("linger_dorm_rest", "tick")
	_check(dorm_effects.size() == 2 and linger_effects.size() == 2, "宿舍磨蹭持续效果与宿舍休息同为两条")
	for field: String in ["resource", "mode", "value", "period_s", "max_basis", "condition", "sequence"]:
		var same: bool = true
		for i in mini(dorm_effects.size(), linger_effects.size()):
			if dorm_effects[i].get(field) != linger_effects[i].get(field):
				same = false
		_check(same, "宿舍磨蹭持续效果%s与宿舍休息一致" % field)
	_check(is_equal_approx(float(configuration.global_value("linger_break_focus_threshold")), 0.35), "磨蹭专注阈值默认0.35")
	_check(is_equal_approx(float(configuration.global_value("linger_break_chance")), 0.35), "磨蹭触发概率默认0.35")
	return true


## 读取动作表的发起来源，缺动作返回空串。
func config_actions_source(action_id: String) -> String:
	var action: Dictionary = configuration.actions.get(action_id, {})
	return String(action.get("source", ""))


## 阈值与概率边界：专注达标不触发、概率为零不触发、概率为一且专注低必触发。
func _test_trigger_threshold_and_chance() -> bool:
	var ok: bool = true
	# 概率为1且专注低于阈值：必触发。
	configuration.globals["linger_break_chance"] = 1.0
	var simulation := _before_break(0)
	if simulation == null:
		return false
	for student: Dictionary in simulation.students:
		student.focus = 20.0
	if not _result(simulation.advance(2.0), "推进跨过课间开始", simulation.error_message):
		return false
	var logs: Array = _linger_logs(simulation)
	ok = _check(logs.size() == 4, "概率为一时四人全部触发磨蹭") and ok
	for entry: Dictionary in logs:
		ok = _check(String(entry.message).begins_with("课间去"), "磨蹭日志记录课间去向") and ok
	var non_default := 0
	for index in simulation.students.size():
		var action_id: String = String(simulation.students[index].current_action.action_id)
		if action_id in ["linger_break", "playground_play", "eat_meal", "linger_dorm_rest"]:
			non_default += 1
	ok = _check(non_default == 4, "触发角色真实处于磨蹭动作") and ok

	# 专注高于阈值：概率为1也不触发。
	simulation = _before_break(0)
	if simulation == null:
		return false
	for student: Dictionary in simulation.students:
		student.focus = 90.0
	if not _result(simulation.advance(2.0), "高专注推进跨过课间开始", simulation.error_message):
		return false
	ok = _check(_linger_logs(simulation).is_empty(), "专注高于阈值不触发磨蹭") and ok
	for index in simulation.students.size():
		ok = _check(String(simulation.students[index].current_action.action_id) == "break_rest", "未触发角色保持课间休息") and ok

	# 阈值边界：略高于阈值乘上限不触发，略低于则触发；保留1点余量避免课内秒级消耗影响判定。
	simulation = _before_break(0)
	if simulation == null:
		return false
	var max_focus: float = simulation.get_resource_max(0, "focus")
	var max_focus_1: float = simulation.get_resource_max(1, "focus")
	simulation.students[0].focus = max_focus * 0.35 + 1.0
	simulation.students[1].focus = max_focus_1 * 0.35 - 1.0
	for i in range(2, simulation.students.size()):
		simulation.students[i].focus = simulation.get_resource_max(i, "focus")
	if not _result(simulation.advance(2.0), "阈值边界推进跨过课间开始", simulation.error_message):
		return false
	var boundary_logs: Array = _linger_logs(simulation).filter(func(entry: Dictionary): return int(entry.student_index) == 0)
	ok = _check(boundary_logs.is_empty(), "专注略高于阈值不触发磨蹭") and ok
	var below_logs: Array = _linger_logs(simulation).filter(func(entry: Dictionary): return int(entry.student_index) == 1)
	ok = _check(below_logs.size() == 1, "专注略低于阈值正常触发") and ok
	ok = _check(_linger_logs(simulation).size() == 1, "高于阈值的其余三人不触发") and ok

	# 概率为零：专注再低也不触发，随机流仍推进但不发起。
	configuration.globals["linger_break_chance"] = 0.0
	simulation = _before_break(0)
	if simulation == null:
		return false
	for student: Dictionary in simulation.students:
		student.focus = 1.0
	if not _result(simulation.advance(2.0), "概率为零推进跨过课间开始", simulation.error_message):
		return false
	ok = _check(_linger_logs(simulation).is_empty(), "概率为零不触发磨蹭") and ok
	configuration.globals["linger_break_chance"] = 1.0
	return ok


## 四地点等权抽取：多课间多种子下四个地点都会出现；宿舍磨蹭按宿舍休息数值恢复。
func _test_place_mapping_and_settlement() -> bool:
	var ok: bool = true
	var seen: Dictionary = {"教室": false, "操场": false, "食堂": false, "宿舍": false}
	var dorm_seed: int = -1
	configuration.globals["linger_break_chance"] = 1.0
	# 每个种子使用独立随机流：同一课间开始四人必触发，40个种子足以覆盖四地点。
	for seed_value in range(1, 41):
		var simulation := _empty(seed_value)
		if simulation == null:
			return false
		if not _result(simulation.set_debug_time(1, 31500.0), "定位第一课间开始时刻", simulation.error_message):
			return false
		if not _result(simulation.advance(0.0), "就位课间开始", simulation.error_message):
			return false
		for student: Dictionary in simulation.students:
			student.focus = 20.0
		if not _result(simulation.advance(2.0), "推进跨过课间开始", simulation.error_message):
			return false
		for entry: Dictionary in _linger_logs(simulation):
			var place: String = String(entry.message).substr("课间去".length(), 2)
			if seen.has(place):
				seen[place] = true
			if place == "宿舍" and dorm_seed < 0:
				dorm_seed = seed_value
	if not _check(seen["教室"] and seen["操场"] and seen["食堂"] and seen["宿舍"], "多课间多种子下四地点全部出现：%s" % str(seen)):
		return false
	# 宿舍磨蹭数值：10分钟恢复与dorm_rest一致（每分钟+4%体力+1%专注，按当前上限）。
	var settlement := _empty(dorm_seed)
	if settlement == null:
		return false
	if not _result(settlement.set_debug_time(1, 31500.0), "定位宿舍磨蹭课间", settlement.error_message):
		return false
	if not _result(settlement.advance(0.0), "就位课间开始", settlement.error_message):
		return false
	for student: Dictionary in settlement.students:
		student.focus = 20.0
		student.stamina = 50.0
	# 推进到课间结束同刻：600秒宿舍磨蹭正好占满课间并完成10次分钟结算，下一节课尚未结算。
	if not _result(settlement.advance(600.0), "推进完整课间到下一节课开始", settlement.error_message):
		return false
	var dorm_logs: Array = _linger_logs(settlement).filter(func(entry: Dictionary): return String(entry.message) == "课间去宿舍磨蹭")
	ok = _check(not dorm_logs.is_empty(), "该种子命中宿舍磨蹭") and ok
	if dorm_logs.is_empty():
		return false
	var starter: Dictionary = dorm_logs[0]
	var index: int = int(starter.student_index)
	# 宿舍磨蹭按宿舍休息数值每分钟恢复：10分钟共+10%专注上限、+40%体力上限。
	var focus_gain: float = float(settlement.students[index].focus) - 20.0
	var stamina_gain: float = float(settlement.students[index].stamina) - 50.0
	ok = _check(absf(focus_gain - settlement.get_resource_max(index, "focus") * 0.10) < 1.0e-6, "宿舍磨蹭10分钟恢复10%%专注上限") and ok
	ok = _check(absf(stamina_gain - settlement.get_resource_max(index, "stamina") * 0.40) < 1.0e-6, "宿舍磨蹭10分钟恢复40%%体力上限") and ok
	ok = _check(String(settlement.students[index].current_action.action_id) != "linger_dorm_rest", "课间结束后宿舍磨蹭已结束") and ok
	return ok


## 课间结束强制回课表：磨蹭动作在课间末被换课边界中断或完成，下节课开始时回到课程动作。
func _test_break_end_interrupt() -> bool:
	configuration.globals["linger_break_chance"] = 1.0
	var simulation := _before_break(0)
	if simulation == null:
		return false
	for student: Dictionary in simulation.students:
		student.focus = 1.0
	if not _result(simulation.advance(5600.0), "推进跨过第一课间全程", simulation.error_message):
		return false
	var context: Dictionary = simulation.course_context()
	if not _check(context.kind == "lesson", "课间结束后回到下一节课"):
		return false
	var ok: bool = true
	for index in simulation.students.size():
		var action_id: String = String(simulation.students[index].current_action.action_id)
		# 课间末之后所有人必须回到真实课表动作，不再停留在磨蹭地点。
		ok = _check(action_id not in ["linger_break", "linger_dorm_rest", "eat_meal"], "课间结束磨蹭动作已结束：%s" % action_id) and ok
		ok = _check(action_id == context.default_action_id or action_id == "playground_play", "课间末角色回到课表动作") and ok
	return ok


## 同一课间只判定一次：继续推进不追加磨蹭日志。
func _test_once_per_break() -> bool:
	configuration.globals["linger_break_chance"] = 1.0
	var simulation := _before_break(0)
	if simulation == null:
		return false
	for student: Dictionary in simulation.students:
		student.focus = 1.0
	if not _result(simulation.advance(2.0), "推进跨过课间开始", simulation.error_message):
		return false
	var first_count: int = _linger_logs(simulation).size()
	if not _result(simulation.advance(120.0), "课间内继续推进", simulation.error_message):
		return false
	_check(_linger_logs(simulation).size() == first_count, "课间内继续推进不重复判定磨蹭")
	return _linger_logs(simulation).size() == first_count


## 存档往返：磨蹭随机流与已处理课间随档恢复；v6缺字段与旧档多字段都明确拒绝。
func _test_roundtrip_and_legacy() -> bool:
	var ok: bool = true
	configuration.globals["linger_break_chance"] = 1.0
	var simulation := _before_break(0)
	if simulation == null:
		return false
	for student: Dictionary in simulation.students:
		student.focus = 1.0
	if not _result(simulation.advance(2.0), "推进跨过课间开始", simulation.error_message):
		return false
	var logs_before: Array = _linger_logs(simulation)
	var save_path: String = fixture_root.path_join("linger_save.json")
	if not _result(simulation.save_file(save_path), "保存磨蹭在途存档", simulation.error_message):
		return false
	var restored := _empty()
	if restored == null:
		return false
	if not _result(restored.load_file(save_path, false), "读取磨蹭在途存档", restored.error_message):
		return false
	ok = _check(_linger_logs(restored).size() == logs_before.size(), "读档后磨蹭日志一致") and ok
	# 同一课间读档后不重复判定。
	if not _result(restored.advance(120.0), "读档后课间内继续推进", restored.error_message):
		return false
	ok = _check(_linger_logs(restored).size() == logs_before.size(), "读档后同一课间不重复触发") and ok
	# v6存档缺linger_auto字段明确拒绝。
	var parsed: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(save_path))
	parsed.erase("linger_auto")
	var corrupt_path: String = fixture_root.path_join("linger_missing.json")
	FileAccess.open(corrupt_path, FileAccess.WRITE).store_string(JSON.stringify(parsed))
	var rejected := _empty()
	if rejected == null:
		return false
	ok = _check(rejected.load_file(corrupt_path, false) != OK and not rejected.error_message.is_empty(), "v6存档缺少磨蹭状态明确拒绝") and ok
	# 旧档（save_version=5）含linger_auto字段明确拒绝。
	parsed = JSON.parse_string(FileAccess.get_file_as_string(save_path))
	parsed.save_version = 5
	var legacy_path: String = fixture_root.path_join("linger_legacy.json")
	FileAccess.open(legacy_path, FileAccess.WRITE).store_string(JSON.stringify(parsed))
	var legacy := _empty()
	if legacy == null:
		return false
	ok = _check(legacy.load_file(legacy_path, false) != OK and not legacy.error_message.is_empty(), "旧档含磨蹭状态明确拒绝") and ok
	return ok


## 大步与小步推进产生同一磨蹭时间账与随机流消耗。
func _test_step_consistency() -> bool:
	configuration.globals["linger_break_chance"] = 1.0
	var big := ClassroomSimulation.new()
	if not _result(big.setup(configuration, 711027), "创建大步真实四人局", big.error_message):
		return false
	var big_controller := ClassroomBehaviorController.new()
	root.add_child(big_controller)
	big_controller.setup(big)
	big.decision_handler = big_controller.decide
	controllers.append(big_controller)
	var small := ClassroomSimulation.new()
	if not _result(small.setup(configuration, 711027), "创建小步真实四人局", small.error_message):
		return false
	var small_controller := ClassroomBehaviorController.new()
	root.add_child(small_controller)
	small_controller.setup(small)
	small.decision_handler = small_controller.decide
	controllers.append(small_controller)
	for simulation in [big, small]:
		if not _result(simulation.set_debug_time(1, 0.0), "大步小步同步定位", simulation.error_message):
			return false
	if not _result(big.advance(86400.0), "大步推进一天", big.error_message):
		return false
	var stepped: float = 0.0
	while stepped < 86400.0:
		var step: float = minf(37.0, 86400.0 - stepped)
		if not _result(small.advance(step), "小步推进一天", small.error_message):
			return false
		stepped += step
	var big_logs: Array = _linger_logs(big)
	var small_logs: Array = _linger_logs(small)
	if not _check(big_logs.size() == small_logs.size(), "大步小步磨蹭日志条数一致"):
		return false
	var ok: bool = true
	for i in big_logs.size():
		ok = _check(String(big_logs[i].message) == String(small_logs[i].message) and absf(float(big_logs[i].clock_seconds) - float(small_logs[i].clock_seconds)) < 1.0e-6, "第%d条磨蹭日志时刻与去向一致" % (i + 1)) and ok
	ok = _check(str(big.linger_auto.rng_state) == str(small.linger_auto.rng_state), "大步小步磨蹭随机流状态一致") and ok
	for index in big.students.size():
		ok = _check(absf(float(big.students[index].focus) - float(small.students[index].focus)) < 1.0e-6, "大步小步第%d人专注一致" % index) and ok
		ok = _check(absf(float(big.students[index].stamina) - float(small.students[index].stamina)) < 1.0e-6, "大步小步第%d人体力一致" % index) and ok
	return ok


## 每次断言均计数，失败保留原始原因。
func _check(condition: bool, message: String) -> bool:
	checks += 1
	if not condition:
		failures.append(message)
	return condition


## 业务入口错误包含原始错误码与执行器原因。
func _result(result: Error, message: String, detail: String = "") -> bool:
	return _check(result == OK, "%s：%s %s" % [message, result, detail])


## 释放真实行为树；成功仅清理登记文件，失败保留独占目录与非零退出码。
func _finish() -> void:
	for controller in controllers:
		controller.free()
	if failures.is_empty():
		for path: String in fixture_files_list():
			if FileAccess.file_exists(path):
				_result(DirAccess.remove_absolute(path), "清理当前验证文件")
		if not fixture_root.is_empty():
			_result(DirAccess.remove_absolute(fixture_root), "清理当前验证目录")
	if failures.is_empty():
		print("LINGER_BREAK_TEST_PASS checks=%d" % checks)
		quit(0)
	else:
		for message: String in failures:
			push_error(message)
		print("LINGER_BREAK_TEST_FAIL checks=%d failures=%d fixtures=%s" % [checks, failures.size(), fixture_root])
		quit(1)


## 本组写入的临时文件清单。
func fixture_files_list() -> Array[String]:
	return [fixture_root.path_join("linger_save.json"), fixture_root.path_join("linger_missing.json"), fixture_root.path_join("linger_legacy.json")]
