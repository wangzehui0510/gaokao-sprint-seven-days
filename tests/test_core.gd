extends SceneTree
## 使用真实配置、真实动作执行器和共享行为树验证阶段1/2的关键规则。

const CONFIG = preload("res://scripts/core/game_config.gd")
const SIMULATION = preload("res://scripts/core/classroom_simulation.gd")
const CONTROLLER = preload("res://scripts/ai/classroom_behavior_controller.gd")

# 测试统计只记录实际断言，不用默认成功替代失败。
var checks: int = 0
var failures: Array[String] = []
var owned_controllers: Array[Node] = []


## 等待场景树就绪后执行真实规则验证。
func _initialize() -> void:
	call_deferred("_run")


## 各用例覆盖时间积分、手动与自主冲突、免费恢复、跨课和配置存档迁移。
func _run() -> void:
	_test_learning_and_focus()
	_test_distraction_and_sleep()
	_test_physical_distraction()
	_test_zero_focus_playground_reload()
	_test_course_boundary()
	_test_config_reload_and_save()
	_test_snapshot_rejection()
	_test_system_clock_resume()
	_test_config_entry_rejection()
	_test_evening_and_exercise()
	for controller in owned_controllers:
		controller.free()
	if failures.is_empty():
		print("CORE_TEST_PASS checks=%s" % checks)
		quit(0)
	else:
		for message in failures:
			push_error(message)
		print("CORE_TEST_FAIL checks=%s failures=%s" % [checks, failures.size()])
		quit(1)


## 建立四人真实行为树，不以测试替身代替动作选择。
func _new_simulation(seconds: float) -> ClassroomSimulation:
	var game_config := CONFIG.new()
	_check(game_config.load_file() == OK, "正式JSON配置应完整通过校验：%s" % game_config.error_message)
	var simulation := SIMULATION.new()
	_check(simulation.setup(game_config, 261106) == OK, "模拟器初始化成功：%s" % simulation.error_message)
	_check(simulation.set_debug_time(1, seconds) == OK, "开发时钟设置成功")
	var controller := CONTROLLER.new()
	root.add_child(controller)
	controller.setup(simulation)
	owned_controllers.append(controller)
	simulation.decision_handler = controller.decide
	_check(simulation.advance(0.0) == OK, "四人共享树应选择真实动作：%s" % simulation.error_message)
	return simulation


## 连点专注应每次生效，已运行的学习段不能被下一次树更新覆盖。
func _test_learning_and_focus() -> void:
	var simulation := _new_simulation(8.0 * 3600.0)
	_check(simulation.students.size() == 4, "应有四份独立角色状态")
	for student in simulation.students:
		_check(student.current_action.action_id == "study", "正常知识课自主学习")
		_close(student.focus, 99.0, "自然学习启动费来自配表")
	_check(simulation.advance(60.0) == OK, "正常学习推进一分钟")
	_close(simulation.students[0].focus, 98.0, "一分钟学习专注成本")
	_close(simulation.students[0].stamina, 99.7, "一分钟学习体力成本")
	_close(simulation.students[0].knowledge.chinese, 1.0, "一分钟正常语文知识")
	simulation.students[0].focus = 40.0
	var other_focus: float = simulation.students[1].focus
	for expected_focus in [45.0, 50.0, 55.0]:
		var old_instance: int = simulation.students[0].current_action.instance_id
		_check(simulation.focus_command() == OK, "每次专注指令成功")
		_close(simulation.students[0].focus, expected_focus, "专注每次+5且不扣自然启动费")
		_check(simulation.students[0].current_action.instance_id != old_instance, "重复专注必须重新建立学习段")
	var instance: int = simulation.students[0].current_action.instance_id
	_check(simulation.advance(0.0) == OK, "更新自主树不应覆盖手动学习")
	_check(simulation.students[0].current_action.instance_id == instance, "动作实例保留")
	_close(simulation.students[1].focus, other_focus, "玩家指令不影响另一人的资源")
	_check(simulation.focus_command(1) != OK, "明确拒绝控制别人的专注")


## 开小差只在决策点判断，基础睡觉不需要发动资源。
func _test_distraction_and_sleep() -> void:
	var simulation := _new_simulation(8.0 * 3600.0)
	simulation.students[0].focus = 50.0
	simulation.students[0].current_action = {}
	_check(simulation.advance(0.0) == OK, "阈值处重新决策")
	_check(simulation.students[0].current_action.action_id == "study", "专注等于50仍选择学习")
	_close(simulation.students[0].focus, 49.0, "自然启动后低于50不会立即重选")
	_check(simulation.advance(1.0) == OK, "低于50的已启动学习继续执行")
	_check(simulation.students[0].current_action.action_id == "study", "执行中不会每帧切成发呆")
	simulation.students[0].current_action = {}
	_check(simulation.advance(0.0) == OK, "下一自主决策点重新判断专注")
	_check(simulation.students[0].current_action.action_id == "daydream", "本阶段仅从原权重池选择已开放发呆")
	var initial_focus: float = simulation.students[0].focus
	var knowledge: float = simulation.students[0].knowledge.chinese
	_check(simulation.advance(60.0) == OK, "发呆恢复一分钟")
	_close(simulation.students[0].focus, initial_focus + 1.5, "发呆按当前专注上限比例恢复")
	_close(simulation.students[0].knowledge.chinese, knowledge + 0.2, "发呆保留20%旁听知识")
	simulation.students[0].focus = 0.0
	simulation.students[0].stamina = 5.0
	_check(simulation.start_action(0, "sleep") == OK, "零专注也能免费睡觉")
	_close(simulation.students[0].focus, 0.0, "睡觉发动不产生费用或额外赠送")
	knowledge = simulation.students[0].knowledge.chinese
	_check(simulation.advance(60.0) == OK, "睡觉持续恢复一分钟")
	_close(simulation.students[0].stamina, 8.0, "睡觉体力按上限3%恢复")
	_close(simulation.students[0].focus, 0.5, "睡觉专注按上限0.5%恢复")
	_close(simulation.students[0].knowledge.chinese, knowledge, "睡觉不获得知识")


## 跨课只结算上课的实际秒数，课间恢复不伪造知识增长。
func _test_course_boundary() -> void:
	var simulation := _new_simulation(8.0 * 3600.0 + 44.0 * 60.0 + 50.0)
	_check(simulation.advance(20.0) == OK, "跨第一节下课边界")
	_check(simulation.course_context().kind == "break", "进入真实普通课间")
	_check(simulation.students[0].current_action.action_id == "break_rest", "跨课后动作由树重新选择")
	_close(simulation.students[0].knowledge.chinese, 10.0 / 60.0, "只有课内10秒产生知识")


## 体育课只覆盖开小差候选，低体力睡觉与手动回归体育学习仍走同一棵树。
func _test_physical_distraction() -> void:
	var simulation := _new_simulation(14.0 * 3600.0)
	_check(simulation.course_context().subject_id == "physical", "测试使用真实体育课表")
	_check(simulation.students[0].current_action.action_id == "physical_study", "体育课正常自主学习")
	simulation.students[0].focus = 40.0
	simulation.students[0].current_action = {}
	var candidates: Array[Dictionary] = simulation.get_auto_candidates(0)
	_check(candidates.size() == 1 and candidates[0].action_id == "playground_play", "体育课按单科覆盖过滤原自主池")
	_close(candidates[0].weight, 10.0, "体育候选保留原表权重")
	_check(simulation.advance(0.0) == OK, "体育低专注自主选择")
	_check(simulation.students[0].current_action.action_id == "playground_play", "体育课低专注去操场玩")
	_close(simulation.students[0].focus, 40.0, "去操场玩按已确认配表免发动专注成本")
	var stamina_before: float = simulation.students[0].stamina
	_check(simulation.advance(60.0) == OK, "去操场玩真实执行一分钟")
	_close(simulation.students[0].focus, 43.0, "去操场玩每分钟按上限3%恢复专注")
	_close(simulation.students[0].stamina, stamina_before - 1.0, "去操场玩每分钟消耗1体力")
	_close(simulation.students[0].knowledge.physical, 0.0, "玩耍不增加体育知识")
	_check(simulation.focus_command() == OK, "体育课专注回归当前课程")
	_check(simulation.students[0].current_action.action_id == "physical_study", "专注指令回归体育学习")
	_close(simulation.students[0].focus, 48.0, "专注加5且不重收体育自然启动费")
	_check(simulation.advance(60.0) == OK, "体育学习执行一分钟")
	_close(simulation.students[0].knowledge.physical, 1.2, "体育知识采用原科目增长率")
	simulation.students[0].stamina = 5.0
	simulation.students[0].current_action = {}
	_check(simulation.advance(0.0) == OK, "体育低体力仍可选择免费睡觉")
	_check(simulation.students[0].current_action.action_id == "sleep", "睡觉优先于体育开小差候选")


## 体育低专注可按免发动费的正式配表继续玩耍；保存和改表都不能重开在途动作。
func _test_zero_focus_playground_reload() -> void:
	var simulation: ClassroomSimulation
	for initial in [{"focus": 0.0, "stamina": 20.0}, {"focus": 2.999, "stamina": 50.0}]:
		simulation = _new_simulation(14.0 * 3600.0)
		simulation.students[0].focus = initial.focus
		simulation.students[0].stamina = initial.stamina
		simulation.students[0].current_action = {}
		var candidates: Array[Dictionary] = simulation.get_auto_candidates(0)
		_check(candidates.size() == 1 and candidates[0].action_id == "playground_play", "不足3专注仍只使用体育原有候选，不引入其他兜底动作")
		_check(simulation.advance(0.0) == OK, "低专注体育角色由真实共享树选择动作")
		_check(simulation.students[0].current_action.action_id == "playground_play", "0或2.999专注都能自主去操场玩")
		_close(simulation.students[0].focus, initial.focus, "发动去操场玩不扣专注")
		_close(simulation.students[0].stamina, initial.stamina, "去操场玩不新增体力发动费")
		var instance_id: int = simulation.students[0].current_action.instance_id
		_check(simulation.advance(60.0) == OK, "低专注去操场玩可持续执行一分钟")
		_check(simulation.students[0].current_action.instance_id == instance_id, "持续中不因低资源被额外切换或重启动作")
		_close(simulation.students[0].focus, initial.focus + 3.0, "低专注角色按原费率恢复专注")
		_close(simulation.students[0].stamina, initial.stamina - 1.0, "低专注角色仍支付原有持续体力消耗")
		_close(simulation.students[0].knowledge.physical, 0.0, "去操场玩仍不获得体育知识")
	var original_action: Dictionary = simulation.students[0].current_action.duplicate(true)
	var original_focus: float = simulation.students[0].focus
	var original_rng: int = simulation.rng.state
	var source: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://config/game_config.json"))
	for effect in source.tables.effects:
		if effect.id == "playground_play_tick_1":
			effect.value = 0.04
	for action in source.tables.actions:
		if action.id == "playground_play":
			action.duration_min_s = 30.0
			action.duration_max_s = 40.0
	var config_path: String = "user://core_test_playground_config.json"
	var file := FileAccess.open(config_path, FileAccess.WRITE)
	file.store_string(JSON.stringify(source))
	file.close()
	var changed_config := CONFIG.new()
	_check(changed_config.load_file(config_path) == OK, "去操场玩调整费率和时长的测试配置真实加载")
	_check(simulation.apply_config(changed_config) == OK, "去操场玩在途时可应用新费率")
	_close(simulation.students[0].focus, original_focus, "热更新不重复扣发动费或赠送额外资源")
	_close(simulation.students[0].current_action.ends_at, original_action.ends_at, "热更新不重抽去操场玩的在途结束时刻")
	_check(simulation.students[0].current_action.instance_id == original_action.instance_id and simulation.rng.state == original_rng, "热更新保留去操场玩实例与随机状态")
	_check(simulation.advance(60.0) == OK, "原玩耍时长继续执行新的持续费率")
	_close(simulation.students[0].focus, original_focus + 4.0, "在途玩耍立即采用新恢复费率")
	var save_path: String = "user://core_test_playground_save.json"
	_check(simulation.save_file(save_path) == OK, "保存执行中的去操场玩")
	var restored := SIMULATION.new()
	_check(restored.setup(changed_config, 1) == OK, "去操场玩读档目标初始化")
	_check(restored.load_file(save_path, false) == OK, "真实恢复执行中的去操场玩")
	_close(restored.students[0].focus, simulation.students[0].focus, "读档不重扣发动费或补离线恢复")
	_close(restored.students[0].current_action.ends_at, original_action.ends_at, "读档保留去操场玩的原结束时刻")
	_close(restored.students[0].current_action.duration_s, original_action.duration_s, "读档不采用改表后的新动作时长")
	_check(restored.students[0].current_action.instance_id == original_action.instance_id and restored.rng.state == simulation.rng.state, "读档保留玩耍实例与精确随机状态")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(config_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path))


## 改表保留在途时长与启动结果，存档恢复随机状态且不重抽当前动作。
func _test_config_reload_and_save() -> void:
	var simulation := _new_simulation(8.0 * 3600.0)
	_check(simulation.advance(30.0) == OK, "改表前正常结算30秒")
	var end_before: float = simulation.students[0].current_action.ends_at
	var focus_before: float = simulation.students[0].focus
	var old_save_path: String = "user://core_test_old_config_save.json"
	_check(simulation.save_file(old_save_path) == OK, "改表前按旧配置保存真实进度")
	var source: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://config/game_config.json"))
	for effect in source.tables.effects:
		if effect.id == "study_tick_1":
			effect.value = -2.0
	for action in source.tables.actions:
		if action.id == "study":
			action.duration_min_s = 30.0
			action.duration_max_s = 40.0
	var config_path: String = "user://core_test_config.json"
	var file := FileAccess.open(config_path, FileAccess.WRITE)
	file.store_string(JSON.stringify(source))
	file.close()
	var changed_config := CONFIG.new()
	_check(changed_config.load_file(config_path) == OK, "修改后的真实JSON重新校验")
	var migrated := SIMULATION.new()
	_check(migrated.setup(changed_config, 2) == OK, "新配置下建立读档目标")
	_check(migrated.load_file(old_save_path, false) == OK, "旧配置存档在新配置下恢复")
	_close(migrated.students[0].focus, focus_before, "跨配置读档保留过去结果和启动费")
	_close(migrated.students[0].current_action.ends_at, end_before, "跨配置读档保持旧抽样时长")
	var migrated_controller := CONTROLLER.new()
	root.add_child(migrated_controller)
	migrated_controller.setup(migrated)
	owned_controllers.append(migrated_controller)
	migrated.decision_handler = migrated_controller.decide
	_check(migrated.advance(60.0) == OK, "跨配置读档后执行真实一分钟")
	_close(migrated.students[0].focus, focus_before - 2.0, "旧存档后续结算立即采用新费率")
	_check(simulation.apply_config(changed_config) == OK, "立即接管新数值")
	_close(simulation.students[0].current_action.ends_at, end_before, "在途动作时长保持原抽取结果")
	_close(simulation.students[0].focus, focus_before, "改表不重新收启动费")
	_check(simulation.advance(60.0) == OK, "改表后按新费率执行一分钟")
	_close(simulation.students[0].focus, focus_before - 2.0, "持续消耗立即使用新值")
	var save_path: String = "user://core_test_save.json"
	_check(simulation.save_file(save_path) == OK, "本地状态保存成功")
	_check(simulation.save_file(save_path) == OK, "已有存档可原子替换")
	var restored := SIMULATION.new()
	_check(restored.setup(changed_config, 1) == OK, "读档目标建立成功")
	_check(restored.load_file(save_path, false) == OK, "恢复已保存的真实状态")
	_close(restored.students[0].current_action.ends_at, end_before, "读档不重新抽取时长")
	_close(restored.students[0].focus, simulation.students[0].focus, "读档不增加关闭期间的资源")
	_check(restored.rng.state == simulation.rng.state, "随机状态精确恢复")
	_check(restored.students[0].current_action.instance_id == simulation.students[0].current_action.instance_id, "当前动作实例不变")
	_check(simulation.focus_command() == OK, "改表后的新动作可重新抽时长")
	_check(simulation.students[0].current_action.duration_s >= 30.0 and simulation.students[0].current_action.duration_s <= 40.0, "新动作才使用新时长范围")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(config_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(old_save_path))


## 损坏的权威状态必须在存档入口显式失败，且不能覆盖已存在的有效局。
func _test_snapshot_rejection() -> void:
	var simulation := _new_simulation(8.0 * 3600.0)
	var save_path: String = "user://core_test_corrupt_save.json"
	_check(simulation.save_file(save_path) == OK, "建立真实存档供边界校验")
	var original: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(save_path))
	var cases: Array[Dictionary] = []
	var invalid_rng: Dictionary = original.duplicate(true)
	invalid_rng.rng_state = "invalid"
	cases.append(invalid_rng)
	var invalid_action: Dictionary = original.duplicate(true)
	invalid_action.students[0].current_action.erase("instance_id")
	cases.append(invalid_action)
	var invalid_time: Dictionary = original.duplicate(true)
	invalid_time.students[0].current_action.last_settled_at = 1.0
	cases.append(invalid_time)
	var invalid_resource: Dictionary = original.duplicate(true)
	invalid_resource.students[0].focus = "100"
	cases.append(invalid_resource)
	var invalid_log: Dictionary = original.duplicate(true)
	invalid_log.logs = ["损坏日志"]
	cases.append(invalid_log)
	var original_instance: int = simulation.students[0].current_action.instance_id
	for snapshot in cases:
		var file := FileAccess.open(save_path, FileAccess.WRITE)
		file.store_string(JSON.stringify(snapshot))
		file.close()
		_check(simulation.load_file(save_path, false) != OK, "损坏存档必须明确拒绝")
		_check(simulation.students[0].current_action.instance_id == original_instance, "校验失败不覆盖有效状态")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path))


## 关闭期间只对齐电脑课表；跨课打断旧动作，不奖励未执行的资源和知识。
func _test_system_clock_resume() -> void:
	var now: Dictionary = Time.get_datetime_dict_from_system()
	var now_seconds: float = now.hour * 3600.0 + now.minute * 60.0 + now.second
	var simulation := _new_simulation(now_seconds)
	var previous_clock: float = 8.0 * 3600.0 if simulation.course_context().kind == "outside" else 20.0 * 3600.0
	_check(simulation.set_debug_time(1, previous_clock) == OK, "保存前选取与当前电脑不同的课程上下文")
	_check(simulation.advance(30.0) == OK, "离线验证前只运行真实30秒")
	var old_elapsed: float = simulation.elapsed_s
	var old_focus: float = simulation.students[0].focus
	var old_knowledge: float = simulation.students[0].knowledge.chinese
	var save_path: String = "user://core_test_system_resume.json"
	_check(simulation.save_file(save_path) == OK, "保存另一课时的真实状态")
	var restored := SIMULATION.new()
	_check(restored.setup(simulation.config, 1) == OK, "系统时钟读档目标建立")
	_check(restored.load_file(save_path, true) == OK, "按当前电脑时钟恢复")
	_close(restored.elapsed_s, old_elapsed, "读档不推进实际执行时长")
	_close(restored.students[0].focus, old_focus, "关闭期间没有额外恢复或消耗")
	_close(restored.students[0].knowledge.chinese, old_knowledge, "关闭期间没有额外知识")
	_check(restored.students[0].current_action.is_empty(), "跨课恢复打断旧动作后等待正常自主决策")
	_check(not restored.is_debug_time, "恢复电脑时间后不保留开发模式")
	_check(restored.logs.any(func(entry: Dictionary) -> bool: return entry.type == "interrupt" and entry.message.begins_with("关闭期间跨课")), "跨课打断有明确可见日志")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path))


## 配置入口应拒绝核心参数缺失和科目覆盖枚举错误，不能等待深层结算才失败。
func _test_config_entry_rejection() -> void:
	var source: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://config/game_config.json"))
	for index in range(source.tables.globals.size() - 1, -1, -1):
		if source.tables.globals[index].key == "sleep_stamina_threshold":
			source.tables.globals.remove_at(index)
	var config_path: String = "user://core_test_invalid_config.json"
	var file := FileAccess.open(config_path, FileAccess.WRITE)
	file.store_string(JSON.stringify(source))
	file.close()
	var game_config := CONFIG.new()
	_check(game_config.load_file(config_path) != OK, "缺少核心参数在配置入口拒绝")
	var valid_config := CONFIG.new()
	_check(valid_config.load_file() == OK, "阶段覆盖校验使用正式配置")
	var source_scope: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://config/phase_scope.json"))
	var invalid_subject: Dictionary = source_scope.duplicate(true)
	invalid_subject.subject_auto_actions = {"missing_subject": ["daydream"]}
	var invalid_action: Dictionary = source_scope.duplicate(true)
	invalid_action.subject_auto_actions = {"physical": ["missing_action"]}
	var invalid_array: Dictionary = source_scope.duplicate(true)
	invalid_array.subject_auto_actions = {"physical": "playground_play"}
	var scope_path: String = "user://core_test_invalid_scope.json"
	for scope in [invalid_subject, invalid_action, invalid_array]:
		file = FileAccess.open(scope_path, FileAccess.WRITE)
		file.store_string(JSON.stringify(scope))
		file.close()
		var simulation := SIMULATION.new()
		_check(simulation.setup(valid_config, 1, scope_path) != OK, "无效自主科目覆盖在入口拒绝")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(config_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(scope_path))


## 晚间与课间操使用配表中的真实规则，不假装在晚上听课。
func _test_evening_and_exercise() -> void:
	var evening := _new_simulation(20.0 * 3600.0)
	_check(evening.students[0].current_action.action_id == "dorm_rest", "晚间默认宿舍休息")
	_check(evening.advance(60.0) == OK, "晚间可以持续活动")
	_close(evening.students[0].knowledge.chinese, 0.0, "晚间不伪造课堂知识")
	var exercise := _new_simulation(9.0 * 3600.0 + 40.0 * 60.0)
	_check(exercise.students[0].current_action.action_id == "morning_exercise", "课间操时段执行真实课间操")
	_check(exercise.advance(1200.0) == OK, "完整课间操正常完成")
	_check(exercise.students[0].buffs.size() == 1, "课间操的完成状态不能被忽略")
	_close(exercise.get_resource_max(0, "stamina"), 110.0, "身体舒展增加健康和体力上限")
	_check(exercise.students[0].stamina < 100.0, "上限提高不直接补满资源")
	exercise.students[0].stamina = 105.0
	_check(exercise.advance(600.0) == OK, "独立状态到期")
	_close(exercise.get_resource_max(0, "stamina"), 100.0, "到期后恢复原体力上限")
	_close(exercise.students[0].stamina, 100.0, "状态到期把超出新上限的绝对体力裁去")
	_check(exercise.logs.any(func(entry: Dictionary) -> bool: return entry.type == "resource" and entry.details.resource == "stamina"), "状态到期夹紧资源有明确日志")


## 数值断言只接受误差范围内的真实计算结果。
func _close(actual: float, expected: float, message: String) -> void:
	_check(absf(actual - expected) < 0.000001, "%s：actual=%s expected=%s" % [message, actual, expected])


## 收集失败并最终返回非零退出码，不能吞掉失败继续显示成功。
func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
