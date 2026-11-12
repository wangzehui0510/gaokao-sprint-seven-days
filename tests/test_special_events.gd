extends SceneTree
## 特殊事件批次：触发调度、玩家弹窗选择、NPC随机选择、选项效果类型与存档往返。

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
	fixture_root = OS.get_cache_dir().path_join("SpecialEvents_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	if not _result(DirAccess.make_dir_recursive_absolute(fixture_root), "建立独占测试目录"):
		_finish()
		return
	# 本组验证事件自身规则，不含每日发点；把起始日推到局外隔离每日属性点影响。
	configuration.globals["first_daily_attribute_day"] = 99
	if _empty() == null:
		_finish()
		return
	_check(_test_config_contract(), "特殊事件配置契约完整")
	_check(_test_trigger_schedule(), "事件触发调度场景完整执行")
	_check(_test_player_resolution(), "玩家待选择事件场景完整执行")
	_check(_test_npc_resolution(), "NPC随机选择事件场景完整执行")
	_check(_test_option_effects(), "事件选项效果类型完整落地")
	_check(_test_roundtrip(), "事件状态存档往返完整执行")
	_finish()


## 建立尚未自主决策的四人局；default_seed用于复现固定随机流。
func _empty(default_seed: int = 910715) -> ClassroomSimulation:
	var simulation := ClassroomSimulation.new()
	if not _result(simulation.setup(configuration, default_seed), "创建真实四人局", simulation.error_message):
		return null
	var controller := ClassroomBehaviorController.new()
	root.add_child(controller)
	controller.setup(simulation)
	simulation.decision_handler = controller.decide
	controllers.append(controller)
	return simulation


## 定位到第一节课内的真实局。
func _at_lesson(seed_value: int = 910715) -> ClassroomSimulation:
	var simulation := _empty(seed_value)
	if simulation == null:
		return null
	if not _result(simulation.set_debug_time(1, 28800.0), "定位第一节课内", simulation.error_message):
		return null
	if not _result(simulation.advance(0.0), "真实行为树开始当前时段", simulation.error_message):
		return null
	if not _check(simulation.course_context().kind == "lesson", "定位处于课内"):
		return null
	return simulation


## 定位到第2天早晨触发点前的真实局：早晨事件挂在第2天08:00第一节课段起点。
func _at_morning(seed_value: int) -> ClassroomSimulation:
	var simulation := _empty(seed_value)
	if simulation == null:
		return null
	if not _result(simulation.set_debug_time(2, 28790.0), "定位第2天早晨", simulation.error_message):
		return null
	if not _result(simulation.advance(0.0), "第2天早晨行为树开始", simulation.error_message):
		return null
	return simulation


## 强制下一检查点必触发：清空防重键与已触发日，概率改为1。
func _arm(simulation: ClassroomSimulation) -> void:
	configuration.globals["event_chance"] = 1.0
	simulation.event_auto.handled_key = ""
	simulation.event_auto.fired_day = 0


## 配置契约：12事件36选项51效果、触发点分布、新增状态与全局开关。
func _test_config_contract() -> bool:
	var ok: bool = true
	var triggers: Dictionary = {}
	for event: Dictionary in configuration.tables.events:
		triggers[String(event.trigger_point)] = int(triggers.get(String(event.trigger_point), 0)) + 1
	ok = _check(configuration.tables.events.size() == 12, "事件表恰好12个事件") and ok
	ok = _check(int(triggers.get("morning", 0)) == 2 and int(triggers.get("lesson_start", 0)) == 1 and int(triggers.get("break_start", 0)) == 2 and int(triggers.get("lunch", 0)) == 4 and int(triggers.get("after_school", 0)) == 3, "触发点分布为早晨2/知识课1/课间2/午休4/放学3") and ok
	ok = _check(configuration.tables.event_options.size() == 36, "事件选项恰好36条") and ok
	ok = _check(configuration.tables.event_effects.size() == 51, "事件效果恰好51条") and ok
	for buff_id: String in ["disciplined", "discipline_star", "undisciplined", "rushed_test"]:
		ok = _check(configuration.buffs.has(buff_id), "新增状态%s存在" % buff_id) and ok
	ok = _check(bool(configuration.globals.get("events_enabled", false)), "events_enabled已启用") and ok
	ok = _check(is_equal_approx(float(configuration.globals.get("event_chance", 0.0)), 0.25), "event_chance默认0.25") and ok
	# 每个启用事件恰有3个选项，效果引用完整（配置校验已保证，这里复核结构）。
	for event: Dictionary in configuration.tables.events:
		var count: int = 0
		for option: Dictionary in configuration.tables.event_options:
			if String(option.event_id) == String(event.id):
				count += 1
		ok = _check(bool(event.enabled) == false or count == 3, "事件%s选项数为3" % String(event.id)) and ok
	return ok


## 触发调度：第1天早晨不触发、第2天早晨概率触发、每日至多1个、局末放学不再触发。
func _test_trigger_schedule() -> bool:
	var ok: bool = true
	# 第1天08:00不触发任何事件。
	var day_one := _at_lesson(41021)
	if day_one == null:
		return false
	_arm(day_one)
	if not _result(day_one.advance(30.0), "推进过第1天早晨", day_one.error_message):
		return false
	ok = _check(int(day_one.event_auto.fired_day) == 0 and day_one.events_log.is_empty() and day_one.pending_event_for_player().is_empty(), "第1天早晨不触发事件") and ok
	# 第2天08:00触发早晨事件（练习册或忘带作业）。
	var day_two := _empty(41022)
	if day_two == null:
		return false
	if not _result(day_two.set_debug_time(2, 28790.0), "定位第2天早晨", day_two.error_message):
		return false
	if not _result(day_two.advance(0.0), "第2天早晨行为树开始", day_two.error_message):
		return false
	_arm(day_two)
	if not _result(day_two.advance(20.0), "推进跨过第2天早晨", day_two.error_message):
		return false
	ok = _check(int(day_two.event_auto.fired_day) == 2, "第2天早晨事件真实触发") and ok
	ok = _check(not day_two.events_log.is_empty() or not day_two.pending_event_for_player().is_empty(), "事件进入NPC结算或玩家待选择") and ok
	# 每日至多1个：同日后续触发点静默跳过。
	day_two.event_auto.handled_key = ""
	var log_size: int = day_two.events_log.size()
	if not _result(day_two.advance(3600.0), "推进到第2天课间与午休", day_two.error_message):
		return false
	ok = _check(int(day_two.event_auto.fired_day) == 2 and day_two.events_log.size() == log_size, "每日至多1个事件生效") and ok
	# 第7天放学后不再触发。
	var last_day := _empty(41027)
	if last_day == null:
		return false
	if not _result(last_day.set_debug_time(7, 59990.0), "定位第7天放学前", last_day.error_message):
		return false
	if not _result(last_day.advance(0.0), "第7天放学前行为树开始", last_day.error_message):
		return false
	_arm(last_day)
	if not _result(last_day.advance(20.0), "推进跨过第7天放学", last_day.error_message):
		return false
	ok = _check(int(last_day.event_auto.fired_day) == 0 and last_day.events_log.is_empty(), "局末放学不再触发事件") and ok
	# 概率为0时永不触发。
	configuration.globals["event_chance"] = 0.0
	var quiet := _empty(41028)
	if quiet == null:
		return false
	if not _result(quiet.set_debug_time(2, 28790.0), "定位零概率早晨", quiet.error_message):
		return false
	if not _result(quiet.advance(0.0), "零概率早晨行为树开始", quiet.error_message):
		return false
	_arm(quiet)
	configuration.globals["event_chance"] = 0.0
	quiet.event_auto.fired_day = 0
	if not _result(quiet.advance(20.0), "推进过零概率早晨", quiet.error_message):
		return false
	ok = _check(int(quiet.event_auto.fired_day) == 0 and quiet.events_log.is_empty(), "概率为0时不触发事件") and ok
	configuration.globals["event_chance"] = 1.0
	return ok


## 玩家事件：待选择状态不暂停挂机；选择真实结算并写入玩家历史；重复结算被拒。
func _test_player_resolution() -> bool:
	var ok: bool = true
	# 遍历固定种子找到玩家归属的事件局（归属者由ambient流抽取）。
	var simulation: ClassroomSimulation = null
	var pending: Dictionary = {}
	for seed_value in range(41101, 41141):
		simulation = _at_morning(seed_value)
		if simulation == null:
			return false
		_arm(simulation)
		if not _result(simulation.advance(20.0), "推进跨过第2天早晨 seed=%d" % seed_value, simulation.error_message):
			return false
		pending = simulation.pending_event_for_player()
		if not pending.is_empty():
			break
		simulation = null
	if simulation == null:
		return _check(false, "40个种子中未找到玩家归属事件局")
	ok = _check(int(pending.get("target_index", -1)) in range(1, simulation.students.size()), "玩家事件的同学目标在1到3之间") and ok
	ok = _check(pending.options.size() == 3, "玩家事件有三个可选选项") and ok
	# 待选择不暂停挂机：弹窗期间推进照常。
	var before_elapsed: float = simulation.elapsed_s
	if not _result(simulation.advance(30.0), "待选择期间照常推进", simulation.error_message):
		return false
	ok = _check(simulation.elapsed_s > before_elapsed, "待选择状态不暂停模拟推进") and ok
	# 非法选择被拒绝：外部选项与重复结算。
	var illegal: Error = simulation.resolve_pending_event("pop_quiz_answer")
	ok = _check(illegal == ERR_UNAVAILABLE, "不属于当前事件的选项被拒绝") and ok
	# 找同学借：待分配点+1、目标同学专注-5。
	var target_index: int = int(pending.target_index)
	var target_before: float = float(simulation.students[target_index].focus)
	var points_before: int = int(simulation.students[0].unspent_points)
	var resolved: Error = simulation.resolve_pending_event("lost_workbook_money_borrow")
	if resolved == OK:
		ok = _check(int(simulation.students[0].unspent_points) == points_before + 1, "找同学借获得1待分配点") and ok
		ok = _check(absf(float(simulation.students[target_index].focus) - (target_before - 5.0)) < 1.0e-6, "被借的同学专注-5") and ok
		ok = _check(simulation.pending_event_for_player().is_empty(), "结算后待选择状态清空") and ok
		ok = _check(simulation.events_log.size() == 1 and String(simulation.events_log[0].resolver) == "player" and String(simulation.events_log[0].option_id) == "lost_workbook_money_borrow", "玩家选择写入事件历史") and ok
	else:
		# 该局抽到的是忘带作业：退而验证其坦白选项同样真实结算。
		var confessed: Error = simulation.resolve_pending_event("forgot_homework_confess")
		ok = _check(confessed == OK, "忘带作业坦白选项真实结算") and ok
		ok = _check(simulation.pending_event_for_player().is_empty(), "结算后待选择状态清空") and ok
	var repeat: Error = simulation.resolve_pending_event("lost_workbook_money_borrow")
	ok = _check(repeat != OK, "重复结算被拒绝") and ok
	return ok


## NPC事件：等权随机选选项立即结算，历史记录完整且归属正确。
func _test_npc_resolution() -> bool:
	var ok: bool = true
	var simulation: ClassroomSimulation = null
	for seed_value in range(41201, 41241):
		simulation = _at_morning(seed_value)
		if simulation == null:
			return false
		_arm(simulation)
		if not _result(simulation.advance(20.0), "推进跨过第2天早晨 seed=%d" % seed_value, simulation.error_message):
			return false
		if not simulation.events_log.is_empty() and simulation.pending_event_for_player().is_empty():
			break
		simulation = null
	if simulation == null:
		return _check(false, "40个种子中未找到NPC归属事件局")
	var entry: Dictionary = simulation.events_log[0]
	ok = _check(String(entry.resolver) == "npc", "NPC事件由执行器即时结算") and ok
	ok = _check(int(entry.student_index) in range(1, simulation.students.size()), "NPC事件归属者不是玩家") and ok
	ok = _check(not String(entry.option_id).is_empty() and not String(entry.event_id).is_empty(), "NPC事件历史含事件与选项") and ok
	ok = _check(not String(entry.summary).is_empty(), "NPC事件历史含结算摘要") and ok
	return ok


## 选项效果类型逐一真实落地：资源/知识/状态/待分配点/物品/课间强制动作。
func _test_option_effects() -> bool:
	var ok: bool = true
	var simulation := _at_lesson(41301)
	if simulation == null:
		return false
	for student: Dictionary in simulation.students:
		student.inventory["snack"] = 0
		student.inventory["comic"] = 0
	# 直接构造玩家待选择事件，逐选项定向结算验证效果类型。
	simulation.students[0].pending_event = {"event_id": "lost_workbook_money", "target_index": 1}
	var points_before: int = int(simulation.students[0].unspent_points)
	var target_focus_before: float = float(simulation.students[1].focus)
	if not _result(simulation.resolve_pending_event("lost_workbook_money_borrow"), "找同学借真实结算", simulation.error_message):
		return false
	ok = _check(int(simulation.students[0].unspent_points) == points_before + 1 and absf(float(simulation.students[1].focus) - (target_focus_before - 5.0)) < 1.0e-6, "待分配点与目标专注效果落地") and ok
	simulation.students[0].pending_event = {"event_id": "lost_workbook_money", "target_index": 1}
	var stamina_before: float = float(simulation.students[0].stamina)
	if not _result(simulation.resolve_pending_event("lost_workbook_money_pay_self"), "自己垫付真实结算", simulation.error_message):
		return false
	ok = _check(absf(float(simulation.students[0].stamina) - (stamina_before - 8.0)) < 1.0e-6, "体力效果落地") and ok
	simulation.students[0].pending_event = {"event_id": "lost_workbook_money", "target_index": 1}
	if not _result(simulation.resolve_pending_event("lost_workbook_money_report"), "报告老师真实结算", simulation.error_message):
		return false
	ok = _check(_has_buff(simulation, 0, "disciplined"), "自律状态效果落地") and ok
	simulation.students[0].pending_event = {"event_id": "forgot_homework", "target_index": 1}
	if not _result(simulation.resolve_pending_event("forgot_homework_make_up"), "课间补写真实结算", simulation.error_message):
		return false
	ok = _check(String(simulation.students[0].pending_forced_action) == "notes", "强制动作进入待执行状态") and ok
	# 推进到课间：强制补写真实启动且字段清空。
	if not _result(simulation.advance(2720.0), "推进到第2天课间", simulation.error_message):
		return false
	ok = _check(String(simulation.students[0].current_action.get("action_id")) == "notes" and String(simulation.students[0].pending_forced_action) == "", "课间强制动作真实启动并清空") and ok
	# 午休事件的物品与状态效果。
	simulation.students[0].pending_event = {"event_id": "canteen_queue", "target_index": 1}
	var snack_before: int = int(simulation.students[0].inventory.get("snack", 0))
	if not _result(simulation.resolve_pending_event("canteen_queue_switch"), "换窗口真实结算", simulation.error_message):
		return false
	ok = _check(int(simulation.students[0].inventory.get("snack", 0)) == snack_before + 1, "获得零食效果落地") and ok
	simulation.students[0].pending_event = {"event_id": "canteen_queue", "target_index": 1}
	var both_before: float = float(simulation.students[0].focus)
	var both_target_before: float = float(simulation.students[1].focus)
	if not _result(simulation.resolve_pending_event("canteen_queue_argue"), "当场理论真实结算", simulation.error_message):
		return false
	ok = _check(absf(float(simulation.students[0].focus) - (both_before - 3.0)) < 1.0e-6 and absf(float(simulation.students[1].focus) - (both_target_before - 3.0)) < 1.0e-6, "双方扣专注效果落地") and ok
	# 知识课开始事件的知识效果：pop_quiz认真答计入当前课科目。
	var quiz := _empty(41302)
	if quiz == null:
		return false
	configuration.globals["event_chance"] = 0.0
	if not _result(quiz.set_debug_time(1, 32090.0), "定位第1天第二节前", quiz.error_message):
		return false
	if not _result(quiz.advance(20.0), "推进跨入第二节知识课", quiz.error_message):
		return false
	if not _check(String(quiz.course_context().kind) == "lesson" and not String(quiz.course_context().subject_id).is_empty(), "定位处于知识课内"):
		return false
	var quiz_subject: String = String(quiz.course_context().subject_id)
	quiz.students[0].pending_event = {"event_id": "pop_quiz", "target_index": 1}
	var knowledge_before: float = float(quiz.students[0].knowledge[quiz_subject])
	var quiz_focus_before: float = float(quiz.students[0].focus)
	if not _result(quiz.resolve_pending_event("pop_quiz_answer"), "认真作答真实结算", quiz.error_message):
		return false
	ok = _check(absf(float(quiz.students[0].knowledge[quiz_subject]) - (knowledge_before + 8.0)) < 1.0e-6, "知识效果计入当前课科目") and ok
	ok = _check(absf(float(quiz.students[0].focus) - (quiz_focus_before - 5.0)) < 1.0e-6, "认真作答扣专注落地") and ok
	quiz.students[0].pending_event = {"event_id": "pop_quiz", "target_index": 1}
	if not _result(quiz.resolve_pending_event("pop_quiz_guess"), "凭感觉蒙真实结算", quiz.error_message):
		return false
	ok = _check(_has_buff(quiz, 0, "rushed_test"), "知识打折状态落地") and ok
	# 拾金不昧的自律+2与待分配点。
	quiz.students[0].pending_event = {"event_id": "lost_found", "target_index": 1}
	points_before = int(quiz.students[0].unspent_points)
	if not _result(quiz.resolve_pending_event("lost_found_teacher"), "交给老师真实结算", quiz.error_message):
		return false
	ok = _check(_has_buff(quiz, 0, "discipline_star") and int(quiz.students[0].unspent_points) == points_before + 1, "自律+2与待分配点效果落地") and ok
	# 拒绝参与（自律-1）。
	quiz.students[0].pending_event = {"event_id": "chalk_fight", "target_index": 1}
	if not _result(quiz.resolve_pending_event("chalk_fight_refuse"), "拒绝参与真实结算", quiz.error_message):
		return false
	ok = _check(_has_buff(quiz, 0, "undisciplined"), "自律-1状态落地") and ok
	return ok


## 辅助：检查学生是否挂有指定状态。
func _has_buff(simulation: ClassroomSimulation, index: int, buff_id: String) -> bool:
	for buff: Dictionary in simulation.students[index].buffs:
		if String(buff.buff_id) == buff_id:
			return true
	return false


## 存档往返：在途玩家事件、事件历史与触发状态随档恢复；读档后仍可真实选择。
func _test_roundtrip() -> bool:
	var ok: bool = true
	var simulation: ClassroomSimulation = null
	for seed_value in range(41401, 41441):
		simulation = _at_morning(seed_value)
		if simulation == null:
			return false
		_arm(simulation)
		if not _result(simulation.advance(20.0), "推进跨过第2天早晨 seed=%d" % seed_value, simulation.error_message):
			return false
		if not simulation.pending_event_for_player().is_empty():
			break
		simulation = null
	if simulation == null:
		return _check(false, "40个种子中未找到玩家归属事件局")
	var save_path: String = fixture_root.path_join("event_save.json")
	if not _result(simulation.save_file(save_path), "保存事件在途存档", simulation.error_message):
		return false
	var restored := _empty()
	if restored == null:
		return false
	if not _result(restored.load_file(save_path, false), "读取事件在途存档", restored.error_message):
		return false
	ok = _check(not restored.pending_event_for_player().is_empty(), "读档保留待选择事件") and ok
	ok = _check(int(restored.event_auto.fired_day) == int(simulation.event_auto.fired_day), "读档保留每日触发状态") and ok
	var options: Array = restored.pending_event_for_player().options
	var first_option: String = String(options[0].id)
	if not _result(restored.resolve_pending_event(first_option), "读档后真实选择事件选项", restored.error_message):
		return false
	ok = _check(restored.pending_event_for_player().is_empty() and restored.events_log.size() == 1, "读档后选择真实结算并写入历史") and ok
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
		print("SPECIAL_EVENTS_TEST_PASS checks=%d" % checks)
		quit(0)
	else:
		for message: String in failures:
			push_error(message)
		print("SPECIAL_EVENTS_TEST_FAIL checks=%d failures=%d fixtures=%s" % [checks, failures.size(), fixture_root])
		quit(1)


## 本组写入的临时文件清单。
func fixture_files_list() -> Array[String]:
	return [fixture_root.path_join("event_save.json")]
