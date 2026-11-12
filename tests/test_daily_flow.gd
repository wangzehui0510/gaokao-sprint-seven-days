extends SceneTree
## 用真实配置、四人共享行为树和生产存档验证全天规则，首次课程沿用真实每日发奖。

# 低资源夹具不触及上下限，恢复费率按百分比乘真实上限，消耗保持每分钟绝对值。
const DORM_RATES: Dictionary = {
	"dorm_study": {"focus": -0.6, "stamina": -0.2, "knowledge": 0.2},
	"dorm_practice": {"focus": -1.5, "stamina": -0.3, "knowledge": 0.35},
	"dorm_game": {"focus": 3.0, "stamina": -0.3, "knowledge": 0.0},
	"dorm_workout": {"focus": 0.5, "stamina": -2.0, "knowledge": 0.12},
	"dorm_wash": {"focus": 2.0, "stamina": 1.0, "knowledge": 0.0},
	"dorm_rest": {"focus": 1.0, "stamina": 4.0, "knowledge": 0.0},
}

# 所有文件只写入本次进程独占的缓存子目录，不访问正式局、开发局或窗口偏好。
var fixture_root: String = ""
var fixture_files: Array[String] = []
var configuration: GameConfig
var owned_controllers: Array[ClassroomBehaviorController] = []
var checks: int = 0
var failures: Array[String] = []


## 等待场景树建立后开始真实规则验收。
func _initialize() -> void:
	call_deferred("_run")


## 每个场景必须执行到返回点，脚本错误不能跳过剩余断言却报告通过。
func _run() -> void:
	for dependency in ["res://scripts/core/classroom_simulation.gd", "res://scripts/ai/classroom_behavior_controller.gd"]:
		var script: Script = load(dependency)
		if script == null or not script.can_instantiate():
			_check(false, "全天流程依赖无法实例化：" + dependency)
			_finish()
			return
	configuration = GameConfig.new()
	if not _result(configuration.load_file(), "正式配置完整加载", configuration.error_message):
		_finish()
		return
	fixture_root = OS.get_cache_dir().path_join("ClassroomDailyFlowTest_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	if not _result(DirAccess.make_dir_recursive_absolute(fixture_root), "建立本次独占存档目录"):
		_finish()
		return
	_check(_test_music(), "音乐课程场景完整执行")
	_check(_test_art(), "美术课程场景完整执行")
	_check(_test_support_periods(), "课间午餐午休眼保健操与晚间场景完整执行")
	_check(_test_midnight(), "四人跨午夜场景完整执行")
	_check(_test_exercise_completion(), "完整课间操及状态到期场景完整执行")
	_check(_test_interrupted_exercise(), "课间操被打断场景完整执行")
	_check(_test_buff_snapshot(), "状态存档及不补离线时长场景完整执行")
	_check(_test_whole_day(), "四人一整天连续推进场景完整执行")
	_finish()


## 建立独立真实局，开发时钟只定位课程，不替换行为树或业务结算。
func _new_simulation(seconds: float, test_day: int = 1) -> ClassroomSimulation:
	var simulation := _empty_simulation()
	if simulation == null:
		return null
	if not _result(simulation.set_debug_time(test_day, seconds), "定位真实课表时段", simulation.error_message):
		return null
	if not _result(simulation.advance(0.0), "四人共享树开始当前活动", simulation.error_message):
		return null
	return simulation


## 读档前只建立正常执行器和四棵树，不提前推进或重新抽取待恢复的动作。
func _empty_simulation() -> ClassroomSimulation:
	var simulation := ClassroomSimulation.new()
	if not _result(simulation.setup(configuration, 261107), "创建四人独立局", simulation.error_message):
		return null
	# 全天算例专门核对课表、费率与状态，自主竞争与宿舍结伴另由专项组验收。
	simulation.phase_scope.social_auto_actions = []
	simulation.phase_scope.dorm_auto_actions = ["dorm_study", "dorm_practice", "dorm_game", "dorm_workout", "dorm_wash", "dorm_rest"]
	var controller := ClassroomBehaviorController.new()
	root.add_child(controller)
	controller.setup(simulation)
	owned_controllers.append(controller)
	simulation.decision_handler = controller.decide
	return simulation


## 使用不同的起始资源确认四人各自结算，不用满资源掩盖恢复费率错误。
func _set_resources(simulation: ClassroomSimulation, focus_base: float, stamina_base: float) -> void:
	for index in simulation.students.size():
		simulation.students[index].focus = focus_base + index * 3.0
		simulation.students[index].stamina = stamina_base + index * 3.0


## 音乐使用真实恢复课程，消耗和恢复都按已执行的两分钟计算。
func _test_music() -> bool:
	var simulation := _new_simulation(10.0 * 3600.0)
	if simulation == null:
		return false
	_set_resources(simulation, 40.0, 70.0)
	var knowledge_before: Array = simulation.students.map(func(student: Dictionary): return student.knowledge.duplicate(true))
	if not _result(simulation.advance(120.0), "音乐课真实执行两分钟", simulation.error_message):
		return false
	for index in simulation.students.size():
		var student: Dictionary = simulation.students[index]
		_check(student.current_action.action_id == "music_class" and simulation.student_location(index) == "classroom", "音乐课四人留在真实教室课程")
		_close(student.focus, 40.0 + index * 3.0 + 0.03 * simulation.get_resource_max(index, "focus"), "音乐两分钟按上限恢复3%%专注：角色%d" % index)
		_close(student.stamina, 69.8 + index * 3.0, "音乐两分钟消耗0.2体力：角色%d" % index)
		_check(student.knowledge == knowledge_before[index] and not student.knowledge.has("music"), "音乐不创建或增加任何知识：角色%d" % index)
	return true


## 美术独立恢复体力，不能沿用音乐的专注恢复或产生美术知识。
func _test_art() -> bool:
	var simulation := _new_simulation(14.0 * 3600.0 + 55.0 * 60.0)
	if simulation == null:
		return false
	_set_resources(simulation, 70.0, 40.0)
	var knowledge_before: Array = simulation.students.map(func(student: Dictionary): return student.knowledge.duplicate(true))
	if not _result(simulation.advance(120.0), "美术课真实执行两分钟", simulation.error_message):
		return false
	for index in simulation.students.size():
		var student: Dictionary = simulation.students[index]
		_check(student.current_action.action_id == "art_class" and simulation.student_location(index) == "classroom", "美术课四人留在真实教室课程")
		_close(student.stamina, 40.0 + index * 3.0 + 0.03 * simulation.get_resource_max(index, "stamina"), "美术两分钟按上限恢复3%%体力：角色%d" % index)
		_close(student.focus, 69.6 + index * 3.0, "美术两分钟消耗0.4专注：角色%d" % index)
		_check(student.knowledge == knowledge_before[index] and not student.knowledge.has("art"), "美术不创建或增加任何知识：角色%d" % index)
	return true


## 从真实课表进入各支持时段，宿舍按真实自主活动核对资源与分科收益。
func _test_support_periods() -> bool:
	var cases: Array[Dictionary] = [
		{"label": "普通课间", "seconds": 31500.0, "duration": 60.0, "action": "break_rest", "location": "classroom", "focus": 0.6, "stamina": 0.3},
		{"label": "午餐", "seconds": 42000.0, "duration": 120.0, "action": "eat_meal", "location": "canteen", "focus": 0.6, "stamina": 8.0},
		{"label": "午休", "seconds": 42600.0, "duration": 120.0, "action": "dorm", "location": "dorm"},
		{"label": "眼保健操", "seconds": 56400.0, "duration": 60.0, "action": "eye_exercise", "location": "classroom", "focus": 1.0, "stamina": 0.2},
		{"label": "晚间", "seconds": 72000.0, "duration": 60.0, "action": "dorm", "location": "dorm"},
	]
	for scenario in cases:
		var simulation := _new_simulation(scenario.seconds)
		if simulation == null:
			return false
		_set_resources(simulation, 40.0, 50.0)
		var original_actions: Array = simulation.students.map(func(student: Dictionary): return student.current_action.duplicate(true))
		if not _result(simulation.advance(scenario.duration), "%s按实际时长执行" % scenario.label, simulation.error_message):
			return false
		for index in simulation.students.size():
			var student: Dictionary = simulation.students[index]
			if scenario.action == "dorm":
				var action: Dictionary = original_actions[index]
				_check(action.action_id in DORM_RATES and student.current_action.instance_id == action.instance_id and simulation.student_location(index) == scenario.location, "%s继续真实自主活动与地点：角色%d" % [scenario.label, index])
				for resource: String in ["focus", "stamina"]:
					var initial: float = (40.0 if resource == "focus" else 50.0) + index * 3.0
					_close(student[resource], initial + _dorm_resource_rate(simulation, index, action.action_id, resource) * scenario.duration / 60.0, "%s按%s实际费率变化：角色%d" % [scenario.label, resource, index])
				_check_dorm_knowledge(simulation, index, action, scenario.duration / 60.0, "%s角色%d" % [scenario.label, index])
			else:
				_check(student.current_action.action_id == scenario.action and simulation.student_location(index) == scenario.location, "%s选择正确动作与地点：角色%d" % [scenario.label, index])
				_close(student.focus, 40.0 + index * 3.0 + scenario.focus * simulation.get_resource_max(index, "focus") / 100.0, "%s专注按真实上限恢复：角色%d" % [scenario.label, index])
				_close(student.stamina, 50.0 + index * 3.0 + scenario.stamina * simulation.get_resource_max(index, "stamina") / 100.0, "%s体力按真实上限恢复：角色%d" % [scenario.label, index])
				_check(student.knowledge.values().all(func(value): return value == 0.0), "%s不增长课堂知识：角色%d" % [scenario.label, index])
	return true


## 跨午夜只推进真实九十秒，四人旧动作切换到新日课表，不漏秒或补整夜收益。
func _test_midnight() -> bool:
	var simulation := _new_simulation(86370.0)
	if simulation == null:
		return false
	_set_resources(simulation, 40.0, 50.0)
	var original_actions: Array = simulation.students.map(func(student: Dictionary): return student.current_action.duplicate(true))
	if not _result(simulation.advance(90.0), "从23:59:30推进到次日00:01", simulation.error_message):
		return false
	_check(simulation.day == 2, "午夜真实进入本局第二天")
	_close(simulation.clock_seconds, 60.0, "跨午夜剩余一分钟落在新日")
	_close(simulation.elapsed_s, 90.0, "跨午夜不扩大在线执行时长")
	for index in simulation.students.size():
		var student: Dictionary = simulation.students[index]
		var action: Dictionary = original_actions[index]
		# 午夜前只执行原活动三十秒，午夜后真实休息六十秒，不能把整段当作休息。
		_close(student.focus, 40.0 + index * 3.0 + _dorm_resource_rate(simulation, index, action.action_id, "focus") * 0.5 + 0.01 * simulation.get_resource_max(index, "focus"), "跨日专注分段结算九十秒：角色%d" % index)
		_close(student.stamina, 50.0 + index * 3.0 + _dorm_resource_rate(simulation, index, action.action_id, "stamina") * 0.5 + 0.04 * simulation.get_resource_max(index, "stamina"), "跨日体力分段结算九十秒：角色%d" % index)
		_check(student.current_action.action_id == "dorm_rest" and student.current_action.dorm_recovery and student.current_action.instance_id != action.instance_id, "午夜为角色%d结束旧日动作并开始十分钟休息" % index)
		_check_dorm_knowledge(simulation, index, action, 0.5, "跨午夜角色%d" % index)
		_check(simulation.get_dorm_summary(2, index).totals.values().all(func(value): return value == 0.0), "新日真实休息不新增宿舍知识")
		_check(simulation.logs.any(func(entry: Dictionary): return entry.student_index == index and entry.type == "interrupt" and entry.day == 2 and entry.clock_seconds == 0.0), "角色%d午夜打断有实际日志" % index)
	return true


## 只有完整课间操生成身体舒展，到期降低上限时只裁去超出部分。
func _test_exercise_completion() -> bool:
	var simulation := _new_simulation(34800.0)
	if simulation == null:
		return false
	_set_resources(simulation, 40.0, 50.0)
	if not _result(simulation.advance(1200.0), "四人完整执行课间操", simulation.error_message):
		return false
	var music_instances: Array = simulation.students.map(func(student: Dictionary): return student.current_action.instance_id)
	for index in simulation.students.size():
		_check(_stretched(simulation, index).size() == 3 and simulation.students[index].buffs.size() == 1, "完整课间操只产生一份真实身体舒展：角色%d" % index)
		var base_max: float = simulation.config.global_value("stamina_base") + simulation.config.global_value("stamina_per_health") * simulation.students[index].attributes.health
		_close(simulation.get_resource_max(index, "stamina"), base_max + 10.0, "舒展使角色%d体力上限提高10" % index)
		_close(simulation.students[index].stamina, 40.0 + index * 3.0, "舒展只改上限、不补满已消耗体力：角色%d" % index)
		# 各自放到旧上限以上，真实验证状态到期对所有NPC的超额裁切。
		simulation.students[index].stamina = base_max + 5.0
	if not _result(simulation.advance(599.75), "推进到状态到期前四分之一秒", simulation.error_message):
		return false
	_check(simulation.students.all(func(student: Dictionary): return student.buffs.size() == 1), "到期之前四人状态仍真实存在")
	if not _result(simulation.advance(0.25), "精确推进到状态到期边界", simulation.error_message):
		return false
	for index in simulation.students.size():
		_check(simulation.students[index].buffs.is_empty(), "舒展到期从角色%d状态列表移除" % index)
		var base_max: float = simulation.config.global_value("stamina_base") + simulation.config.global_value("stamina_per_health") * simulation.students[index].attributes.health
		_close(simulation.get_resource_max(index, "stamina"), base_max, "到期恢复角色%d原体力上限" % index)
		_close(simulation.students[index].stamina, base_max, "到期只裁去角色%d超额体力" % index)
		_check(simulation.students[index].current_action.instance_id == music_instances[index], "状态到期不重开角色%d在途音乐课" % index)
		_check(simulation.logs.any(func(entry: Dictionary): return entry.student_index == index and entry.type == "buff" and entry.message.begins_with("状态结束")), "角色%d到期留下实际状态结束日志" % index)
	return true


## 中途离开课间操不发完成状态，其他三人仍独立完成并按时到期。
func _test_interrupted_exercise() -> bool:
	var simulation := _new_simulation(34800.0)
	if simulation == null:
		return false
	if not _result(simulation.advance(600.0), "四人先执行半段课间操", simulation.error_message):
		return false
	if not _result(simulation.start_action(0, "rest"), "玩家真实休息打断自身课间操", simulation.error_message):
		return false
	if not _result(simulation.advance(600.0), "跨过原课间操完成时刻", simulation.error_message):
		return false
	_check(_stretched(simulation, 0).is_empty(), "被打断的玩家未获得身体舒展")
	_check(not simulation.logs.any(func(entry: Dictionary): return entry.student_index == 0 and entry.type == "buff" and entry.details.get("buff_id") == "stretched"), "被打断课间操不生成虚假获益日志")
	for index in range(1, simulation.students.size()):
		_check(not _stretched(simulation, index).is_empty(), "其他同学%d仍独立完成课间操获得状态" % index)
	if not _result(simulation.advance(600.0), "其他同学的舒展按各自时限结束", simulation.error_message):
		return false
	_check(simulation.students.all(func(student: Dictionary): return student.buffs.is_empty()), "未获得与已到期状态均不残留")
	return true


## 状态和在途课程按原剩余时长保存；电脑日期对齐不能扣掉关闭期间的状态时长。
func _test_buff_snapshot() -> bool:
	var simulation := _new_simulation(34800.0)
	if simulation == null:
		return false
	if not _result(simulation.advance(1337.5), "真实完成课间操并继续执行137.5秒", simulation.error_message):
		return false
	# 将本次独立测试局标记为昨天创建，保证系统时钟读档实际跨日而不是碰巧同课。
	var created_midnight: int = int(Time.get_unix_time_from_datetime_string(simulation.created_date + "T00:00:00"))
	simulation.created_date = Time.get_date_string_from_unix_time(created_midnight - 86400)
	var before_students: Array = simulation.students.duplicate(true)
	var before_elapsed: float = simulation.elapsed_s
	var before_clock: float = simulation.clock_seconds
	var before_rng: int = simulation.rng.state
	var path: String = fixture_root.path_join("timed_buff_roundtrip.json")
	fixture_files.append(path)
	fixture_files.append(path + ".tmp")
	if not _result(simulation.save_file(path), "只向独占缓存目录保存真实状态", simulation.error_message):
		return false
	var restored := _empty_simulation()
	if restored == null or not _result(restored.load_file(path, false), "恢复开发时钟状态而不重新开始动作", restored.error_message):
		return false
	_close(restored.elapsed_s, before_elapsed, "状态读档不推进在线执行秒数")
	_close(restored.clock_seconds, before_clock, "开发时钟读档保留课程时刻")
	_check(restored.rng.state == before_rng, "状态读档保留精确随机流")
	for index in restored.students.size():
		_check(restored.students[index].buffs == before_students[index].buffs, "角色%d保留状态原到期时刻" % index)
		var restored_action: Dictionary = restored.students[index].current_action
		var original_action: Dictionary = before_students[index].current_action
		_check(restored_action.instance_id == original_action.instance_id and restored_action.action_id == original_action.action_id, "角色%d保留原课程实例" % index)
		_close(restored_action.started_at, original_action.started_at, "角色%d保留原课程开始时刻" % index)
		_close(restored_action.ends_at, original_action.ends_at, "角色%d保留原课程结束时刻" % index)
		_close(restored_action.duration_s, original_action.duration_s, "角色%d保留已抽取的课程时长" % index)
		_close(restored_action.last_settled_at, original_action.last_settled_at, "角色%d保留原课程结算时刻" % index)
		_close(restored.students[index].focus, before_students[index].focus, "角色%d读档不补专注" % index)
		_close(restored.students[index].stamina, before_students[index].stamina, "角色%d读档不补体力" % index)
	var aligned := _empty_simulation()
	if aligned == null or not _result(aligned.load_file(path, true), "恢复到真实电脑日期并验证无离线推进", aligned.error_message):
		return false
	_check(aligned.day == 2 and not aligned.is_debug_time, "昨天创建的独立局真实对齐为第二天")
	_close(aligned.elapsed_s, before_elapsed, "跨日读档没有补在线秒数")
	for index in aligned.students.size():
		_check(aligned.students[index].buffs == before_students[index].buffs, "跨日关闭不消耗角色%d舒展剩余时长" % index)
		_check(aligned.students[index].knowledge == before_students[index].knowledge, "跨日关闭不增加角色%d知识" % index)
		_close(aligned.students[index].focus, before_students[index].focus, "跨日关闭不增加角色%d专注" % index)
		_close(aligned.students[index].stamina, before_students[index].stamina, "跨日关闭不增加角色%d体力" % index)
	var remaining: float = float(_stretched(restored, 0).expires_at) - restored.elapsed_s
	_close(remaining, 462.5, "恢复后仍剩真实462.5秒状态")
	if not _result(restored.advance(remaining - 0.25), "读档后执行至原到期边界之前", restored.error_message):
		return false
	_check(restored.students.all(func(student: Dictionary): return student.buffs.size() == 1), "恢复状态不会提前到期")
	if not _result(restored.advance(0.25), "读档后执行至原到期边界", restored.error_message):
		return false
	_check(restored.students.all(func(student: Dictionary): return student.buffs.is_empty()), "恢复状态仍在原在线到期点结束")
	return true


## 一次连续推进二十四小时，覆盖全部课程路径、恢复时段、午夜及四人独立状态。
func _test_whole_day() -> bool:
	var simulation := _new_simulation(0.0)
	if simulation == null:
		return false
	if not _result(simulation.advance(86400.0), "四人完整连续运行第一天", simulation.error_message):
		return false
	_check(simulation.day == 2, "一整天结束进入第二天")
	_close(simulation.clock_seconds, 0.0, "完整一天落在次日午夜")
	_close(simulation.elapsed_s, 86400.0, "整天连续推进没有漏掉实际时间")
	for period_id in ["lesson_1", "break_1", "lesson_2", "exercise", "lesson_3", "break_2", "lesson_4", "lunch", "lunch_rest", "lesson_5", "break_3", "lesson_6", "eye_exercise", "break_4", "lesson_7"]:
		_check(simulation.logs.any(func(entry: Dictionary): return entry.type == "course" and entry.day == 1 and entry.details.period_id == period_id), "连续运行真实经过时段：" + period_id)
	for index in simulation.students.size():
		var student: Dictionary = simulation.students[index]
		for action_id in ["study", "physical_study", "music_class", "art_class", "eat_meal", "dorm_rest", "morning_exercise", "eye_exercise", "break_rest"]:
			_check(simulation.logs.any(func(entry: Dictionary): return entry.student_index == index and entry.type == "start" and entry.details.action_id == action_id), "角色%d全天真实执行过%s" % [index, action_id])
		for resource in ["focus", "stamina"]:
			_check(is_finite(student[resource]) and student[resource] >= 0.0 and student[resource] <= simulation.get_resource_max(index, resource), "角色%d全天结束%s仍为范围内有限值" % [index, resource])
		_check(student.current_action.action_id in DORM_RATES and student.current_action.started_at == simulation.elapsed_s and simulation.student_location(index) == "dorm", "角色%d全天结束后从次日午夜接续真实宿舍活动" % index)
		_check(student.knowledge.keys().size() == 4 and student.knowledge.values().all(func(value): return is_finite(value) and value > 0.0), "角色%d全天只获得四科真实知识且均为有限正值" % index)
	_check(_resource_logs_are_finite(simulation), "全天已完成动作的资源记录均为有限值且没有越界")
	var other_knowledge: Array = simulation.students.slice(1).map(func(student: Dictionary): return student.knowledge.duplicate(true))
	simulation.students[0].knowledge.chinese += 1.0
	for index in range(1, simulation.students.size()):
		_check(simulation.students[index].knowledge == other_knowledge[index - 1], "角色%d知识字典不与玩家共享" % index)
	_check(simulation.interactions.is_empty(), "本组专门关闭竞争后，全天课表循环不产生自主互动")
	return true


## 独立费率表区分按上限恢复和固定消耗，不读取生产结算结果作为预期。
func _dorm_resource_rate(simulation: ClassroomSimulation, index: int, action_id: String, resource: String) -> float:
	var rate: float = DORM_RATES[action_id][resource]
	return rate * simulation.get_resource_max(index, resource) / 100.0 if rate > 0.0 else rate


## 短区间知识从零开始，只允许所选文化课或固定体育科目按独立费率增长。
func _check_dorm_knowledge(simulation: ClassroomSimulation, index: int, action: Dictionary, minutes: float, label: String) -> void:
	var student: Dictionary = simulation.students[index]
	var multiplier: float = 1.0 + simulation.effective_attribute(index, "attention") * simulation.config.global_value("learning_focus_coefficient")
	for subject: String in student.knowledge:
		var expected: float = DORM_RATES[action.action_id].knowledge * minutes * multiplier if subject == action.subject_id else 0.0
		_close(student.knowledge[subject], expected, "%s只增加真实动作的%s知识" % [label, subject])


## 批量核对真实动作日志，避免只检查末态而遗漏过程中的无效资源。
func _resource_logs_are_finite(simulation: ClassroomSimulation) -> bool:
	for entry in simulation.logs:
		if entry.type not in ["complete", "interrupt"]:
			continue
		for change in entry.details.resource_changes.values():
			for field in ["requested", "actual", "current", "maximum"]:
				if not is_finite(change[field]):
					return false
			if change.current < 0.0 or change.current > change.maximum:
				return false
	return true


## 只读取真实产生的身体舒展实例，不为缺失状态构造默认到期时间。
func _stretched(simulation: ClassroomSimulation, index: int) -> Dictionary:
	for instance in simulation.students[index].buffs:
		if instance.buff_id == "stretched":
			return instance
	return {}


## 实际入口失败时记录生产错误，调用方随即停止本场景。
func _result(result: Error, message: String, detail: String = "") -> bool:
	_check(result == OK, "%s：错误码%d %s" % [message, result, detail])
	return result == OK


## 数值结果只接受固定误差内的真实计算值。
func _close(actual: float, expected: float, message: String) -> void:
	_check(absf(actual - expected) < 0.000001, "%s：实际%s，预期%s" % [message, actual, expected])


## 汇总实际断言，任何失败均保留清楚原因。
func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)


## 释放真实行为树；成功时仅清理本进程写入的文件，失败时保留独立证据目录。
func _finish() -> void:
	for controller in owned_controllers:
		controller.free()
	if failures.is_empty():
		for path in fixture_files:
			if FileAccess.file_exists(path):
				_result(DirAccess.remove_absolute(path), "清理本次独占测试文件")
		if not fixture_root.is_empty():
			_result(DirAccess.remove_absolute(fixture_root), "清理本次独占测试目录")
	if failures.is_empty():
		print("DAILY_FLOW_TEST_PASS checks=%d" % checks)
		quit(0)
	else:
		for message in failures:
			push_error(message)
		print("DAILY_FLOW_TEST_FAIL checks=%d failures=%d fixtures=%s" % [checks, failures.size(), fixture_root])
		quit(1)
