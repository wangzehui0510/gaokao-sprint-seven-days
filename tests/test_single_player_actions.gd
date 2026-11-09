extends SceneTree
## 单机动作必须经过正式配置、真实行为树、真实抽奖与统一执行器，不预填库存或完成结果。

# 文件仅落在本进程独占系统缓存，不读写正式玩家存档和权威配置。
var fixture_root: String = ""
var fixture_files: Array[String] = []
var configuration: GameConfig
var owned_controllers: Array[ClassroomBehaviorController] = []
var checks: int = 0
var failures: Array[String] = []


## 等场景树建立后执行完整业务链。
func _initialize() -> void:
	call_deferred("_run")


## 每组场景必须实际返回完成标记，运行时中断不能跳过后续断言后报告成功。
func _run() -> void:
	configuration = GameConfig.new()
	if not _result(configuration.load_file(), "加载正式配置", configuration.error_message):
		_finish()
		return
	fixture_root = OS.get_cache_dir().path_join("ClassroomSingleActions_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	if not _result(DirAccess.make_dir_recursive_absolute(fixture_root), "建立独占动作验证目录"):
		_finish()
		return
	_check(_test_all_actions(), "17个新增个人动作均真实启动、积分与完成")
	_check(_test_unavailable_atomicity(), "资源和物品不足原子拒绝，可用性查询无副作用")
	_check(_test_item_aggregation(), "同物品多条消耗汇总验证并真实扣除")
	_check(_test_interruption(), "已消费物品不退款，打断不结算完成奖励")
	_check(_test_pair_replacement(), "物品不足保留双人动作，真实消费接管后旧纸条不再送达")
	_check(_test_completion_routes(), "完成后回课程只结束一次且不重扣自然启动费")
	_check(_test_completion_boundaries(), "完成接续在换课清理后只启动一次，终局不短暂开启新动作")
	_check(_test_buff_lifetimes(), "动作状态真实清理，定时状态真实刷新与到期")
	_check(_test_save_roundtrip(), "在途物品动作真实存档恢复不重扣或重抽")
	_check(_test_hot_reload(), "合法费率热改不重收物品，坏配置不替换有效局")
	_check(_test_scope_rejection(), "不支持的消耗阶段、数量、状态及接续在入口明确拒绝")
	_check(_test_round_end(), "终局取消在途完成效果并拒绝新物品指令")
	_finish()


## 四棵真实行为树按正式课表开课，物品只来自真实课程奖励。
func _simulation(seed_value: int = 1, at_day: int = 1, seconds: float = 28800.0, game_config: GameConfig = null, start_tree: bool = true) -> ClassroomSimulation:
	var simulation := ClassroomSimulation.new()
	var loaded: GameConfig = configuration if game_config == null else game_config
	if not _result(simulation.setup(loaded, seed_value), "建立四人真实新局", simulation.error_message):
		return null
	if not _result(simulation.set_debug_time(at_day, seconds), "定位真实课表", simulation.error_message):
		return null
	var controller := ClassroomBehaviorController.new()
	root.add_child(controller)
	controller.setup(simulation)
	owned_controllers.append(controller)
	simulation.decision_handler = controller.decide
	if start_tree and not _result(simulation.advance(0.0), "真实行为树开始课程", simulation.error_message):
		return null
	return simulation


## 固定种子在正式奖池中实际抽得对应物品，不修改背包制造使用前置条件。
func _item_simulation(item_id: String, at_day: int = 1, seconds: float = 28800.0) -> ClassroomSimulation:
	var seeds: Dictionary = {"snack": 1, "comic": 2, "candy": 6}
	var simulation := _simulation(seeds[item_id], at_day, seconds)
	if simulation == null:
		return null
	if not _check(int(simulation.students[0].inventory.get(item_id, 0)) > 0, "真实课程抽奖应获得%s" % item_id):
		return null
	_check(_events(simulation, "daily_items", 0).size() == 1, "持有物品必须有对应的真实领取日志")
	return simulation


## 明确期望检验完整行为结果，含动作启动费、连续积分、完成奖励及知识倍率。
func _test_all_actions() -> bool:
	var cases: Array[Dictionary] = [
		{"id": "snack_self", "item": "snack", "focus": 0.0, "stamina": 15.0, "knowledge": 0.0},
		{"id": "lunch_rest", "focus": 20.0, "stamina": 60.0, "knowledge": 0.0},
		{"id": "read_comic", "focus": 8.0, "stamina": -0.4, "knowledge": 0.0, "buff": "comic_afterglow"},
		{"id": "bathroom", "focus": 8.0, "stamina": -0.8, "knowledge": 0.0},
		{"id": "linger_break", "focus": 3.0, "stamina": 0.9, "knowledge": 0.0},
		{"id": "sprint_study", "focus": -15.5, "stamina": -2.0, "knowledge": 5.5},
		{"id": "preview", "focus": -5.5, "stamina": -1.0, "knowledge": 0.0, "buff": "prepared"},
		{"id": "notes", "focus": -5.4, "stamina": -0.6, "knowledge": 1.5, "buff": "notes_ready"},
		{"id": "self_test", "focus": -9.0, "stamina": -1.5, "knowledge": 5.5, "buff": "inspired"},
		{"id": "standing_study", "focus": -7.0, "stamina": -4.0, "knowledge": 5.0},
		{"id": "chores", "focus": 7.5, "stamina": -4.0, "knowledge": 0.0},
		{"id": "exercise_slack", "focus": 1.0, "stamina": 1.5, "knowledge": 0.0},
		{"id": "remind_self", "focus": -2.0, "stamina": 0.0, "knowledge": 0.0},
		{"id": "wake_self", "focus": -2.0, "stamina": 0.0, "knowledge": 0.0},
		{"id": "recall_classroom", "focus": -3.0, "stamina": 0.0, "knowledge": 0.0},
		{"id": "read_comic_item", "item": "comic", "focus": 15.0, "stamina": -0.5, "knowledge": 0.0, "buff": "comic_afterglow"},
		{"id": "eat_candy_item", "item": "candy", "focus": 10.0, "stamina": 0.0, "knowledge": 0.0},
	]
	for scenario: Dictionary in cases:
		var simulation: ClassroomSimulation = _item_simulation(scenario.item) if scenario.has("item") else _simulation()
		if simulation == null:
			return false
		simulation.students[0].focus = 60.0
		simulation.students[0].stamina = 30.0
		var before_inventory: Dictionary = simulation.students[0].inventory.duplicate()
		var before_knowledge: float = simulation.students[0].knowledge.chinese
		if not _result(simulation.start_action(0, scenario.id), "真实发动%s" % scenario.id, simulation.error_message):
			return false
		var instance: Dictionary = simulation.students[0].current_action.duplicate(true)
		_close(instance.duration_s, configuration.actions[scenario.id].duration_min_s, "新增动作时长读取正式配置")
		if scenario.id == "sprint_study":
			_check(_has_buff(simulation, "sprinting"), "冲刺在开始时施加真实动作状态")
			_close(simulation.effective_attribute(0, "attention"), 2.0, "冲刺状态实际提高有效专注力")
		if scenario.has("item"):
			_check(simulation.students[0].inventory[scenario.item] == before_inventory[scenario.item] - 1, "成功开始即真实消费一件物品")
			var consumed: Array = _events(simulation, "consume_item", 0)
			_check(consumed.size() == 1 and consumed[0].details.item_id == scenario.item and consumed[0].details.quantity == 1 and consumed[0].details.instance_id == instance.instance_id, "扣物日志关联真实动作实例和数量")
		if not _result(simulation.advance(instance.duration_s), "推进至%s实际完成" % scenario.id, simulation.error_message):
			return false
		var ended: Array = _instance_events(simulation, instance.instance_id)
		if not _check(ended.size() == 1 and ended[0].type == "complete", "动作只记录一次真实正常完成：" + scenario.id):
			return false
		for resource: String in ["focus", "stamina"]:
			_close(float(ended[0].details.resource_changes.get(resource, {}).get("actual", 0.0)), scenario[resource], "%s的%s实际总变化" % [scenario.id, resource])
		_close(ended[0].details.knowledge_gain, scenario.knowledge, "完整动作记录真实知识：" + scenario.id)
		_close(simulation.students[0].knowledge.chinese - before_knowledge, scenario.knowledge, "权威知识实际入账：" + scenario.id)
		if scenario.has("buff"):
			_check(_has_buff(simulation, scenario.buff), "完成后施加对应状态：" + scenario.id)
		_check(not _has_buff(simulation, "sprinting"), "完成后动作生命周期状态已清除")
		_check(simulation.students[0].current_action.instance_id != instance.instance_id, "完成后真实行为树或完成路由接续新实例")
	_check(cases.size() == 17, "新增个人动作覆盖数为17")
	var simulation := _simulation()
	if simulation == null:
		return false
	_check(simulation.phase_scope.enabled_actions.size() == 54, "范围保留既有49项并增加五项宿舍动作")
	var expected_actions: Array[String] = [
		"study", "physical_study", "music_class", "art_class", "break_rest", "eye_exercise",
		"morning_exercise", "rest", "daydream", "sleep", "eat_meal", "dorm_rest", "exam",
		"focus_command", "playground_play", "send_note", "eraser_prank", "report",
		"remind_friend", "solve_together", "invite_playground", "invite_canteen", "borrow_notes",
		"encourage", "pillow_fight", "feed_snack", "use_eraser", "give_comic_item",
		"give_candy_item", "swap_book", "swap_book_boost", "arm_wrestle",
		"dorm_study", "dorm_practice", "dorm_game", "dorm_workout", "dorm_wash",
	]
	for scenario: Dictionary in cases:
		expected_actions.append(scenario.id)
	expected_actions.sort()
	var actual_actions: Array = simulation.phase_scope.enabled_actions.duplicate()
	actual_actions.sort()
	_check(actual_actions == expected_actions, "既有动作身份完整保留，新增宿舍范围没有多开或漏开")
	_check(simulation.phase_scope.dorm_auto_actions == ["dorm_study", "dorm_practice", "dorm_game", "dorm_workout", "dorm_wash", "dorm_rest"], "宿舍自主池恰为已批准六项")
	_check(simulation.phase_scope.auto_actions == ["daydream", "sleep", "read_comic", "bathroom"] and simulation.phase_scope.subject_auto_actions == {"physical": ["playground_play"]}, "自主候选按批准范围开放发呆、睡觉、漫画与上厕所")
	for candidate: Dictionary in simulation.get_auto_candidates(0):
		_check(candidate.action_id not in ["send_note", "linger_break"], "仅开放执行的动作不擅自加入自主池")
	_check(configuration.actions.bathroom.scene == "any" and configuration.actions.playground_play.scene == "any", "权威地点配置保持原值")
	return true


## 整组前置失败发生在结束旧动作、抽时长、扣费、扣物和写日志之前。
func _test_unavailable_atomicity() -> bool:
	var simulation := _simulation(8)
	if simulation == null:
		return false
	for action_id: String in ["snack_self", "read_comic_item", "eat_candy_item"]:
		var before: Dictionary = _authority(simulation)
		var reason: String = simulation.action_unavailable_reason(0, action_id)
		_check(not reason.is_empty() and reason.contains("不足"), "缺物原因明确显示数量不足")
		_check(not simulation.can_start_action(0, action_id), "查询和实际发动共用物品前置")
		_check(_authority(simulation) == before, "缺物查询完全无副作用")
		_check(simulation.start_action(0, action_id) == ERR_UNAVAILABLE and simulation.error_message == reason, "真实发动返回同一明确业务拒绝")
		_check(_authority(simulation) == before, "缺物拒绝保留全体状态、旧动作、随机流与日志")
	simulation.students[0].focus = 7.0
	var before: Dictionary = _authority(simulation)
	_check(simulation.action_unavailable_reason(0, "sprint_study").contains("专注不足"), "资源不足原因明确")
	_check(simulation.start_action(0, "sprint_study") == ERR_UNAVAILABLE, "启动资源不足真实拒绝")
	_check(_authority(simulation) == before, "资源不足不结束原课程或改变任何权威结果")
	for query: Array in [[-1, "study"], [4, "study"], [0, "missing"], [0, "focus_command"], [0, "send_note"]]:
		_check(not simulation.action_unavailable_reason(query[0], query[1]).is_empty(), "非法角色、未开放动作及专用入口明确拒绝")
	_check(_authority(simulation) == before, "各类可用性查询均保持无副作用")
	return true


## 配置副本增加第二条消费；物品仍通过真实奖池领取，不直接修改库存。
func _test_item_aggregation() -> bool:
	var data: Dictionary = _config_data()
	var extra: Dictionary = _effect(data, "snack_self_start_2").duplicate(true)
	extra.id = "snack_self_start_3"
	extra.sequence = 3
	data.tables.effects.append(extra)
	var doubled: GameConfig = _load_config(data, "aggregate.json")
	if doubled == null:
		return false
	var simulation := _simulation(1, 1, 28800.0, doubled)
	if simulation == null:
		return false
	_check(simulation.students[0].inventory.snack == 1, "正式奖池真实抽到一份零食")
	var before: Dictionary = _authority(simulation)
	_check(simulation.action_unavailable_reason(0, "snack_self").contains("需要2件"), "多条同物消耗必须先汇总为两件")
	_check(simulation.start_action(0, "snack_self") == ERR_UNAVAILABLE, "一件不能支付两条各一件的消费")
	_check(_authority(simulation) == before, "汇总不足不会先扣第一件或启动费用")
	for row: Dictionary in data.tables.drop_pool:
		row.quantity = 2
	var larger_rewards: GameConfig = _load_config(data, "aggregate_real_reward.json")
	if larger_rewards == null:
		return false
	simulation = _simulation(1, 1, 28800.0, larger_rewards)
	if simulation == null:
		return false
	_check(simulation.students[0].inventory.snack == 2, "配置副本的真实课程奖励发放两件零食")
	if not _result(simulation.start_action(0, "snack_self"), "两份真实库存支付两条消费", simulation.error_message):
		return false
	_check(simulation.students[0].inventory.snack == 0 and _events(simulation, "consume_item", 0).size() == 2, "每条真实消费记录且库存合计恰好扣两件")
	return true


## 途中切换保留已发生连续收益，不退启动消费，也不提前补发完成状态或资源。
func _test_interruption() -> bool:
	for scenario: Dictionary in [{"id": "snack_self", "item": "snack"}, {"id": "read_comic_item", "item": "comic"}, {"id": "eat_candy_item", "item": "candy"}]:
		var simulation := _item_simulation(scenario.item)
		if simulation == null:
			return false
		simulation.students[0].focus = 60.0
		simulation.students[0].stamina = 30.0
		var item_count: int = simulation.students[0].inventory[scenario.item]
		if not _result(simulation.start_action(0, scenario.id), "开始真实可消费动作", simulation.error_message):
			return false
		var instance: Dictionary = simulation.students[0].current_action.duplicate(true)
		if not _result(simulation.advance(instance.duration_s / 2.0), "实际执行一半时长", simulation.error_message):
			return false
		var before_resources: Array = [simulation.students[0].focus, simulation.students[0].stamina]
		if not _result(simulation.start_action(0, "rest"), "真实休息打断物品动作", simulation.error_message):
			return false
		_check(simulation.students[0].inventory[scenario.item] == item_count - 1, "打断不退还已消耗物品")
		_check([simulation.students[0].focus, simulation.students[0].stamina] == before_resources, "打断不会发放未完成资源奖励")
		var ended: Array = _instance_events(simulation, instance.instance_id)
		_check(ended.size() == 1 and ended[0].type == "interrupt", "物品动作只记录一次实际打断")
		_check(not _has_buff(simulation, "comic_afterglow"), "未完成阅读不获得完成状态")
	return true


## 双人动作中也先验证完整消费条件，成功换动作才整体结束旧互动并恢复旧搭档。
func _test_pair_replacement() -> bool:
	var unavailable := _simulation(8)
	if unavailable == null or not _result(unavailable.start_interaction(0, 1, "send_note", "缺物时保留真实在途纸条"), "建立缺物拒绝时的双人动作", unavailable.error_message):
		return false
	var before: Dictionary = _authority(unavailable)
	_check(unavailable.action_unavailable_reason(0, "snack_self").contains("不足"), "双人动作中明确报告零食不足")
	_check(unavailable.start_action(0, "snack_self") == ERR_UNAVAILABLE, "双人动作中真实拒绝缺物指令")
	_check(_authority(unavailable) == before, "缺物时不打断任一参与者、不改纸条或随机流")
	var simulation := _item_simulation("snack")
	if simulation == null or not _result(simulation.start_interaction(0, 1, "send_note", "成功换动作后不可送达"), "消费前建立真实双人动作", simulation.error_message):
		return false
	var old_interaction: Dictionary = simulation.interactions.back()
	var old_target_instance: int = simulation.students[1].current_action.instance_id
	if not _result(simulation.advance(5.0), "纸条先真实执行五秒", simulation.error_message):
		return false
	var inventory_before: int = simulation.students[0].inventory.snack
	if not _result(simulation.start_action(0, "snack_self"), "真实物品动作取得控制权", simulation.error_message):
		return false
	var replacement: Dictionary = simulation.students[0].current_action.duplicate(true)
	_check(old_interaction.status == "interrupted" and simulation.notes.is_empty(), "成功切换才整体打断旧纸条")
	_check(simulation.students[1].current_action.action_id == "study" and simulation.students[1].current_action.instance_id != old_target_instance, "旧搭档由真实行为树返回课程新实例")
	_check(not simulation.students[1].current_action.has("interaction_id"), "旧搭档不会遗留孤儿双人占用")
	_check(simulation.students[0].inventory.snack == inventory_before - 1, "新动作成功消费一份真实奖品")
	if not _result(simulation.advance(replacement.duration_s), "新物品动作真实完成并跨过旧纸条原结束时刻", simulation.error_message):
		return false
	_check(simulation.notes.is_empty() and old_interaction.status == "interrupted", "旧纸条原到期不能补送或重新完成")
	var ended: Array = _instance_events(simulation, replacement.instance_id)
	_check(ended.size() == 1 and ended[0].type == "complete", "旧互动清理没有覆盖新物品动作的真实完成")
	_check(_events(simulation, "consume_item", 0).size() == 1, "整体打断和恢复旧搭档不重复扣物")
	return true


## 完成路由必须在旧实例结算后启动，强制回课程使用非自然入段契约。
func _test_completion_routes() -> bool:
	for action_id: String in ["remind_self", "wake_self", "recall_classroom"]:
		var simulation := _simulation()
		if simulation == null:
			return false
		simulation.students[0].focus = 20.0
		if not _result(simulation.start_action(0, action_id), "真实开始回课程指令", simulation.error_message):
			return false
		var instance: Dictionary = simulation.students[0].current_action.duplicate(true)
		var focus_after_start: float = simulation.students[0].focus
		if not _result(simulation.advance(instance.duration_s), "指令实际完成后进入课程", simulation.error_message):
			return false
		_check(simulation.students[0].current_action.action_id == "study" and not simulation.students[0].current_action.natural_entry, "低专注也按完成契约强制进入本节课程")
		_close(simulation.students[0].focus, focus_after_start, "完成接续不重收课程自然启动费")
		var ended: Array = _instance_events(simulation, instance.instance_id)
		_check(ended.size() == 1 and ended[0].type == "complete", "完成接续不递归打断或重复结束旧实例")
		var completed_position: int = simulation.logs.find(ended[0])
		var next_start_position: int = -1
		for index: int in simulation.logs.size():
			if simulation.logs[index].student_index == 0 and simulation.logs[index].type == "start" and simulation.logs[index].details.action_id == "study" and simulation.logs[index].elapsed_s == simulation.elapsed_s:
				next_start_position = index
		_check(next_start_position > completed_position, "先记录旧动作正常完成，再记录新课程启动")
		_check(_events(simulation, "daily_items", 0).size() == 1, "完成接续不重复领取当天物品")
		if not _result(simulation.advance(60.0), "接续学习真实运行一分钟", simulation.error_message):
			return false
		_close(simulation.students[0].knowledge.chinese, 1.0, "接续动作没有被旧实例清理覆盖")
	var rest_context := _simulation(1, 1, 72000.0)
	if rest_context == null or not _result(rest_context.start_action(0, "recall_classroom"), "课外真实召回", rest_context.error_message):
		return false
	if not _result(rest_context.advance(60.0), "课外召回实际完成", rest_context.error_message):
		return false
	_check(rest_context.students[0].current_action.action_id == "dorm_rest", "current_course接续当前课表默认活动，不猜成固定学习")
	_close(rest_context.students[0].knowledge.chinese, 0.0, "课外回归不伪造课堂知识")
	return true


## 完成与换课、终局同刻发生时，接续必须服从统一边界顺序，不能生成即刻取消的新实例。
func _test_completion_boundaries() -> bool:
	var boundary: float = roundf(configuration.indexes.periods.lesson_1.end_time * 86400.0)
	var simulation := _simulation(1, 1, boundary - 30.0)
	if simulation == null or not _result(simulation.start_action(0, "remind_self"), "换课前真实开始三十秒提醒", simulation.error_message):
		return false
	var instance_id: int = simulation.students[0].current_action.instance_id
	if not _result(simulation.advance(30.0), "提醒恰好在课间边界正常完成", simulation.error_message):
		return false
	var starts: Array = _events(simulation, "start", 0).filter(func(entry: Dictionary): return entry.elapsed_s == simulation.elapsed_s)
	_check(starts.size() == 1, "完成与换课同刻只启动一次真实后续动作")
	_check(simulation.students[0].current_action.action_id == "break_rest" and not simulation.students[0].current_action.natural_entry, "换课清理后保留完成效果指定的强制入段方式")
	var ended: Array = _instance_events(simulation, instance_id)
	_check(ended.size() == 1 and ended[0].type == "complete", "边界上的原指令仍只正常完成一次")
	var final_simulation := _simulation(1, 7, 59970.0)
	if final_simulation == null or not _result(final_simulation.start_action(0, "remind_self"), "终局前三十秒真实提醒", final_simulation.error_message):
		return false
	var final_instance: int = final_simulation.students[0].current_action.instance_id
	if not _result(final_simulation.advance(30.0), "提醒与七天局结束同刻完成", final_simulation.error_message):
		return false
	_check(final_simulation.is_round_finished() and final_simulation.students[0].current_action.is_empty(), "终局仍正常停止且没有后续动作")
	var final_starts: Array = _events(final_simulation, "start", 0).filter(func(entry: Dictionary): return entry.elapsed_s == final_simulation.elapsed_s)
	_check(final_starts.is_empty(), "终局边界不建立转瞬即被取消的新动作或消耗其随机数")
	var final_ended: Array = _instance_events(final_simulation, final_instance)
	_check(final_ended.size() == 1 and final_ended[0].type == "complete", "恰好到期的指令保留正常完成事实")
	return true


## 同组定时状态刷新到新完成时刻；动作绑定状态在真实打断时移除。
func _test_buff_lifetimes() -> bool:
	var simulation := _simulation()
	if simulation == null:
		return false
	if not _result(simulation.start_action(0, "sprint_study"), "真实开始冲刺状态", simulation.error_message):
		return false
	var instance_id: int = simulation.students[0].current_action.instance_id
	_check(simulation.students[0].buffs[0].action_instance_id == instance_id, "冲刺状态绑定正在运行的实例")
	if not _result(simulation.advance(60.0), "冲刺真实学习一分钟", simulation.error_message):
		return false
	_close(simulation.students[0].knowledge.chinese, 1.1, "动作状态实际进入学习效率计算")
	if not _result(simulation.start_action(0, "preview"), "预习真实打断冲刺", simulation.error_message):
		return false
	_check(not _has_buff(simulation, "sprinting"), "被打断冲刺的专注力修正实际清除")
	if not _result(simulation.advance(300.0), "预习真实完成", simulation.error_message):
		return false
	_close(simulation.effective_attribute(0, "attention"), 1.0, "完成预习状态实际修改有效属性")
	if not _result(simulation.start_action(0, "preview"), "再次真实预习", simulation.error_message) or not _result(simulation.advance(300.0), "第二次预习真实完成", simulation.error_message):
		return false
	var prepared: Array = simulation.students[0].buffs.filter(func(buff: Dictionary): return buff.buff_id == "prepared")
	if not _check(prepared.size() == 1, "刷新策略不叠加同组定时状态"):
		return false
	_close(prepared[0].expires_at, simulation.elapsed_s + configuration.buffs.prepared.duration_s, "状态到期从最新完成时刻计算")
	if not _result(simulation.advance(600.0), "真实推进到刷新后的状态到期", simulation.error_message):
		return false
	_check(not _has_buff(simulation, "prepared"), "定时状态实际到期，不靠界面隐藏冒充清除")
	return true


## 保存与恢复复用生产v4入口，在途消费和已抽时长不能再次执行。
func _test_save_roundtrip() -> bool:
	var original := _item_simulation("comic")
	if original == null or not _result(original.start_action(0, "read_comic_item"), "开始待保存物品动作", original.error_message):
		return false
	if not _result(original.advance(75.0), "保存前实际运行75秒", original.error_message):
		return false
	var save_path: String = _path("inflight.json")
	fixture_files.append(save_path + ".tmp")
	if not _result(original.save_file(save_path), "写入独占缓存真实存档", original.error_message):
		return false
	var read_log_position: int = original.logs.size()
	var restored := _simulation(11, 1, 28800.0, null, false)
	if restored == null or not _result(restored.load_file(save_path, false), "真实恢复v4在途存档", restored.error_message):
		return false
	_check(restored.logs.size() == read_log_position + 1 and restored.logs[read_log_position].type == "save", "读档只额外写入一条明确恢复日志")
	# 只从比对副本中去除已核验的读档提示，真实权威日志仍完整保留。
	var restored_state: Dictionary = _authority(restored)
	restored_state.logs.remove_at(read_log_position)
	_check(_same(_authority(original), restored_state), "恢复后完整权威状态、业务日志、库存和随机流一致")
	if not _result(original.advance(225.0), "原局真实完成剩余时长", original.error_message) or not _result(restored.advance(225.0), "恢复局真实完成剩余时长", restored.error_message):
		return false
	restored_state = _authority(restored)
	restored_state.logs.remove_at(read_log_position)
	_check(_same(_authority(original), restored_state), "两局完成结果与后续决策保持相同")
	_check(_events(restored, "consume_item", 0).size() == 1 and _has_buff(restored, "comic_afterglow"), "恢复不重复扣物，正常完成仍发真实状态")
	return true


## 后续费率立即采用新表，已抽时长和已成功消费保持；坏表拒绝不能留下半份配置。
func _test_hot_reload() -> bool:
	var simulation := _item_simulation("comic")
	if simulation == null:
		return false
	simulation.students[0].focus = 30.0
	if not _result(simulation.start_action(0, "read_comic_item"), "热改前真实开始阅读", simulation.error_message):
		return false
	if not _result(simulation.advance(60.0), "热改前真实恢复一分钟", simulation.error_message):
		return false
	_close(simulation.students[0].focus, 33.0, "热改前采用正式3%费率")
	var old_action: Dictionary = simulation.students[0].current_action.duplicate(true)
	var old_inventory: Dictionary = simulation.students[0].inventory.duplicate()
	var old_rng: int = simulation.rng.state
	var data: Dictionary = _config_data()
	for action: Dictionary in data.tables.actions:
		if action.id == "read_comic_item":
			action.duration_min_s = 720
			action.duration_max_s = 720
	_effect(data, "read_comic_item_tick_1").value = 0.06
	var changed: GameConfig = _load_config(data, "rates.json")
	if changed == null or not _result(simulation.apply_config(changed), "真实应用新费率", simulation.error_message):
		return false
	_check(simulation.students[0].current_action == old_action and simulation.students[0].inventory == old_inventory and simulation.rng.state == old_rng, "热改不改在途时长、不抽随机数、不重扣物")
	if not _result(simulation.advance(60.0), "新费率真实运行一分钟", simulation.error_message):
		return false
	_close(simulation.students[0].focus, 39.0, "后续连续恢复立即读取新6%费率")
	_check(_events(simulation, "consume_item", 0).size() == 1, "合法热改不重复消费")
	var invalid_data: Dictionary = _config_data()
	_effect(invalid_data, "read_comic_item_start_2").phase = "complete"
	var invalid: GameConfig = _load_config(invalid_data, "invalid_reload.json")
	if invalid == null:
		return false
	var before: Dictionary = _authority(simulation)
	_check(simulation.apply_config(invalid) != OK and simulation.config == changed, "不支持的完成阶段消费明确拒绝并保留旧配置")
	_check(_authority(simulation) == before, "坏表拒绝保留运行中的真实动作、资源、背包、日志和随机流")
	return true


## 配置副本只改变待测入口数据，非法阶段或数量不得静默忽略为可执行动作。
func _test_scope_rejection() -> bool:
	for invalid_value: Variant in [0, -1, 0.5, null]:
		var data: Dictionary = _config_data()
		_effect(data, "snack_self_start_2").value = invalid_value
		if not _scope_rejects(data, "quantity_%d.json" % checks, "物品消耗必须为正整数"):
			return false
	for invalid_phase: String in ["complete", "tick"]:
		var data: Dictionary = _config_data()
		var effect: Dictionary = _effect(data, "snack_self_start_2")
		effect.phase = invalid_phase
		effect.period_s = 60 if invalid_phase == "tick" else null
		if not _scope_rejects(data, "phase_%s.json" % invalid_phase, "物品只能在成功启动时消耗"):
			return false
	var data: Dictionary = _config_data()
	_effect(data, "snack_self_start_2").item_id = null
	if not _scope_rejects(data, "missing_item.json", "消耗不能缺少权威物品引用"):
		return false
	data = _config_data()
	_effect(data, "snack_self_start_2").recipient = "target"
	if not _scope_rejects(data, "wrong_recipient.json", "个人动作不能偷偷消耗另一个角色物品"):
		return false
	data = _config_data()
	_effect(data, "preview_complete_1").buff_id = "sprinting"
	if not _scope_rejects(data, "action_buff_at_complete.json", "动作绑定状态不能在旧动作完成时附着"):
		return false
	data = _config_data()
	_effect(data, "preview_complete_1").buff_id = "wrong_book"
	if not _scope_rejects(data, "unsupported_redirect.json", "未实现的知识重定向状态不能开放为假成功"):
		return false
	data = _config_data()
	_effect(data, "remind_self_complete_1").phase = "start"
	_effect(data, "remind_self_complete_1").sequence = 2
	if not _scope_rejects(data, "recursive_start.json", "开始阶段递归接续在入口明确拒绝"):
		return false
	return true


## 七天结束只取消未完成效果，消费不退款，查询和失败指令不改变被冻结的结果。
func _test_round_end() -> bool:
	var simulation := _item_simulation("comic", 7, 59980.0)
	if simulation == null or not _result(simulation.start_action(0, "read_comic_item"), "终局前真实开始物品阅读", simulation.error_message):
		return false
	var inventory_after_start: Dictionary = simulation.students[0].inventory.duplicate()
	var instance_id: int = simulation.students[0].current_action.instance_id
	if not _result(simulation.advance(20.0), "推进到正式第七天16:40终局", simulation.error_message):
		return false
	_check(simulation.is_round_finished() and simulation.students[0].current_action.is_empty(), "终局实际停止未完成动作")
	_check(simulation.students[0].inventory == inventory_after_start and not _has_buff(simulation, "comic_afterglow"), "终局不退物、不补发尚未完成的漫画状态")
	var ended: Array = _instance_events(simulation, instance_id)
	_check(ended.size() == 1 and ended[0].type == "interrupt", "终局物品动作仅实际打断一次")
	var before: Dictionary = _authority(simulation)
	_check(simulation.action_unavailable_reason(0, "eat_candy_item").contains("本局已结束"), "终局查询给出明确禁止新动作原因")
	_check(simulation.start_action(0, "read_comic_item") == ERR_UNAVAILABLE, "终局真实拒绝新物品指令")
	_check(_authority(simulation) == before, "终局拒绝不改变保存结果、背包、日志或随机流")
	return true


## 配置入口整体通过后仍必须由阶段执行器拒绝未实现的业务形式。
func _scope_rejects(data: Dictionary, filename: String, message: String) -> bool:
	var game_config: GameConfig = _load_config(data, filename)
	if game_config == null:
		return false
	var simulation := ClassroomSimulation.new()
	return _check(simulation.setup(game_config, 1) != OK and not simulation.error_message.is_empty(), message + "，且失败原因可见")


## 权威状态用于无副作用与原子性比对，不将预期变化的错误文本当成业务状态。
func _authority(simulation: ClassroomSimulation) -> Dictionary:
	return {
		"students": simulation.students.duplicate(true), "logs": simulation.logs.duplicate(true),
		"rng": simulation.rng.state, "next_action": simulation.next_action_number,
		"interactions": simulation.interactions.duplicate(true), "notes": simulation.notes.duplicate(true),
		"violations": simulation.violations.duplicate(true), "next_interaction": simulation.next_interaction_number,
		"next_violation": simulation.next_violation_number, "round": simulation.round_progression.data.duplicate(true),
		"day": simulation.day, "clock": simulation.clock_seconds, "elapsed": simulation.elapsed_s,
	}


## 日志只筛选真实执行器已经写入的事件，不生成测试业务结果。
func _events(simulation: ClassroomSimulation, event_type: String, student_index: int) -> Array:
	return simulation.logs.filter(func(entry: Dictionary): return entry.type == event_type and entry.student_index == student_index)


## 每个实例必须恰好拥有一个完成或打断记录。
func _instance_events(simulation: ClassroomSimulation, instance_id: int) -> Array:
	return simulation.logs.filter(func(entry: Dictionary): return entry.type in ["complete", "interrupt"] and int(entry.details.get("instance_id", -1)) == instance_id)


## 状态来源必须是动作实际施加的实例。
func _has_buff(simulation: ClassroomSimulation, buff_id: String) -> bool:
	return simulation.students[0].buffs.any(func(buff: Dictionary): return buff.buff_id == buff_id)


## 从权威JSON读取独立配置副本，测试修改不会写回正式文件。
func _config_data() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string("res://config/game_config.json"))


## 明确ID必须存在，缺少测试目标时立即暴露错误。
func _effect(data: Dictionary, effect_id: String) -> Dictionary:
	for effect: Dictionary in data.tables.effects:
		if effect.id == effect_id:
			return effect
	assert(false, "正式配置缺少待验证效果：" + effect_id)
	return {}


## 副本必须经过生产配置加载校验，不能直接拼接缓存冒充配置。
func _load_config(data: Dictionary, filename: String) -> GameConfig:
	var path: String = _path(filename)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not _check(file != null, "创建隔离配置副本"):
		return null
	file.store_string(JSON.stringify(data, "\t", true, true))
	file.close()
	var game_config := GameConfig.new()
	if not _result(game_config.load_file(path), "生产入口加载配置副本", game_config.error_message):
		return null
	return game_config


## 固定文件名只能位于本次独占目录，记录清理对象而不递归删除目录。
func _path(filename: String) -> String:
	var path: String = fixture_root.path_join(filename)
	if path not in fixture_files:
		fixture_files.append(path)
	return path


## JSON往返允许浮点表示误差，字段、整数及容器顺序必须保持真实一致。
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
	if left is int and right is int:
		return left == right
	if (left is int or left is float) and (right is int or right is float):
		return absf(float(left) - float(right)) < 0.0000000001
	return typeof(left) == typeof(right) and left == right


## 生产错误带出实际原因，依赖失败结果的场景立即返回。
func _result(result: Error, message: String, detail: String = "") -> bool:
	return _check(result == OK, "%s：错误码%d %s" % [message, result, detail])


## 连续积分只容许浮点表示误差，不改写被测结果。
func _close(actual: float, expected: float, message: String) -> void:
	_check(absf(actual - expected) < 0.000001, "%s：实际%s，预期%s" % [message, actual, expected])


## 只计数实际执行过的断言，失败不得由后续成功覆盖。
func _check(condition: bool, message: String) -> bool:
	checks += 1
	if not condition:
		failures.append(message)
	return condition


## 仅清理登记文件；失败保留独占证据并以非零退出，不访问正式玩家存档。
func _finish() -> void:
	for controller in owned_controllers:
		controller.free()
	if failures.is_empty():
		for path: String in fixture_files:
			if FileAccess.file_exists(path):
				_result(DirAccess.remove_absolute(path), "清理本次动作验证文件")
		if not fixture_root.is_empty():
			_result(DirAccess.remove_absolute(fixture_root), "清理动作验证独占目录")
	if failures.is_empty():
		print("SINGLE_PLAYER_ACTIONS_TEST_PASS checks=%d" % checks)
		quit(0)
	else:
		for message: String in failures:
			push_error(message)
		print("SINGLE_PLAYER_ACTIONS_TEST_FAIL checks=%d failures=%d fixtures=%s" % [checks, failures.size(), fixture_root])
		quit(1)
