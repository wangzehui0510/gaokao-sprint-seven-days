extends SceneTree
## 用真实行为树和持久化入口验证事件课表热改，失败必须保留整份有效局。

# 配置副本与存档只写入本进程独占缓存，正式JSON和玩家存档不参与验证。
var fixture_root: String = ""
var fixture_files: Array[String] = []
var configuration: GameConfig
var owned_controllers: Array[ClassroomBehaviorController] = []
var checks: int = 0
var failures: Array[String] = []


## 延迟到场景树就绪再接入四棵真实行为树。
func _initialize() -> void:
	call_deferred("_run")


## 场景必须完整返回，脚本中断不能跳过断言后报告通过。
func _run() -> void:
	configuration = GameConfig.new()
	if not _result(configuration.load_file(), "加载正式配置", configuration.error_message):
		_finish()
		return
	fixture_root = OS.get_cache_dir().path_join("ClassroomRoundReload_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	if not _result(DirAccess.make_dir_recursive_absolute(fixture_root), "建立独占配置热改目录"):
		_finish()
		return
	_check(_test_past_exam_atomicity(), "过去开考边界整次拒绝并保留旧局")
	_check(_test_past_daily_atomicity(), "过去日榜边界整次拒绝并保留旧局")
	_check(_test_future_boundaries(), "未来考试、日榜与终局按新课表边界发生")
	_check(_test_current_boundary(), "恰好当前时刻的新开考边界不伪造过去")
	_check(_test_rates_only(), "仅费率热改即时生效且不重开动作")
	_check(_test_snapshot_history(), "已发生快照保留原边界及原参数")
	_check(_test_rewound_frontier(), "开发时钟回退不把已观察时段当作未来")
	_check(_test_cross_config_load(), "跨配置读档预检失败保护有效局，合法未来可继续")
	_check(_test_offline_original_plan(), "离线先按保存课表补纯事件，再规划新课表")
	_check(_test_dorm_timetable_change(), "调表和跨配置恢复后只在真实自由时段保留宿舍活动")
	_finish()


## 建立隔离角色与真实决策树，动作仍由生产推进器实际启动。
func _simulation(at_day: int, seconds: float, source: GameConfig = null) -> ClassroomSimulation:
	var simulation := ClassroomSimulation.new()
	if not _result(simulation.setup(configuration if source == null else source, 261107), "建立真实四人局", simulation.error_message):
		return null
	# 热改算例隔离自主竞争，确保被核对的课程段由本场景显式控制。
	simulation.phase_scope.social_auto_actions = []
	var controller := ClassroomBehaviorController.new()
	root.add_child(controller)
	controller.setup(simulation)
	owned_controllers.append(controller)
	simulation.decision_handler = controller.decide
	if not _result(simulation.set_debug_time(at_day, seconds), "定位独立验证时钟", simulation.error_message):
		return null
	if not _result(simulation.advance(0.0), "生产行为树进入当前课表", simulation.error_message):
		return null
	return simulation


## 同一配置同时含合法未来日榜与非法过去考试，验证不会先提交一部分边界。
func _test_past_exam_atomicity() -> bool:
	var simulation := _simulation(7, 50399.0)
	var changed := _config("past_exam.json", {
		"lunch_rest": {"end": 50300.0}, "lesson_5": {"start": 50300.0},
		"lesson_7": {"end": 60200.0},
	})
	if simulation == null or changed == null:
		return false
	var before: Dictionary = _authority(simulation)
	_check(simulation.apply_config(changed) != OK, "开考移到当前时刻之前明确拒绝")
	_check(simulation.error_message.contains("已观察时刻之前"), "拒绝说明缺少可追溯开考状态")
	_check(_authority(simulation) == before, "失败不切配置、不改日榜/考试/终局、角色或随机流")
	if not _result(simulation.advance(1.0), "拒绝后仍按旧14:00边界执行", simulation.error_message):
		return false
	_check(simulation.get_exam_board("chinese").status == "snapshot", "旧语文开考事件仍真实取值")
	_check(simulation.get_exam_board("physical").status == "published", "旧体育事件仍在首场开考公布")
	_check(simulation.get_round_summary().final_seconds == 60000.0, "拒绝不会残留另一项合法终局修改")
	return true


## 已积累到当前时刻的当日知识不能被追溯截短成较早出榜。
func _test_past_daily_atomicity() -> bool:
	var simulation := _simulation(1, 59900.0)
	var changed := _config("past_daily.json", {"lesson_7": {"end": 59800.0}})
	if simulation == null or changed == null:
		return false
	var before: Dictionary = _authority(simulation)
	_check(simulation.apply_config(changed) != OK, "当日日榜移到过去明确拒绝")
	_check(simulation.error_message.contains("尚待日榜"), "日榜错误能定位到具体事件")
	_check(_authority(simulation) == before, "日榜拒绝保留全部角色、配置与账本")
	if not _result(simulation.advance(100.0), "拒绝后按旧16:40真实出榜", simulation.error_message):
		return false
	_check(simulation.get_daily_board(1, "chinese").status == "published", "有效日榜不会因失败热改变成缺失")
	return true


## 未发生事件允许移到未来，查询摘要与真实执行均读取更新后的权威边界。
func _test_future_boundaries() -> bool:
	var changed := _config("future_boundaries.json", {
		"lunch_rest": {"end": 50500.0}, "lesson_5": {"start": 50500.0},
		"lesson_7": {"end": 60100.0},
	})
	var simulation := _simulation(7, 50399.0)
	if simulation == null or changed == null or not _result(simulation.apply_config(changed), "未来课表更新", simulation.error_message):
		return false
	_check(simulation.get_exam_board("chinese").start_seconds == 50500.0, "待开考界面数据采用新时刻")
	_check(simulation.get_daily_board(7, "chinese").end_seconds == 60100.0, "待出榜数据采用新日榜时刻")
	_check(simulation.get_round_summary().final_day == 7 and simulation.get_round_summary().final_seconds == 60100.0, "局摘要提供真实终局边界")
	if not _result(simulation.advance(1.0), "经过旧14:00时刻", simulation.error_message):
		return false
	_check(simulation.get_exam_board("chinese").status == "pending", "旧开考时刻不提前取值")
	if not _result(simulation.advance(100.0), "到达新开考时刻", simulation.error_message):
		return false
	var chinese: Dictionary = simulation.get_exam_board("chinese")
	_check(chinese.status == "snapshot" and chinese.rows.size() == 4, "新时刻真实取得四人快照")
	for row: Dictionary in chinese.rows:
		_check(row.config_fingerprint == changed.fingerprint and row.exam_intelligence_coefficient == 0.06, "未来开考采用更新后的来源参数")
	if not _result(simulation.advance(60000.0 - simulation.clock_seconds), "执行至旧终局时刻", simulation.error_message):
		return false
	_check(not simulation.is_round_finished() and simulation.get_daily_board(7, "chinese").status == "pending", "旧终局不会提前出榜或停局")
	if not _result(simulation.advance(100.0), "执行至更新后终局", simulation.error_message):
		return false
	_check(simulation.is_round_finished() and simulation.clock_seconds == 60100.0, "在真实更新边界结束本局")
	_check(simulation.get_daily_board(7, "chinese").status == "published", "更新后终局保留真实当日日榜")
	return true


## 当前时刻无需补造历史，允许下一次真实边界处理采集当时状态。
func _test_current_boundary() -> bool:
	var simulation := _simulation(7, 50399.0)
	var changed := _config("current_exam.json", {
		"lunch_rest": {"end": 50399.0}, "lesson_5": {"start": 50399.0},
	})
	if simulation == null or changed == null or not _result(simulation.apply_config(changed), "开考边界移到恰好当前时刻", simulation.error_message):
		return false
	if not _result(simulation.advance(0.0), "当前时刻执行真实取值", simulation.error_message):
		return false
	_check(simulation.get_exam_board("chinese").status == "snapshot", "当前时刻产生真实快照")
	_check(simulation.get_exam_board("physical").status == "published", "首考同时真实公布体育")
	return true


## 无课表变化的持续费用修改不影响在途动作身份、时长、启动费或随机流。
func _test_rates_only() -> bool:
	var simulation := _simulation(1, 28860.0)
	var changed := _config("rates_only.json", {})
	if simulation == null or changed == null:
		return false
	var action: Dictionary = simulation.students[0].current_action.duplicate(true)
	var focus: float = simulation.students[0].focus
	var rng_state: String = str(simulation.rng.state)
	if not _result(simulation.apply_config(changed), "仅费率和后续计分参数更新", simulation.error_message):
		return false
	_check(simulation.students[0].current_action == action, "费率更新不重开或重抽动作")
	_check(simulation.students[0].focus == focus and str(simulation.rng.state) == rng_state, "费率更新当刻不重复收费或抽奖")
	if not _result(simulation.advance(60.0), "同一动作继续真实执行一分钟", simulation.error_message):
		return false
	_check(absf(simulation.students[0].focus - (focus - 2.0)) < 0.000001, "既有学习段即时采用新持续专注费用")
	return true


## 已快照考试不适用待事件改时约束，历史结束时刻及计分参数均保持原值。
func _test_snapshot_history() -> bool:
	var simulation := _simulation(7, 50399.0)
	if simulation == null or not _result(simulation.advance(2.0), "先实际经过开考边界", simulation.error_message):
		return false
	var chinese: Dictionary = simulation.get_exam_board("chinese")
	var physical: Dictionary = simulation.get_exam_board("physical")
	var changed := _config("historical_timing.json", {
		"lunch_rest": {"end": 50300.0},
		"lesson_5": {"start": 50300.0, "end": 53000.0}, "break_3": {"start": 53000.0},
	})
	if changed == null or not _result(simulation.apply_config(changed), "已快照后的课表热改", simulation.error_message):
		return false
	_check(simulation.get_exam_board("chinese") == chinese and simulation.get_exam_board("physical") == physical, "快照与已公布体育不重取或改写原边界")
	if not _result(simulation.advance(53000.0 - simulation.clock_seconds), "经过新课表结束时刻", simulation.error_message):
		return false
	_check(simulation.get_exam_board("chinese").status == "snapshot", "已快照成绩沿用原公布时刻")
	if not _result(simulation.advance(100.0), "到达原快照公布边界", simulation.error_message):
		return false
	_check(simulation.get_exam_board("chinese").status == "published" and simulation.get_exam_board("chinese").rows == chinese.rows, "原公布边界只公布既有结果")
	return true


## 最远已观察边界在开发回退后仍约束新课表，避免用后来状态补造过去。
func _test_rewound_frontier() -> bool:
	var simulation := _simulation(7, 50399.0)
	if simulation == null or not _result(simulation.advance(2601.0), "真实执行至14:43:20", simulation.error_message):
		return false
	if not _result(simulation.set_debug_time(7, 50000.0), "开发时钟显式回退", simulation.error_message):
		return false
	var changed := _config("rewound_past_math.json", {
		"lesson_5": {"end": 52800.0}, "break_3": {"start": 52800.0, "end": 52900.0},
		"lesson_6": {"start": 52900.0},
	})
	if changed == null:
		return false
	var before: Dictionary = _authority(simulation)
	_check(simulation.apply_config(changed) != OK, "新数学开考晚于回退时钟但早于已观察边界仍拒绝")
	_check(_authority(simulation) == before, "回退局热改失败仍保护既有快照及整局")
	return true


## 读档兼容更新在候选账本完成，失败不会先覆盖目标局的角色、时钟或历史。
func _test_cross_config_load() -> bool:
	var source := _simulation(7, 50399.0)
	var past := _config("load_past_exam.json", {"lunch_rest": {"end": 50300.0}, "lesson_5": {"start": 50300.0}})
	var future := _config("load_future_exam.json", {"lunch_rest": {"end": 50500.0}, "lesson_5": {"start": 50500.0}})
	if source == null or past == null or future == null or not _save(source, "source_before_exam.json"):
		return false
	var target := _simulation(2, 28800.0, past)
	if target == null:
		return false
	var before: Dictionary = _authority(target)
	_check(target.load_file(_path("source_before_exam.json"), false) != OK, "跨配置读档拒绝过去开考边界")
	_check(target.error_message.contains("已观察时刻之前"), "读档失败暴露事件兼容性根因")
	_check(_authority(target) == before, "失败读档保护目标有效角色、配置、时钟、历史与随机流")
	target = _simulation(2, 28800.0, future)
	if target == null or not _result(target.load_file(_path("source_before_exam.json"), false), "跨配置读取合法未来课表", target.error_message):
		return false
	_check(target.day == 7 and target.clock_seconds == 50399.0 and target.get_exam_board("chinese").start_seconds == 50500.0, "成功恢复原局并采用合法未来边界")
	_check(_same(target.students, source.students), "合法跨配置读档保留实际角色与在途进度")
	if not _result(target.advance(101.0), "跨配置恢复局执行至新开考", target.error_message):
		return false
	_check(target.get_exam_board("chinese").status == "snapshot", "读档后按合法新边界真实取值")
	return true


## 恢复期间先处理原保存计划；尚未发生的新课表若追溯到恢复时刻之前则整次拒绝。
func _test_offline_original_plan() -> bool:
	var source := _simulation(6, 50000.0)
	var past := _config("offline_past_exam.json", {"lunch_rest": {"end": 50300.0}, "lesson_5": {"start": 50300.0}})
	var future := _config("offline_future_exam.json", {"lunch_rest": {"end": 50500.0}, "lesson_5": {"start": 50500.0}})
	if source == null or past == null or future == null or not _save(source, "offline_old_plan.json"):
		return false
	var target := _simulation(2, 28800.0, past)
	if target == null:
		return false
	var before: Dictionary = _authority(target)
	_check(target.load_file_at_time(_path("offline_old_plan.json"), 7, 50399.0) != OK, "离线尚未过原开考时，新课表不能将其追溯到过去")
	_check(_authority(target) == before, "离线纯事件规划后兼容失败也不覆盖目标局")
	target = _simulation(2, 28800.0, future)
	if target == null or not _result(target.load_file_at_time(_path("offline_old_plan.json"), 7, 50450.0), "离线已经经过原课表开考后恢复", target.error_message):
		return false
	var chinese: Dictionary = target.get_exam_board("chinese")
	_check(chinese.status == "snapshot" and chinese.source == "offline_frozen" and chinese.start_seconds == 50400.0, "离线快照使用原保存课表，不改为新未来时刻")
	for row: Dictionary in chinese.rows:
		_check(row.config_fingerprint == configuration.fingerprint and row.exam_intelligence_coefficient == configuration.global_value("exam_intelligence_coefficient"), "离线快照采用保存时冻结参数")
	_check(_same(target.students[0].knowledge, source.students[0].knowledge), "跨日恢复不产生离线学习")
	return true


## 调表可以提前下午课程；旧宿舍动作必须在首次继续积分之前真实中断。
func _test_dorm_timetable_change() -> bool:
	var source := _simulation(1, 45000.0)
	if source == null or not _result(source.start_action(0, "dorm_study", false, -1, "课表更新前自习", "math"), "开始实际宿舍自习", source.error_message):
		return false
	if not _result(source.advance(60.0), "宿舍自习真实执行一分钟", source.error_message) or not _save(source, "dorm_timetable_source.json"):
		return false
	var knowledge: Dictionary = source.students[0].knowledge.duplicate(true)
	var dorm: Dictionary = source.get_dorm_summary(1)
	var rng_state: String = str(source.rng.state)
	var instance_id: int = source.students[0].current_action.instance_id
	var timings: Dictionary = {"lunch_rest": {"end": 44900.0}, "lesson_5": {"start": 44900.0}}
	var changed := _config("dorm_to_lesson.json", timings)
	if changed == null or not _result(source.apply_config(changed), "合法调表把当前时刻纳入下午课程", source.error_message):
		return false
	_check(source.course_context().kind == "lesson" and source.students[0].current_action.is_empty(), "热改提交时即结束不再符合时段的宿舍动作")
	_check(source.students[0].knowledge == knowledge and source.get_dorm_summary(1) == dorm, "调表当刻保留已得宿舍知识，不额外结算")
	_check(str(source.rng.state) == rng_state, "中止宿舍动作不提前抽取新课堂动作")
	_check(_has_dorm_interruption(source, instance_id), "课表变更留下真实宿舍中断原因")
	if not _result(source.advance(0.0), "行为树接续更新后的下午课程", source.error_message):
		return false
	_check(source.config.actions[source.students[0].current_action.action_id].eligible_period != "dorm_free", "上课后不继续选择宿舍活动")
	# 特意保留相同的时段键，证明读档资格不能只靠context_key是否变化。
	var same_key := _config("dorm_same_key_lesson.json", timings, true)
	var target := _simulation(2, 28800.0, same_key) if same_key != null else null
	if target == null or not _result(target.load_file(_path("dorm_timetable_source.json"), false), "跨配置恢复到同键但已上课的时刻", target.error_message):
		return false
	_check(target.course_context().context_key == "1/lunch_rest" and target.course_context().kind == "lesson", "真实新课表复用原时段键且课程已生效")
	_check(target.students[0].current_action.is_empty(), "同键跨配置读档也明确中止宿舍活动")
	_check(_same(target.students[0].knowledge, knowledge) and _same(target.get_dorm_summary(1), dorm), "跨配置中止不新增知识或改写宿舍历史")
	_check(str(target.rng.state) == rng_state and _has_dorm_interruption(target, instance_id), "恢复不抽随机数且中断日志可见")
	if not _result(target.advance(0.0), "跨配置恢复后接续真实课堂", target.error_message):
		return false
	_check(target.config.actions[target.students[0].current_action.action_id].eligible_period != "dorm_free", "恢复后的课堂动作不再获得宿舍来源收益")
	return true


## 只接受真实旧实例的中断记录，不用当前UI标签推断课表切换已经发生。
func _has_dorm_interruption(simulation: ClassroomSimulation, instance_id: int) -> bool:
	for entry: Dictionary in simulation.logs:
		if entry.student_index == 0 and entry.type == "interrupt" and entry.details.instance_id == instance_id:
			return entry.message.contains("课表") and entry.details.knowledge_source == "dorm"
	return false


## 每个变体经完整配置入口读取，改名变体专门验证时段键不变时的宿舍资格。
func _config(filename: String, timings: Dictionary, reuse_dorm_period_id: bool = false) -> GameConfig:
	var source: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://config/game_config.json"))
	for period: Dictionary in source.tables.periods:
		if timings.has(period.id):
			var timing: Dictionary = timings[period.id]
			if timing.has("start"):
				period.start_time = timing.start / 86400.0
			if timing.has("end"):
				period.end_time = timing.end / 86400.0
		if reuse_dorm_period_id:
			if period.id == "lunch_rest":
				period.id = "midday_rest"
			elif period.id == "lesson_5":
				period.id = "lunch_rest"
	if reuse_dorm_period_id:
		for row: Dictionary in source.tables.schedule:
			if row.period_id == "lesson_5":
				row.period_id = "lunch_rest"
	for row: Dictionary in source.tables.globals:
		if row.key == "exam_intelligence_coefficient":
			row.value = 0.06
	for row: Dictionary in source.tables.effects:
		if row.id == "study_tick_1":
			row.value = -2.0
	var path: String = _path(filename)
	fixture_files.append(path)
	var output := FileAccess.open(path, FileAccess.WRITE)
	if not _check(output != null, "写入独占配置副本"):
		return null
	output.store_string(JSON.stringify(source, "", true, true))
	var write_result: Error = output.get_error()
	output.close()
	if not _result(write_result, "配置副本真实落盘"):
		return null
	var loaded := GameConfig.new()
	if not _result(loaded.load_file(path), "变体通过完整入口校验", loaded.error_message):
		return null
	return loaded


## 失败原子性比较包含账本内部来源、配置引用、随机状态与所有权威业务数据。
func _authority(simulation: ClassroomSimulation) -> Dictionary:
	return {
		"config": simulation.config, "round_config": simulation.round_progression.configuration,
		"round": simulation.round_progression.data.duplicate(true), "events": simulation.round_progression.events.duplicate(true),
		"students": simulation.students.duplicate(true), "logs": simulation.logs.duplicate(true),
		"interactions": simulation.interactions.duplicate(true), "notes": simulation.notes.duplicate(true),
		"violations": simulation.violations.duplicate(true), "created_date": simulation.created_date,
		"day": simulation.day, "clock_seconds": simulation.clock_seconds, "elapsed_s": simulation.elapsed_s,
		"rng_seed": str(simulation.rng.seed), "rng_state": str(simulation.rng.state),
		"next_action_number": simulation.next_action_number, "next_interaction_number": simulation.next_interaction_number,
		"next_violation_number": simulation.next_violation_number, "is_debug_time": simulation.is_debug_time,
	}


## 生产保存器只写独占路径，临时文件也登记供本次清理。
func _save(simulation: ClassroomSimulation, filename: String) -> bool:
	var path: String = _path(filename)
	fixture_files.append(path)
	fixture_files.append(path + ".tmp")
	return _result(simulation.save_file(path), "实际保存待跨配置恢复的局", simulation.error_message)


## 固定文件名只能位于本进程独占根目录。
func _path(filename: String) -> String:
	return fixture_root.path_join(filename)


## JSON往返仅放宽浮点表示误差，容器内容与顺序均保持逐项比较。
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
		for index: int in left.size():
			if not _same(left[index], right[index]):
				return false
		return true
	if (left is int or left is float) and (right is int or right is float):
		return absf(float(left) - float(right)) < 0.0000000001
	return typeof(left) == typeof(right) and left == right


## 生产入口错误保留原始原因，依赖失败结果的场景立即返回。
func _result(result: Error, message: String, detail: String = "") -> bool:
	return _check(result == OK, "%s：错误码%d %s" % [message, result, detail])


## 所有实际断言均计数，失败不会被后续成功覆盖。
func _check(condition: bool, message: String) -> bool:
	checks += 1
	if not condition:
		failures.append(message)
	return condition


## 只清理登记文件；失败保留独占证据并以非零结束。
func _finish() -> void:
	for controller in owned_controllers:
		controller.free()
	if failures.is_empty():
		for path: String in fixture_files:
			if FileAccess.file_exists(path):
				_result(DirAccess.remove_absolute(path), "清理本次验证文件")
		if not fixture_root.is_empty():
			_result(DirAccess.remove_absolute(fixture_root), "清理独占配置热改目录")
	if failures.is_empty():
		print("ROUND_CONFIG_RELOAD_TEST_PASS checks=%d" % checks)
		quit(0)
	else:
		for message: String in failures:
			push_error(message)
		print("ROUND_CONFIG_RELOAD_TEST_FAIL checks=%d failures=%d fixtures=%s" % [checks, failures.size(), fixture_root])
		quit(1)
