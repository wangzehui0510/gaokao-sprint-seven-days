extends SceneTree
## 宿舍二批双人：结伴自习与室友开黑的发起边界、数值结算、自主发起与存档往返。

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
	fixture_root = OS.get_cache_dir().path_join("DormPair_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	if not _result(DirAccess.make_dir_recursive_absolute(fixture_root), "建立独占结伴测试目录"):
		_finish()
		return
	# 本组验证结伴自身规则，不含每日发点；把起始日推到局外隔离每日属性点影响。
	configuration.globals["first_daily_attribute_day"] = 99
	# 事件是独立内容：本组数值基线不含事件干扰，显式关闭保持既有基线。
	configuration.globals["events_enabled"] = false
	if _empty() == null:
		_finish()
		return
	_check(_test_config_contract(), "结伴配置与动作契约完整")
	_check(_test_player_launch_boundaries(), "玩家发起边界场景完整执行")
	_check(_test_study_together_settlement(), "结伴自习数值结算场景完整执行")
	_check(_test_roommate_game_settlement(), "室友开黑数值结算场景完整执行")
	_check(_test_npc_auto_launch(), "NPC自主发起场景完整执行")
	_check(_test_busy_target_refusal(), "不打扰正忙同学场景完整执行")
	_check(_test_roundtrip_and_boundary(), "存档往返与时段边界场景完整执行")
	_check(_test_together_visuals(), "同桌表现场景完整执行")
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


## 定位到宿舍自由时段（17:00课表外）的真实局；不做advance避免行为树先开动作产生孤儿互动。
func _at_dorm_free(at_day: int, seed_value: int = 261109) -> ClassroomSimulation:
	var simulation := _empty(seed_value)
	if simulation == null:
		return null
	if not _result(simulation.set_debug_time(at_day, 61200.0), "定位宿舍自由时段", simulation.error_message):
		return null
	if not _check(simulation.course_context().kind == "outside", "定位处于课表外自由时段"):
		return null
	return simulation


## 把全部同学动作清空，制造可结伴的空闲目标；配合隔离结伴候选后夹具无互动孤儿。
func _free_others(simulation: ClassroomSimulation, initiator_index: int) -> void:
	for index in simulation.students.size():
		simulation.students[index].current_action = {}


## 数值与边界算例隔离结伴候选：行为树决策只开个人活动，结伴由用例显式发起。
func _isolate_auto_pair(simulation: ClassroomSimulation) -> void:
	simulation.phase_scope.dorm_auto_actions = ["dorm_study", "dorm_practice", "dorm_game", "dorm_workout", "dorm_wash", "dorm_rest"]


## 配置契约：两个pair动作、效果表数值、自主池行与阶段开放。
func _test_config_contract() -> bool:
	var study: Dictionary = configuration.actions.get("study_together", {})
	var game: Dictionary = configuration.actions.get("roommate_game", {})
	if not _check(not study.is_empty() and not game.is_empty(), "权威配置存在两个宿舍结伴动作"):
		return false
	for field: String in ["target", "scene", "eligible_period", "source"]:
		_check(String(study.get(field)) == String(game.get(field)), "结伴动作%s契约一致" % field)
	for field: String in ["duration_min_s", "duration_max_s"]:
		_check(is_equal_approx(float(study.get(field)), float(game.get(field))), "结伴动作%s时长契约一致" % field)
	_check(String(study.target) == "pair" and String(study.scene) == "dorm" and String(study.eligible_period) == "dorm_free", "结伴自习是宿舍自由时段双人持续动作")
	_check(String(study.source) == "both" and String(game.source) == "both", "结伴动作玩家与自主双来源开放")
	_check(is_equal_approx(float(study.knowledge_multiplier), 1.15), "结伴自习按基础自习1.15倍记知识")
	_check(String(study.knowledge_mode) == "selected_subject", "结伴自习由发起者显式选科")
	_check(String(game.knowledge_mode) == "none", "室友开黑不产生知识")
	# 效果表：结伴自习双方每分钟-0.8专注-0.25体力；开黑每分钟+3.5%专注上限-0.5体力。
	var study_effects: Array = configuration.phase_effects("study_together", "tick")
	_check(study_effects.size() == 2, "结伴自习两条持续效果")
	for effect: Dictionary in study_effects:
		var expected: float = -0.8 if String(effect.resource) == "focus" else -0.25
		_check(String(effect.recipient) == "both" and String(effect.mode) == "flat" and is_equal_approx(float(effect.value), expected) and int(effect.period_s) == 60, "结伴自习每分钟%s数值正确" % String(effect.resource))
	var game_effects: Array = configuration.phase_effects("roommate_game", "tick")
	_check(game_effects.size() == 2, "室友开黑两条持续效果")
	for effect: Dictionary in game_effects:
		if String(effect.resource) == "focus":
			_check(String(effect.recipient) == "both" and String(effect.mode) == "max_ratio" and is_equal_approx(float(effect.value), 0.035), "开黑每分钟恢复3.5%专注上限")
		else:
			_check(String(effect.recipient) == "both" and String(effect.mode) == "flat" and is_equal_approx(float(effect.value), -0.5), "开黑每分钟消耗0.5体力")
	# 自主池：两个结伴候选必须声明同场景同伴。
	for row: Dictionary in configuration.tables.auto_pool:
		if String(row.action_id) in ["study_together", "roommate_game"]:
			_check(String(row.eligible_period) == "dorm_free" and bool(row.requires_same_scene_target), "结伴候选%s声明同场景同伴" % String(row.action_id))
	_check("study_together" in configuration.phase_scope.enabled_actions and "roommate_game" in configuration.phase_scope.enabled_actions, "阶段范围开放两个结伴动作")
	return true


## 玩家发起边界：时段、选科与空闲目标校验，个人入口对pair动作一律拒绝。
func _test_player_launch_boundaries() -> bool:
	var ok: bool = true
	# 个人入口不能发起pair动作。
	var simulation := _at_dorm_free(1)
	if simulation == null:
		return false
	_isolate_auto_pair(simulation)
	_free_others(simulation, 0)
	ok = _check(simulation.start_action(0, "study_together", false, -1, "个人入口验证", "math") != OK, "个人动作入口不能发起结伴自习") and ok
	ok = _check(not simulation.interaction_unavailable_reason(0, 1, "study_together", "").is_empty(), "结伴自习缺少选科被拒绝") and ok
	ok = _check(not simulation.interaction_unavailable_reason(0, 1, "study_together", "physical").is_empty(), "结伴自习不接受体育") and ok
	ok = _check(not simulation.interaction_unavailable_reason(0, 1, "roommate_game", "math").is_empty(), "开黑不接受选科") and ok
	ok = _check(simulation.can_start_interaction(0, 1, "study_together", "math"), "空闲目标与有效选科下结伴可发起") and ok
	# 课中发起被时段校验拒绝。
	var lesson := _at_lesson()
	if lesson == null:
		return false
	ok = _check(not lesson.can_start_interaction(0, 1, "study_together", "math"), "课中不能发起宿舍结伴") and ok
	return ok


## 定位到第一节课内的真实局。
func _at_lesson() -> ClassroomSimulation:
	var simulation := _empty()
	if simulation == null:
		return null
	if not _result(simulation.set_debug_time(1, 30000.0), "定位第一节课内", simulation.error_message):
		return null
	if not _result(simulation.advance(0.0), "真实行为树开始当前时段", simulation.error_message):
		return null
	if not _check(simulation.course_context().kind == "lesson", "定位处于课内"):
		return null
	return simulation


## 结伴自习数值：双方各按1.15倍自习记宿舍账本，专注体力按分钟结算。
func _test_study_together_settlement() -> bool:
	var ok: bool = true
	var simulation := _at_dorm_free(1)
	if simulation == null:
		return false
	_isolate_auto_pair(simulation)
	_free_others(simulation, 0)
	var before_knowledge: Array = []
	for student: Dictionary in simulation.students:
		# 三科知识拉平消除弱科差异，注意力归零消除属性加成，双方都按1.15倍基础自习精确记账。
		student.attributes.attention = 0.0
		for subject: String in ["chinese", "math", "english", "physical"]:
			student.knowledge[subject] = 100.0
		before_knowledge.append(float(student.knowledge.chinese))
	ok = _result(simulation.start_interaction(0, 1, "study_together", "", "chinese", "结伴数值验证"), "真实发起结伴自习", simulation.error_message)
	if not ok:
		return false
	var interaction: Dictionary = simulation.interactions.back()
	ok = _check(String(interaction.action_id) == "study_together" and int(interaction.initiator_index) == 0 and int(interaction.target_index) == 1, "结伴互动身份正确") and ok
	for index in [0, 1]:
		ok = _check(String(simulation.students[index].current_action.action_id) == "study_together" and String(simulation.students[index].current_action.subject_id) == "chinese", "双方动作保存发起者选科") and ok
	# 推进三分钟：双方各+3.45结伴知识、-2.4专注、-0.75体力（ dorm_free tick ）。
	if not _result(simulation.advance(180.0), "推进三分钟结伴", simulation.error_message):
		return false
	for index in [0, 1]:
		var gain: float = float(simulation.students[index].knowledge.chinese) - before_knowledge[index]
		ok = _check(absf(gain - 3.45) < 1.0e-6, "第%d人结伴三分钟知识等于1.15倍自习" % index) and ok
		ok = _check(absf(float(simulation.students[index].focus) - (100.0 - 2.4)) < 1.0e-6, "第%d人结伴三分钟专注消耗正确" % index) and ok
		ok = _check(absf(float(simulation.students[index].stamina) - (100.0 - 0.75)) < 1.0e-6, "第%d人结伴三分钟体力消耗正确" % index) and ok
	# 完成后双方回到宿舍自由决策，不残留互动占用。
	if not _result(simulation.advance(900.0 - 180.0 + 1.0), "推进到结伴完成", simulation.error_message):
		return false
	ok = _check(String(interaction.action_id) == "study_together" and interaction.status == "completed", "结伴互动真实完成") and ok
	for index in [0, 1]:
		var action: Dictionary = simulation.students[index].current_action
		ok = _check(action.is_empty() or not action.has("interaction_id") or String(action.action_id) != "study_together", "第%d人完成后不再停留结伴" % index) and ok
	# 知识记入宿舍账本：get_dorm_summary存在结伴自习来源。
	var summary: Dictionary = simulation.get_dorm_summary(1, 0)
	ok = _check(not summary.is_empty(), "结伴知识进入宿舍账本") and ok
	return ok


## 室友开黑数值：每分钟+3.5%专注上限-0.5体力，无知识。
func _test_roommate_game_settlement() -> bool:
	var ok: bool = true
	var simulation := _at_dorm_free(1, 817233)
	if simulation == null:
		return false
	_isolate_auto_pair(simulation)
	_free_others(simulation, 0)
	var focus_max: float = simulation.get_resource_max(0, "focus")
	simulation.students[0].focus = 40.0
	simulation.students[1].focus = 40.0
	if not _result(simulation.start_interaction(0, 1, "roommate_game", "", "", "开黑数值验证"), "真实发起室友开黑", simulation.error_message):
		return false
	if not _result(simulation.advance(120.0), "推进两分钟开黑", simulation.error_message):
		return false
	for index in [0, 1]:
		# 开黑按各自当前专注上限恢复3.5%每分钟。
		var expected_focus: float = 40.0 + simulation.get_resource_max(index, "focus") * 0.07
		ok = _check(absf(float(simulation.students[index].focus) - expected_focus) < 1.0e-6, "第%d人开黑两分钟恢复7%%专注上限" % index) and ok
		ok = _check(absf(float(simulation.students[index].stamina) - (100.0 - 1.0)) < 1.0e-6, "第%d人开黑两分钟消耗1体力" % index) and ok
	var knowledge_total: float = 0.0
	for index in [0, 1]:
		for subject: String in ["chinese", "math", "english", "physical"]:
			knowledge_total += float(simulation.students[index].knowledge[subject])
	ok = _check(knowledge_total < 1.0e-6, "开黑全程无知识收益") and ok
	return ok


## NPC自主发起：候选按同学枚举；强制池后NPC在宿舍自由时段真实结伴且完成率高。
func _test_npc_auto_launch() -> bool:
	var ok: bool = true
	var simulation := _at_dorm_free(1, 940137)
	if simulation == null:
		return false
	# 候选强制含保底休息与两个结伴：无空闲同伴时回落休息，不会出现无候选决策。
	_free_others(simulation, 0)
	simulation.phase_scope.dorm_auto_actions = ["dorm_rest", "study_together", "roommate_game"]
	if not _result(simulation.advance(600.0), "推进十分钟触发NPC结伴", simulation.error_message):
		return false
	var pair_interactions: Array = simulation.interactions.filter(func(entry: Dictionary): return String(entry.action_id) in ["study_together", "roommate_game"])
	ok = _check(not pair_interactions.is_empty(), "强制候选下NPC真实发起结伴互动") and ok
	if pair_interactions.is_empty():
		return false
	var first: Dictionary = pair_interactions[0]
	# 强制池下四人行为树都会决策：任意空闲角色真实发起、目标是别人即验证自主通道。
	ok = _check(int(first.target_index) != int(first.initiator_index), "自主结伴真实发起且目标是别人") and ok
	# 目标空闲才可结伴：正在互动中的同学不能被新的结伴拉走。
	var busy_target: int = int(first.target_index)
	for other in simulation.students.size():
		if other != int(first.initiator_index) and other != busy_target:
			var reason: String = simulation.interaction_unavailable_reason(other, busy_target, "roommate_game", "")
			ok = _check(reason.contains("正忙"), "正在结伴的同学不被再次拉走") and ok
			break
	# 真实跑完宿舍自由时段：结伴完成率显著，不被互相打断清零。
	if not _result(simulation.advance(86400.0 - 61200.0 - 120.0), "推进到当天结束", simulation.error_message):
		return false
	var completed: int = 0
	for entry: Dictionary in simulation.interactions:
		if String(entry.action_id) in ["study_together", "roommate_game"] and String(entry.status) == "completed":
			completed += 1
	ok = _check(completed >= 1, "自主结伴存在真实完成记录") and ok
	return ok


## 不打扰正忙同学：目标在做个人宿舍活动时结伴被拒，空闲后才可结伴。
func _test_busy_target_refusal() -> bool:
	var ok: bool = true
	var simulation := _at_dorm_free(1, 261109)
	if simulation == null:
		return false
	_isolate_auto_pair(simulation)
	_free_others(simulation, 0)
	# 1号先进入个人宿舍活动；0号尝试拉其结伴被拒。
	if not _result(simulation.start_action(1, "dorm_practice", false, -1, "目标先自习", "math"), "目标进入自习", simulation.error_message):
		return false
	var busy_reason: String = simulation.interaction_unavailable_reason(0, 1, "roommate_game", "")
	ok = _check(busy_reason.contains("正忙"), "正忙目标拒绝结伴：%s" % busy_reason) and ok
	simulation.students[1].current_action = {}
	ok = _check(simulation.can_start_interaction(0, 1, "roommate_game", ""), "目标空闲后结伴可发起") and ok
	return ok


## 存档往返：在途结伴随档恢复；宿舍契约字段随互动保存；换课边界强制回课表。
func _test_roundtrip_and_boundary() -> bool:
	var ok: bool = true
	var simulation := _at_dorm_free(1, 711027)
	if simulation == null:
		return false
	_isolate_auto_pair(simulation)
	_free_others(simulation, 0)
	if not _result(simulation.start_interaction(0, 1, "study_together", "", "math", "在途存档验证"), "真实发起在途结伴", simulation.error_message):
		return false
	if not _result(simulation.advance(300.0), "推进五分钟产生在途状态", simulation.error_message):
		return false
	var save_path: String = fixture_root.path_join("pair_save.json")
	if not _result(simulation.save_file(save_path), "保存结伴在途存档", simulation.error_message):
		return false
	var restored := _empty()
	if restored == null:
		return false
	if not _result(restored.load_file(save_path, false), "读取结伴在途存档", restored.error_message):
		return false
	var action: Dictionary = restored.students[0].current_action
	ok = _check(String(action.action_id) == "study_together" and String(action.subject_id) == "math" and bool(action.get("dorm_recovery", true)) == false, "读档保留结伴在途动作、选科与恢复契约") and ok
	if not _result(restored.advance(700.0), "读档后推进到完成", restored.error_message):
		return false
	var interaction: Dictionary = restored.interactions.back()
	ok = _check(String(interaction.action_id) == "study_together" and interaction.status == "completed", "读档后结伴真实完成") and ok
	# 时段边界：结伴进行中跨越次日上午课开始被强制回课表（课表外自由时段持续到次日上课）。
	var boundary := _at_dorm_free(2, 940137)
	if boundary == null:
		return false
	_isolate_auto_pair(boundary)
	_free_others(boundary, 0)
	if not _result(boundary.start_interaction(0, 1, "roommate_game", "", "", "边界验证"), "真实发起边界结伴", boundary.error_message):
		return false
	if not _result(boundary.advance(86400.0 - 61200.0 + 30000.0), "推进跨过次日上午课开始", boundary.error_message):
		return false
	var context: Dictionary = boundary.course_context()
	ok = _check(context.kind == "lesson", "边界后回到课表") and ok
	for index in [0, 1]:
		var action_after: Dictionary = boundary.students[index].current_action
		ok = _check(action_after.is_empty() or String(action_after.action_id) != "roommate_game", "第%d人结伴被换课清理" % index) and ok
	return ok


## 同桌表现：结伴互动中两人渲染到同桌脚点（宿舍并排中点、教室合作移到发起方桌子），不画连线。
func _test_together_visuals() -> bool:
	var ok: bool = true
	var simulation := _at_dorm_free(1, 261109)
	if simulation == null:
		return false
	_isolate_auto_pair(simulation)
	_free_others(simulation, 0)
	if not _result(simulation.start_interaction(0, 1, "roommate_game", "", "", "同桌表现验证"), "真实发起开黑", simulation.error_message):
		return false
	var room := ClassroomView.new()
	room.size = Vector2(384, 256)
	root.add_child(room)
	room.set_process(false)
	room.bind_game(simulation)
	room._update_geometry()
	room.set_view_location("dorm")
	# 宿舍开黑：双方并排到两人锚点中点两侧，不再各留原座位。
	var anchor0: Vector2 = CampusSceneRenderer.student_anchor("dorm", 0)
	var anchor1: Vector2 = CampusSceneRenderer.student_anchor("dorm", 1)
	var middle: Vector2 = (anchor0 + anchor1) * 0.5
	ok = _check(room._together_foot(0).is_equal_approx(middle + Vector2(-32.0, 0.0)), "开黑中发起者在中点左侧为完整电脑工位留宽") and ok
	ok = _check(room._together_foot(1).is_equal_approx(middle + Vector2(32.0, 0.0)), "开黑中目标在中点右侧，双方电脑家具不重叠") and ok
	ok = _check(room._together_foot(2).is_equal_approx(CampusSceneRenderer.student_anchor("dorm", 2)), "未参与同学保持原座位") and ok
	# 结束后回原座位。
	simulation.students[1].current_action = {}
	simulation.interactions.back().status = "interrupted"
	ok = _check(room._together_foot(0).is_equal_approx(anchor0), "互动结束后发起者回原座位") and ok
	room.queue_free()
	# 教室合作：一起解题时目标画到发起方桌子旁。
	var lesson := _at_lesson()
	if lesson == null:
		return false
	_free_others(lesson, 0)
	if not _result(lesson.start_interaction(0, 2, "solve_together", "", "", "教室同桌验证"), "真实发起一起解题", lesson.error_message):
		return false
	var class_room := ClassroomView.new()
	class_room.size = Vector2(384, 256)
	root.add_child(class_room)
	class_room.set_process(false)
	class_room.bind_game(lesson)
	class_room._update_geometry()
	var class_anchor0: Vector2 = CampusSceneRenderer.student_anchor("classroom", 0)
	var side: float = 28.0 if CampusSceneRenderer.student_anchor("classroom", 2).x >= class_anchor0.x else -28.0
	ok = _check(class_room._together_foot(2).is_equal_approx(class_anchor0 + Vector2(side, 0.0)), "教室合作目标移到发起方桌子旁") and ok
	ok = _check(class_room._together_foot(0).is_equal_approx(class_anchor0), "教室合作发起者留在原座位") and ok
	# 同桌互动不画连线飞行物，其他互动保持连线。
	ok = _check(class_room.visual_interactions.is_empty() or class_room.visual_interactions.all(func(visual: Dictionary): return String(visual.action_id) != "solve_together" or visual.get("progress", 1.0) >= 1.0), "同桌互动不产生连线") and ok
	class_room.queue_free()
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
		print("DORM_PAIR_TEST_PASS checks=%d" % checks)
		quit(0)
	else:
		for message: String in failures:
			push_error(message)
		print("DORM_PAIR_TEST_FAIL checks=%d failures=%d fixtures=%s" % [checks, failures.size(), fixture_root])
		quit(1)


## 本组写入的临时文件清单。
func fixture_files_list() -> Array[String]:
	return [fixture_root.path_join("pair_save.json")]
