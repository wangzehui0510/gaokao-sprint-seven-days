extends SceneTree
## AI验收通过真实四棵行为树、课表和唯一执行器推进，不预填资源、知识或互动结果。

const SOCIAL_IDS: Array[String] = ["borrow_notes", "swap_book", "invite_playground", "invite_canteen", "arm_wrestle", "eraser_prank"]
const SUBJECTS: Array[String] = ["chinese", "math", "english", "physical"]
# 独占目录仅存配置副本及验证存档，正式配置和玩家进度不参与写入。
var fixture_root: String = ""
var fixture_files: Array[String] = []
var controllers: Array[ClassroomBehaviorController] = []
var checks: int = 0
var failures: Array[String] = []


## 等待场景树初始化完成后接入生产行为树。
func _initialize() -> void:
	call_deferred("_run")


## 每个场景必须完整返回；运行时异常不能跳过断言后误报成功。
func _run() -> void:
	fixture_root = OS.get_cache_dir().path_join("ClassroomAiIntegration_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	if not _result(DirAccess.make_dir_recursive_absolute(fixture_root), "建立AI独占验证目录"):
		_finish()
		return
	_check(_test_classroom_tree(), "课堂三候选通过真实行为树选择并保持在途实例")
	_check(_test_six_social_actions(), "六项竞争互动通过树自主发起并产生真实结果")
	_check(_test_manual_and_competing_takeover(), "本人指令保持优先且对手仍可按竞争规则打断")
	_check(_test_boundaries_and_depletion(), "资源耗尽、低体力、换课和终局边界完整执行")
	_check(_test_save_replay_and_legacy(), "自主互动在途往返和旧档保留已分配属性")
	_check(_test_hot_reload_atomicity(), "AI热改保留在途动作且不兼容修改原子拒绝")
	_check(_test_step_equivalence(), "大步小步跨夜及课堂竞争保持相同权威结果")
	_finish()


## 每个局读取独立配置对象，再按正式蓝图创建四棵树。
func _empty(seed_value: int = 261109, config_path: String = "res://config/game_config.json", scope_path: String = "res://config/phase_scope.json") -> ClassroomSimulation:
	var configuration := GameConfig.new()
	if not _result(configuration.load_file(config_path), "加载AI真实配置", configuration.error_message):
		return null
	# 本组验证行为树与互动历史，不含每日发点；把起始日推到局外隔离每日属性点影响。
	configuration.globals["first_daily_attribute_day"] = 99
	# 事件是独立内容：本组数值基线不含事件干扰，显式关闭保持既有基线。
	configuration.globals["events_enabled"] = false
	var simulation := ClassroomSimulation.new()
	if not _result(simulation.setup(configuration, seed_value, scope_path), "建立AI四人真实局", simulation.error_message):
		return null
	var controller := ClassroomBehaviorController.new()
	root.add_child(controller)
	controller.setup(simulation)
	controllers.append(controller)
	simulation.decision_handler = controller.decide
	_check(controller.trees.size() == 4, "四名角色各自接入真实行为树")
	return simulation


## 开发时钟只定位验证入口，角色收益仍由后续真实推进产生。
func _at(seed_value: int, test_day: int, seconds: float, config_path: String = "res://config/game_config.json", scope_path: String = "res://config/phase_scope.json", start_now: bool = true) -> ClassroomSimulation:
	var simulation := _empty(seed_value, config_path, scope_path)
	if simulation == null or not _result(simulation.set_debug_time(test_day, seconds), "定位AI验证时钟", simulation.error_message):
		return null
	if start_now and not _result(simulation.advance(0.0), "四棵树真实选择当前动作", simulation.error_message):
		return null
	return simulation


## 课堂候选用真实启动费用降低专注，固定种子集合必须实际覆盖三项。
func _test_classroom_tree() -> bool:
	var source_path: String = _config("classroom_no_social.json", {"social_auto_base": 0.0})
	if source_path.is_empty():
		return false
	var seen: Dictionary = {}
	for sample in 32:
		var simulation := _at(41000 + sample, 1, 28800.0, source_path, "res://config/phase_scope.json", false)
		if simulation == null:
			return false
		for press in 56:
			if not _result(simulation.start_action(0, "study"), "实际开始学习扣启动专注", simulation.error_message):
				return false
		_check(simulation.students[0].focus < simulation.distraction_threshold(0), "真实启动费用使本人进入低专注条件")
		if not _result(simulation.set_debug_time(1, 28800.0), "同刻结束旧学习等待树决策", simulation.error_message) or not _result(simulation.advance(0.0), "低专注角色由真实树选择", simulation.error_message):
			return false
		var action: Dictionary = simulation.students[0].current_action.duplicate(true)
		_check(action.action_id in ["daydream", "read_comic", "bathroom"], "课堂树只提交真实开放的低专注候选")
		seen[action.action_id] = true
		var before_rng: String = str(simulation.rng.state)
		if not _result(simulation.advance(0.0), "无时间重复推进", simulation.error_message):
			return false
		_check(simulation.students[0].current_action == action and str(simulation.rng.state) == before_rng, "当前实例继续运行，不按树tick重复抽取")
		_release(simulation)
	_check(seen.size() == 3, "确定种子集合实际覆盖发呆、漫画和厕所")
	return true


## 单项自主池和确定触发率只是显式配置夹具，互动效果仍由正式执行器真实完成。
func _test_six_social_actions() -> bool:
	var source_path: String = _config("social_certain.json", {"social_auto_base": 1.0, "g_game": 0.0})
	var quiet_path: String = _config("social_completion_quiet.json", {"social_auto_base": 0.0, "g_game": 0.0})
	if source_path.is_empty() or quiet_path.is_empty():
		return false
	for action_id: String in SOCIAL_IDS:
		var scope_path: String = _scope(action_id + "_scope.json", [action_id])
		var simulation := _at(51521, 1, 28800.0, source_path, scope_path)
		if simulation == null:
			return false
		if not _check(not simulation.interactions.is_empty(), "非空课堂候选通过树真正发起：" + action_id):
			return false
		var active: Array = simulation.interactions.filter(func(interaction: Dictionary) -> bool: return interaction.status == "active")
		if not _check(not active.is_empty(), "自主接管后仍有实际执行中的互动：" + action_id):
			return false
		var started: Dictionary = active.back().duplicate(true)
		_check(started.action_id == action_id and started.status == "active", "实际自主记录匹配唯一竞争候选：" + action_id)
		_check(started.initiator_index != started.target_index, "自主互动双方确实不同")
		_check(simulation.students[started.initiator_index].current_action.get("interaction_id") == started.interaction_id, "自主提交接管真实动作实例")
		_check(simulation.logs.any(func(entry: Dictionary) -> bool: return entry.type == "interaction_start" and entry.details.interaction_id == started.interaction_id and entry.details.get("reason") == "自主干扰"), "真实日志明确区分自主干扰和玩家主动互动")
		if action_id in ["invite_playground", "invite_canteen"]:
			var expected_location: String = "playground" if action_id == "invite_playground" else "canteen"
			_check(simulation.student_location(int(started.initiator_index)) == expected_location and simulation.student_location(int(started.target_index)) == expected_location, "自主邀请真实改变双方地点")
		if action_id == "swap_book":
			_check(started.selected_subject_id in ["math", "english"], "课堂偷换真实选择不同于授课语文的科目")
		if action_id == "arm_wrestle":
			_check(started.stamina_snapshot.size() == 2, "自主掰手腕保存真实扣费前双方体力")
		# 自主发起已被真实记录；关闭后续发起率以隔离完成效果，避免合法的新竞争在长动作期间打断本例。
		var quiet := GameConfig.new()
		if not _result(quiet.load_file(quiet_path), "加载完成效果隔离配置", quiet.error_message) or not _result(simulation.apply_config(quiet), "在途保持并关闭新的自主竞争", simulation.error_message):
			return false
		# 先固定其他角色的真实学习指令，完整保留第一项自主互动，使完成效果可以独立核对。
		var participants: Array = [int(started.initiator_index), int(started.target_index)]
		for index in 4:
			if index not in participants:
				if not _result(simulation.start_action(index, "study", false), "其他角色保持实际学习", simulation.error_message):
					return false
		var remaining: float = float(started.ends_at) - simulation.elapsed_s
		if not _result(simulation.advance(remaining), "自主互动真实执行完整时长：" + action_id, simulation.error_message):
			return false
		var completed: Dictionary = _interaction(simulation, int(started.interaction_id))
		_check(completed.status == "completed", "完整自主互动留下真实完成记录：" + action_id)
		_close(completed.finished_at, started.ends_at, "自主互动在真实结束秒数完成")
		if action_id == "arm_wrestle":
			_check(not completed.result.is_empty(), "自主掰手腕完成后才产生真实胜负结果")
		if action_id == "swap_book":
			_check(_has_buff(simulation, int(started.target_index), "wrong_book"), "自主偷换完成后真实施加错误课本")
		_check(simulation.notes.is_empty(), "竞争自主池不擅自生成纸条内容")
		_release(simulation)
	return true


## 本人主动动作不会被本人的树重选；竞争者仍能通过同一入口接管在线人物。
func _test_manual_and_competing_takeover() -> bool:
	var certain_path: String = _config("manual_competition.json", {"social_auto_base": 1.0, "g_game": 0.0})
	var scope_path: String = _scope("manual_competition_scope.json", ["eraser_prank"])
	if certain_path.is_empty() or scope_path.is_empty():
		return false
	var taken_over: bool = false
	for sample in 16:
		var simulation := _at(62000 + sample, 1, 28800.0, certain_path, scope_path, false)
		if simulation == null or not _result(simulation.start_action(0, "read_comic", false), "本人真实开始主动漫画", simulation.error_message):
			return false
		var manual: Dictionary = simulation.students[0].current_action.duplicate(true)
		var before_rng: String = str(simulation.rng.state)
		simulation.decision_handler.call(0)
		_check(simulation.students[0].current_action == manual and str(simulation.rng.state) == before_rng, "本人树继续当前手动实例且不重新抽数")
		if not _result(simulation.advance(0.0), "其他角色真实竞争决策", simulation.error_message):
			return false
		for interaction: Dictionary in simulation.interactions:
			if int(interaction.target_index) == 0:
				taken_over = true
				_check(int(interaction.initiator_index) != 0, "在线角色确实被其他角色竞争接管")
		_check(simulation.students.all(func(student: Dictionary) -> bool: return not student.current_action.is_empty()), "竞争接管后四人均有真实动作，不留下递归空状态")
		_release(simulation)
	_check(taken_over, "固定种子集合实际发生过对在线本人的竞争打断")
	return true


## 真实健身消耗体力到零，再验证恢复、低体力优先级及课表/终局清理。
func _test_boundaries_and_depletion() -> bool:
	var simulation := _at(71000, 1, 61200.0)
	if simulation == null:
		return false
	for repeat in 5:
		if not _result(simulation.start_action(0, "dorm_workout", false), "真实健身消耗体力", simulation.error_message) or not _result(simulation.advance(600.0), "执行十分钟真实健身", simulation.error_message):
			return false
	_close(simulation.students[0].stamina, 0.0, "五段真实健身后体力归零")
	_check(simulation.students[0].current_action.action_id == "dorm_rest" and simulation.students[0].current_action.dorm_recovery, "耗尽边界进入十分钟恢复实例")
	_check(simulation.get_dorm_candidates(0).all(func(candidate: Dictionary) -> bool: return candidate.action_id in ["dorm_wash", "dorm_rest"]), "零体力候选只包含真实可执行恢复活动")
	if not _result(simulation.set_debug_time(1, 28800.0), "显式定位课堂以验收低体力优先级", simulation.error_message):
		return false
	# 单独决策本人先核对分支优先级；其他角色随后仍可按竞争规则打断睡眠。
	simulation.decision_handler.call(0)
	_check(simulation.students[0].current_action.action_id == "sleep", "低体力睡觉优先于竞争互动")
	_release(simulation)
	var certain_path: String = _config("boundary_social.json", {"social_auto_base": 1.0, "g_game": 0.0})
	var scope_path: String = _scope("boundary_social_scope.json", ["borrow_notes"])
	var boundary := _at(71001, 1, 31499.0, certain_path, scope_path)
	if boundary == null or not _check(not boundary.interactions.is_empty(), "下课前确实建立自主竞争互动"):
		return false
	var original: Array = boundary.interactions.duplicate(true)
	if not _result(boundary.advance(1.0), "真实跨过08:45下课边界", boundary.error_message):
		return false
	_check(boundary.course_context().subject_kind != "knowledge", "边界后为真实非知识课时段")
	for interaction: Dictionary in original:
		_check(_interaction(boundary, int(interaction.interaction_id)).status == "interrupted", "课表切换取消未完成自主互动")
	var count_after: int = boundary.interactions.size()
	if not _result(boundary.advance(60.0), "下课后继续真实一分钟", boundary.error_message):
		return false
	_check(boundary.interactions.size() == count_after, "非知识课不会再次发起自主竞争")
	_release(boundary)
	var terminal := _at(71002, 7, 59999.0, certain_path, scope_path)
	if terminal == null or not _result(terminal.advance(1.0), "真实到第七天16:40终局", terminal.error_message):
		return false
	_check(terminal.is_round_finished() and terminal.students.all(func(student: Dictionary) -> bool: return student.current_action.is_empty()), "终局结束四人真实动作")
	var final_state: Dictionary = _state(terminal)
	if not _result(terminal.advance(86400.0), "终局继续推进明确冻结", terminal.error_message):
		return false
	_check(_same(_state(terminal), final_state), "终局不再产生AI动作、资源、账本或随机消耗")
	_release(terminal)
	return true


## 生产存档恢复在途AI互动；旧版格式只剥离当时不存在的账本，不伪造养成结果。
func _test_save_replay_and_legacy() -> bool:
	var certain_path: String = _config("saved_social.json", {"social_auto_base": 1.0, "g_game": 0.0})
	var scope_path: String = _scope("saved_social_scope.json", ["arm_wrestle"])
	var source := _at(81000, 1, 28800.0, certain_path, scope_path)
	if source == null or not _result(source.allocate_attribute("attention", 8), "实际分配本人八点属性", source.error_message):
		return false
	if not _check(not source.interactions.is_empty(), "存档前确有自主发起互动") or not _result(source.advance(7.0), "自主互动真实执行七秒", source.error_message):
		return false
	var path: String = _path("active_ai_save.json")
	if not _result(source.save_file(path), "保存真实自主互动在途局", source.error_message):
		return false
	fixture_files.append(path)
	var restored := _empty(999, certain_path, scope_path)
	if restored == null or not _result(restored.load_file(path, false), "生产入口恢复自主互动", restored.error_message):
		return false
	_check(_same(_state(source), _state(restored)), "恢复保留动作、属性、快照、随机流及来源账本")
	for seconds in [113.0, 300.0, 600.0]:
		if not _result(source.advance(seconds), "原局真实继续AI", source.error_message) or not _result(restored.advance(seconds), "读档局同样继续AI", restored.error_message):
			return false
		_check(_same(_state(source), _state(restored)), "原局与恢复局后续真实行为和随机流一致")
	var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	saved.save_version = 3
	saved.erase("round_progression")
	# v3没有教师抽查、每日纪律分与每日属性点，旧档夹具必须移除v5/v6字段，保留真实属性和互动。
	saved.erase("inspection")
	saved.erase("daily_points")
	saved.erase("npc_growth")
	# 每日属性点与抢答检查点状态同属v6，旧档夹具一并剔除。
	saved.erase("challenge_auto")
	# 课间磨蹭状态同属v6，旧档夹具一并剔除。
	saved.erase("linger_auto")
	for student: Dictionary in saved.students:
		student.erase("daily_discipline")
		student.erase("daily_discipline_day")
	var legacy_path: String = _path("legacy_v3_ai.json")
	if not _write_json(legacy_path, saved):
		return false
	var legacy := _empty(998, certain_path, scope_path)
	if legacy == null or not _result(legacy.load_file(legacy_path, false), "迁移既有v3属性及真实互动", legacy.error_message):
		return false
	for index in 4:
		_check(_same(legacy.students[index].attributes, saved.students[index].attributes) and legacy.students[index].unspent_points == saved.students[index].unspent_points, "v3迁移保留本人和占位角色属性，不重新套预设或赠点")
	_check(str(legacy.rng.state) == str(saved.rng_state) and _same(legacy.interactions, saved.interactions), "旧档迁移不重抽AI选择或在途快照")
	_release(source)
	_release(restored)
	_release(legacy)
	return true


## 合法倾向热改不重开在途动作；不兼容选科语义修改必须保留原有效局。
func _test_hot_reload_atomicity() -> bool:
	var source := _at(91000, 1, 61200.0)
	if source == null or not _result(source.start_action(0, "dorm_study", false, -1, "验收热改", "math"), "真实开始数学自习", source.error_message) or not _result(source.advance(17.0), "真实执行十七秒", source.error_message):
		return false
	var action_before: Dictionary = source.students[0].current_action.duplicate(true)
	var rng_before: String = str(source.rng.state)
	var config_path: String = _config("ai_valid_reload.json", {"g_study": 0.75, "g_weak": 0.75})
	var changed := GameConfig.new()
	if config_path.is_empty() or not _result(changed.load_file(config_path), "合法AI倾向新配置通过校验", changed.error_message) or not _result(source.apply_config(changed), "实际应用AI倾向热改", source.error_message):
		return false
	_check(source.students[0].current_action == action_before and str(source.rng.state) == rng_before, "倾向热改不重选科、不重抽时长、不重复收启动费用")
	var incompatible: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(config_path))
	for action: Dictionary in incompatible.tables.actions:
		if action.id == "dorm_study":
			action.knowledge_mode = "fixed_subject"
			action.knowledge_subject_id = "english"
	var bad_path: String = _path("ai_incompatible_reload.json")
	if not _write_json(bad_path, incompatible):
		return false
	var bad := GameConfig.new()
	if not _result(bad.load_file(bad_path), "结构合法但在途语义不兼容配置", bad.error_message):
		return false
	var authority: Dictionary = _state(source)
	_check(source.apply_config(bad) != OK and not source.error_message.is_empty(), "在途数学自习不得被热改猜成固定英语")
	_check(source.config == changed and _same(_state(source), authority), "失败热改保留整个有效局和随机流")
	_release(source)
	return true


## 同种子从真实宿舍跨午夜至次日课堂，比较真实动作序列与全部权威结果。
func _test_step_equivalence() -> bool:
	var large := _at(101000, 1, 61200.0)
	var small := _at(101000, 1, 61200.0)
	if large == null or small == null:
		return false
	for simulation: ClassroomSimulation in [large, small]:
		if not _result(simulation.allocate_attribute("discipline", 4), "本人真实分配自律四点", simulation.error_message) or not _result(simulation.allocate_attribute("attention", 4), "本人真实分配专注四点", simulation.error_message):
			return false
	if not _result(large.advance(55000.0), "大步真实跨夜至次日课堂", large.error_message):
		return false
	var remaining: float = 55000.0
	while remaining > 0.0:
		var duration: float = minf(37.0, remaining)
		if not _result(small.advance(duration), "37秒小步真实推进相同时间", small.error_message):
			return false
		remaining -= duration
	_check(large.day == 2 and small.day == 2, "大步小步均实际抵达次日")
	_check(_same(_state(large), _state(small)), "大步小步人物、知识、库存、状态、互动、账本和RNG一致")
	_check(_same(_action_history(large), _action_history(small)), "不同积分分段保留相同真实动作及互动历史")
	_check(not large.interactions.is_empty(), "该重放确实覆盖课堂自主竞争，不以空历史冒充通过")
	_release(large)
	_release(small)
	return true


## 夹具从正式配置创建，只调整显式用于触发或热改验收的参数。
func _config(filename: String, changes: Dictionary) -> String:
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://config/game_config.json"))
	for row: Dictionary in data.tables.globals:
		if changes.has(row.key):
			row.value = changes[row.key]
	var path: String = _path(filename)
	return path if _write_json(path, data) else ""


## 单项社交池用于逐动作真实完成验收，不向正式阶段配置写入任何内容。
func _scope(filename: String, social_ids: Array) -> String:
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://config/phase_scope.json"))
	data.social_auto_actions = social_ids
	var path: String = _path(filename)
	return path if _write_json(path, data) else ""


## 记录独占夹具路径后才写入，失败保留完整定位信息。
func _write_json(path: String, value: Dictionary) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not _check(file != null, "写入独占夹具：" + path):
		return false
	file.store_string(JSON.stringify(value, "\t", true, true))
	file.close()
	fixture_files.append(path)
	return true


## 测试路径始终位于本进程创建的独占缓存目录。
func _path(filename: String) -> String:
	return fixture_root.path_join(filename)


## 按真实互动编号查记录，不依赖后续自主活动是否已经开始。
func _interaction(simulation: ClassroomSimulation, interaction_id: int) -> Dictionary:
	for interaction: Dictionary in simulation.interactions:
		if int(interaction.interaction_id) == interaction_id:
			return interaction.duplicate(true)
	return {}


## 查询真实状态实例，不制造或延长状态。
func _has_buff(simulation: ClassroomSimulation, student_index: int, buff_id: String) -> bool:
	return simulation.students[student_index].buffs.any(func(instance: Dictionary) -> bool: return instance.buff_id == buff_id)


## 保存当前生产权威结果，分段资源日志和读档提示不属于需逐字相同的业务状态。
func _state(simulation: ClassroomSimulation) -> Dictionary:
	return {
		"students": simulation.students.duplicate(true), "interactions": simulation.interactions.duplicate(true),
		"notes": simulation.notes.duplicate(true), "violations": simulation.violations.duplicate(true),
		"day": simulation.day, "clock_seconds": simulation.clock_seconds, "elapsed_s": simulation.elapsed_s,
		"rng": str(simulation.rng.state), "next_action": simulation.next_action_number,
		"next_interaction": simulation.next_interaction_number, "round": simulation.round_progression.data.duplicate(true),
	}


## 比较真实动作事件，资源积分日志数量可以随外部推进分段改变。
func _action_history(simulation: ClassroomSimulation) -> Array:
	return simulation.logs.filter(func(entry: Dictionary) -> bool: return entry.type in ["start", "complete", "interrupt", "interaction_start", "dorm_recovery"])


## JSON数字允许表示误差，结构、数组次序、整型和RNG文本仍严格比较。
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
	if left is int and right is int:
		return left == right
	if (left is int or left is float) and (right is int or right is float):
		return left == right or absf(float(left) - float(right)) < 0.00000001
	return typeof(left) == typeof(right) and left == right


## 单个数值误差只允许机器积分表示差，不替代对实际结果的断言。
func _close(actual: float, expected: float, label: String) -> bool:
	return _check(absf(actual - expected) < 0.00000001, "%s：实际%.15f，预期%.15f" % [label, actual, expected])


## 生产入口必须明确成功才继续后续依赖步骤。
func _result(result: Error, label: String, detail: String = "") -> bool:
	return _check(result == OK, "%s：错误码%d %s" % [label, result, detail])


## 保存所有失败供最终统一输出，断言数量不代表覆盖场景可被跳过。
func _check(condition: bool, label: String) -> bool:
	checks += 1
	if not condition:
		failures.append(label)
	return condition


## 及时释放当前局的树节点，避免多种子验收残留无用场景对象。
func _release(simulation: ClassroomSimulation) -> void:
	for controller: ClassroomBehaviorController in controllers:
		if controller.simulation == simulation:
			controllers.erase(controller)
			simulation.decision_handler = Callable()
			controller.free()
			return


## 通过时清理本进程登记的独占夹具，失败保留证据，绝不遍历正式用户目录。
func _finish(marker: String = "AI_INTEGRATION") -> void:
	for controller: ClassroomBehaviorController in controllers:
		controller.free()
	if failures.is_empty():
		for path: String in fixture_files:
			if FileAccess.file_exists(path):
				_result(DirAccess.remove_absolute(path), "清理本次AI夹具")
		_result(DirAccess.remove_absolute(fixture_root), "清理本次AI独占目录")
	if failures.is_empty():
		print("%s_TEST_PASS checks=%d" % [marker, checks])
		quit(0)
	else:
		for message: String in failures:
			push_error(message)
		print("%s_TEST_FAIL checks=%d failures=%d fixtures=%s" % [marker, checks, failures.size(), fixture_root])
		quit(1)
