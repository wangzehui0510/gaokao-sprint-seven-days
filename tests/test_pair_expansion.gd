extends SceneTree
## 双人扩展通过正式配置、真实课程奖励、共享行为树和生产执行器验收，不预填库存或成绩。

const PAIR_ACTIONS: Array[String] = [
	"remind_friend", "solve_together", "invite_playground", "invite_canteen",
	"borrow_notes", "encourage", "pillow_fight", "feed_snack", "use_eraser",
	"give_comic_item", "give_candy_item", "swap_book", "swap_book_boost", "arm_wrestle",
]
# 文件只写本进程独占缓存；真实用户目录和正式Excel、JSON始终不作为测试夹具。
var fixture_root: String = ""
var fixture_files: Array[String] = []
var configuration: GameConfig
var owned_controllers: Array[ClassroomBehaviorController] = []
var checks: int = 0
var failures: Array[String] = []


## 等场景树建立后执行，依赖错误不能跳过测试后误报通过。
func _initialize() -> void:
	call_deferred("_run")


## 每组返回确切完成标记，脚本中断或前置失败均不能冒充完整验收。
func _run() -> void:
	configuration = GameConfig.new()
	if not _result(configuration.load_file(), "加载正式配置", configuration.error_message):
		_finish()
		return
	fixture_root = OS.get_cache_dir().path_join("ClassroomPairExpansion_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	if not _result(DirAccess.make_dir_recursive_absolute(fixture_root), "建立双人扩展独占缓存"):
		_finish()
		return
	_check(_test_all_actions(), "14项双人动作均真实执行和完成")
	_check(_test_atomic_rejection(), "资源、物品、场景和选科不足统一原子拒绝")
	_check(_test_item_aggregation(), "双人扣物按角色和物品汇总后提交")
	_check(_test_pair_replacement(), "接管两组旧互动不影响新实例或补送旧纸条")
	_check(_test_interruption(), "消耗不退款，打断不发未完成资源或状态")
	_check(_test_completion_boundaries(), "完成接续服从切课和七天终局顺序")
	_check(_test_redirect_knowledge(), "偷换课本按实际所得科目入知识和日榜")
	_check(_test_redirect_replacement(), "普通和强化课本同组替换且正确到期")
	_check(_test_arm_wrestle(), "掰手腕使用扣费前体力快照并真实结算胜负")
	_check(_test_save_roundtrip(), "14项在途真实存读不重扣、不重抽或丢失效果")
	_check(_test_corrupt_snapshot(), "损坏选科、快照和胜负结果在覆盖有效局前拒绝")
	_check(_test_legacy_pair_snapshot(), "旧v4纸条和基础橡皮缺新增元数据仍可恢复")
	_check(_test_hot_reload(), "热改立即使用新费率并保留在途时长与扣物")
	_check(_test_scope_validation(), "不支持的效果和胜负契约在配置入口拒绝")
	_check(_test_view_projection(), "双人方向、状态和结果只取真实记录")
	_finish()


## 四棵真实树按正式课表启动，未启动树的夹具仅供生产存档入口恢复。
func _simulation(seed_value: int = 1, at_day: int = 1, seconds: float = 28800.0, game_config: GameConfig = null, start_tree: bool = true) -> ClassroomSimulation:
	var simulation := ClassroomSimulation.new()
	var loaded: GameConfig = configuration if game_config == null else game_config
	if not _result(simulation.setup(loaded, seed_value), "建立真实四人局", simulation.error_message):
		return null
	if not _result(simulation.set_debug_time(at_day, seconds), "定位真实课表", simulation.error_message):
		return null
	var controller := ClassroomBehaviorController.new()
	root.add_child(controller)
	controller.setup(simulation)
	owned_controllers.append(controller)
	simulation.decision_handler = controller.decide
	if start_tree and not _result(simulation.advance(0.0), "四人真实树开始活动", simulation.error_message):
		return null
	return simulation


## 固定夹具种子真实抽奖取得物品；未命中就明确失败，不写入虚构库存。
func _item_simulation(item_id: String, at_day: int = 1, seconds: float = 28800.0, game_config: GameConfig = null) -> ClassroomSimulation:
	for seed_value: int in [1, 2, 6, 3, 4, 5, 7, 8]:
		var simulation := _simulation(seed_value, at_day, seconds, game_config)
		if simulation == null:
			return null
		if int(simulation.students[0].inventory.get(item_id, 0)) > 0:
			_check(_events(simulation, "daily_items", 0).size() == 1, "物品%s来自本局真实课程奖池" % item_id)
			return simulation
	_check(false, "正式奖池固定夹具未实际获得物品：" + item_id)
	return null


## 显式列出正式表对应的整段净变化，避免用同一效果循环制造测试期望。
func _cases() -> Array[Dictionary]:
	return [
		{"id": "remind_friend", "own": [-3.0, 0.0], "target": [3.0, 0.0], "knowledge": 0.0},
		{"id": "solve_together", "own": [-11.0, -1.5], "target": [-6.0, -1.5], "knowledge": 6.5},
		{"id": "invite_playground", "own": [13.0, -6.0], "target": [18.0, -6.0], "knowledge": 0.0, "location": "playground"},
		{"id": "invite_canteen", "own": [0.0, 30.0], "target": [3.0, 30.0], "knowledge": 0.0, "location": "canteen"},
		{"id": "borrow_notes", "own": [-6.4, -0.6], "target": [-2.4, -0.6], "knowledge": 1.5, "own_buff": "note_borrowed"},
		{"id": "encourage", "own": [-3.0, 0.0], "target": [8.0, 0.0], "knowledge": 0.0, "target_buff": "encouraged"},
		{"id": "pillow_fight", "own": [6.0, -10.0], "target": [10.0, -10.0], "knowledge": 0.0, "seconds": 72000.0, "own_buff": "tired", "target_buff": "tired"},
		{"id": "feed_snack", "item": "snack", "own": [-2.0, 0.0], "target": [0.0, 15.0], "knowledge": 0.0},
		{"id": "use_eraser", "item": "eraser", "own": [-2.0, 0.0], "target": [-10.0, 0.0], "knowledge": 0.0},
		{"id": "give_comic_item", "item": "comic", "own": [13.0, -0.5], "target": [15.0, -0.5], "knowledge": 0.0, "own_buff": "comic_afterglow", "target_buff": "comic_afterglow"},
		{"id": "give_candy_item", "item": "candy", "own": [-2.0, 0.0], "target": [10.0, 0.0], "knowledge": 0.0},
		{"id": "swap_book", "subject": "math", "own": [-6.0, 0.0], "target": [0.0, 0.0], "knowledge": 0.0, "target_buff": "wrong_book"},
		{"id": "swap_book_boost", "subject": "math", "item": "book_cover", "own": [-6.0, 0.0], "target": [0.0, 0.0], "knowledge": 0.0, "target_buff": "wrong_book_boost"},
		{"id": "arm_wrestle", "own": [-1.0, -8.0], "target": [3.0, -8.0], "knowledge": 0.0},
	]


## 仅设置资源形成无截顶的可观察输入；库存、知识与结果始终由真实玩法产生。
func _case_simulation(scenario: Dictionary, at_day: int = 1) -> ClassroomSimulation:
	var seconds: float = scenario.get("seconds", 28800.0)
	var simulation: ClassroomSimulation = _item_simulation(scenario.item, at_day, seconds) if scenario.has("item") else _simulation(1, at_day, seconds)
	if simulation != null:
		for index: int in [0, 1]:
			simulation.students[index].focus = 70.0
			simulation.students[index].stamina = 40.0
	return simulation


## 双方各持一个真实动作，但费用、完成状态和业务结果均只能发生一次。
func _test_all_actions() -> bool:
	for scenario: Dictionary in _cases():
		var simulation := _case_simulation(scenario)
		if simulation == null:
			return false
		var before_knowledge: Array = [simulation.students[0].knowledge.duplicate(), simulation.students[1].knowledge.duplicate()]
		var before_inventory: Array = [simulation.students[0].inventory.duplicate(), simulation.students[1].inventory.duplicate()]
		var untouched: Dictionary = simulation.students[2].current_action.duplicate(true)
		var subject_id: String = scenario.get("subject", "")
		var before_query: Dictionary = _authority(simulation)
		_check(simulation.interaction_unavailable_reason(0, 1, scenario.id, subject_id).is_empty() and simulation.can_start_interaction(0, 1, scenario.id, subject_id), "正式动作可由统一入口发动：" + scenario.id)
		_check(_authority(simulation) == before_query, "双人可用性查询不改变任何权威结果")
		if not _result(simulation.start_interaction(0, 1, scenario.id, "", subject_id), "真实发动" + scenario.id, simulation.error_message):
			return false
		var interaction: Dictionary = simulation.interactions.back()
		var instances: Array = [simulation.students[0].current_action.duplicate(true), simulation.students[1].current_action.duplicate(true)]
		_check(instances[0].interaction_id == interaction.interaction_id and instances[1].interaction_id == interaction.interaction_id and instances[0].instance_id != instances[1].instance_id, "双方动作实例关联唯一互动")
		_close(interaction.duration_s, configuration.actions[scenario.id].duration_min_s, "时长读取正式配置")
		_check(interaction.result.is_empty(), "运行中不提前伪造完成胜负结果")
		if scenario.has("location"):
			for index: int in [0, 1]:
				_check(simulation.student_location(index) == scenario.location, "邀请双方真实到达目标场景：" + scenario.id)
			_check(simulation.get_open_violation(0).is_empty() and simulation.get_open_violation(1).is_empty(), "已离开课堂的邀请不保留课堂违纪")
		if scenario.has("item"):
			_check(simulation.students[0].inventory[scenario.item] == before_inventory[0][scenario.item] - 1, "只在成功开始时扣发起者一件真实物品")
			_check(simulation.students[1].inventory == before_inventory[1], "双人用物不擅自扣目标库存")
			var consumed: Array = _events(simulation, "consume_item", 0)
			_check(consumed.size() == 1 and consumed[0].details.item_id == scenario.item and consumed[0].details.quantity == 1, "真实扣物日志保留数量和物品身份")
		_check(simulation.students[2].current_action == untouched, "未参与者的动作不被互动启动覆盖")
		if not _result(simulation.advance(interaction.duration_s), "真实完成" + scenario.id, simulation.error_message):
			return false
		_check(interaction.status == "completed" and is_equal_approx(interaction.finished_at, interaction.ends_at), "互动历史只在真实完成边界写入完成")
		for index: int in [0, 1]:
			var ended: Array = _instance_events(simulation, instances[index].instance_id)
			if not _check(ended.size() == 1 and ended[0].type == "complete", "双方各自只正常结束一次：" + scenario.id):
				return false
			var expected: Array = scenario.own if index == 0 else scenario.target
			for resource_index: int in 2:
				var resource: String = ["focus", "stamina"][resource_index]
				_close(ended[0].details.resource_changes.get(resource, {}).get("actual", 0.0), expected[resource_index], "%s角色%d的%s整段实际变化" % [scenario.id, index, resource])
			_close(ended[0].details.knowledge_gain, scenario.knowledge, "%s角色%d真实知识倍率" % [scenario.id, index])
			for knowledge_id: String in simulation.students[index].knowledge:
				_close(simulation.students[index].knowledge[knowledge_id] - before_knowledge[index][knowledge_id], scenario.knowledge if knowledge_id == "chinese" else 0.0, "各科知识只增实际所得")
			_check(not simulation.students[index].current_action.has("interaction_id"), "完成后没有遗留双人占用")
		if scenario.has("own_buff"):
			_check(not _buff(simulation, 0, scenario.own_buff).is_empty(), "发起者获得真实完成状态：" + scenario.id)
		if scenario.has("target_buff"):
			var instance: Dictionary = _buff(simulation, 1, scenario.target_buff)
			_check(not instance.is_empty(), "目标获得真实完成状态：" + scenario.id)
			if not subject_id.is_empty():
				_check(instance.selected_subject_id == subject_id, "课本状态保留实际选定科目")
		_check(simulation.notes.is_empty(), "非纸条互动不伪造聊天送达")
	_check(PAIR_ACTIONS.size() == 14 and _cases().size() == PAIR_ACTIONS.size(), "扩展覆盖恰好14项")
	var simulation := _simulation()
	if simulation == null:
		return false
	_check(simulation.phase_scope.enabled_actions.size() == 49 and "answer_challenge" not in simulation.phase_scope.enabled_actions, "执行范围49项，未确认抢答仍关闭")
	_check(simulation.phase_scope.auto_actions == ["daydream", "sleep"] and simulation.phase_scope.subject_auto_actions == {"physical": ["playground_play"]}, "新增玩家互动不暗中改变NPC自主池")
	return true


## 不足与非法参数在打断双方、扣费、扣物和消耗随机流之前统一拒绝。
func _test_atomic_rejection() -> bool:
	var simulation := _simulation(8)
	if simulation == null or not _result(simulation.start_interaction(0, 1, "send_note", "前置失败时仍须保留的纸条"), "建立在途真实纸条", simulation.error_message):
		return false
	for scenario: Array in [
		["swap_book", ""], ["swap_book", "chinese"], ["swap_book", "physical"], ["swap_book", "missing"],
		["answer_challenge", ""], ["missing", ""], ["pillow_fight", ""], ["encourage", "math"],
	]:
		var before: Dictionary = _authority(simulation)
		var reason: String = simulation.interaction_unavailable_reason(0, 2, scenario[0], scenario[1])
		_check(not reason.is_empty() and not simulation.can_start_interaction(0, 2, scenario[0], scenario[1]), "非法选科、未开放或错误场景明确拒绝")
		_check(simulation.start_interaction(0, 2, scenario[0], "", scenario[1]) == ERR_UNAVAILABLE, "统一发动入口拒绝同一错误")
		_check(_authority(simulation) == before, "前置拒绝保留两位原参与者、纸条、日志和随机流")
	for action_id: String in ["feed_snack", "use_eraser", "swap_book_boost", "give_comic_item", "give_candy_item"]:
		var no_items := _simulation(1, 1, 28800.0, null, false)
		if no_items == null:
			return false
		var before: Dictionary = _authority(no_items)
		var reason: String = no_items.interaction_unavailable_reason(0, 1, action_id, "math" if action_id == "swap_book_boost" else "")
		_check(reason.contains("不足"), "真实空包明确说明缺少强化物品：" + action_id)
		_check(no_items.start_interaction(0, 1, action_id, "", "math" if action_id == "swap_book_boost" else "") == ERR_UNAVAILABLE, "物品不足不能降级到基础动作")
		_check(_authority(no_items) == before, "物品不足不收半份启动费或创建动作")
	simulation.students[2].stamina = 7.0
	var before: Dictionary = _authority(simulation)
	_check(simulation.interaction_unavailable_reason(0, 2, "arm_wrestle").contains("体力不足"), "掰手腕核验目标实际体力费用")
	_check(simulation.start_interaction(0, 2, "arm_wrestle") == ERR_UNAVAILABLE and _authority(simulation) == before, "目标支付不起时发起者也不扣费或离开旧纸条")
	simulation.students[0].focus = 2.0
	before = _authority(simulation)
	_check(simulation.start_interaction(0, 2, "solve_together") == ERR_UNAVAILABLE and _authority(simulation) == before, "发起者专注不足仍整体拒绝")
	for target_index: int in [-1, 0, 4]:
		before = _authority(simulation)
		_check(simulation.start_interaction(0, target_index, "encourage") == ERR_UNAVAILABLE and _authority(simulation) == before, "非法双人目标不会改变有效局")
	return true


## 配置副本要求同物两条消耗，真实奖品不足时不能先扣第一条或启动费。
func _test_item_aggregation() -> bool:
	var data: Dictionary = _config_data()
	var extra: Dictionary = _effect(data, "feed_snack_start_2").duplicate(true)
	extra.id = "feed_snack_start_3"
	extra.sequence = 3
	data.tables.effects.append(extra)
	var changed := _load_config(data, "aggregate.json")
	if changed == null:
		return false
	var simulation := _item_simulation("snack", 1, 28800.0, changed)
	if simulation == null:
		return false
	_check(simulation.students[0].inventory.snack == 1, "实际奖池夹具只领一份零食")
	var before: Dictionary = _authority(simulation)
	_check(simulation.interaction_unavailable_reason(0, 1, "feed_snack").contains("需要2件"), "双人同物消费在发动前汇总")
	_check(simulation.start_interaction(0, 1, "feed_snack") == ERR_UNAVAILABLE and _authority(simulation) == before, "两条消费不足拒绝不扣半件")
	for row: Dictionary in data.tables.drop_pool:
		row.quantity = 2
	changed = _load_config(data, "aggregate_rewards.json")
	if changed == null:
		return false
	simulation = _item_simulation("snack", 1, 28800.0, changed)
	if simulation == null or not _result(simulation.start_interaction(0, 1, "feed_snack"), "两份真实奖励支付两条消费", simulation.error_message):
		return false
	_check(simulation.students[0].inventory.snack == 0 and _events(simulation, "consume_item", 0).size() == 2, "成功后两条扣物日志与真实库存相符")
	return true


## 新动作接管两组旧互动，未参与的旧搭档由真实树回课表。
func _test_pair_replacement() -> bool:
	var simulation := _item_simulation("comic")
	if simulation == null:
		return false
	if not _result(simulation.start_interaction(0, 1, "send_note", "第一组未送达"), "建立第一组纸条", simulation.error_message):
		return false
	var first: Dictionary = simulation.interactions.back()
	if not _result(simulation.start_interaction(2, 3, "send_note", "第二组未送达"), "建立第二组纸条", simulation.error_message):
		return false
	var second: Dictionary = simulation.interactions.back()
	if not _result(simulation.advance(5.0), "两组真实执行五秒", simulation.error_message):
		return false
	if not _result(simulation.start_interaction(0, 2, "give_comic_item"), "新漫画接管两组旧参与者", simulation.error_message):
		return false
	var newest: Dictionary = simulation.interactions.back()
	_check(first.status == "interrupted" and second.status == "interrupted" and simulation.notes.is_empty(), "旧纸条整体打断且不补送")
	for index: int in [1, 3]:
		_check(simulation.students[index].current_action.action_id == "study" and not simulation.students[index].current_action.has("interaction_id"), "未参与新互动的旧搭档回真实课表")
	if not _result(simulation.advance(newest.duration_s), "新互动真实完成并跨过旧结束时刻", simulation.error_message):
		return false
	_check(newest.status == "completed" and first.status == "interrupted" and second.status == "interrupted" and simulation.notes.is_empty(), "旧完成处理不会覆盖新互动或补送纸条")
	_check(_events(simulation, "consume_item", 0).size() == 1, "接管两组只消费一次新物品")
	return true


## 部分执行后改为休息只保留已经发生变化，不退物也不发完成状态或胜负奖励。
func _test_interruption() -> bool:
	for scenario: Dictionary in _cases():
		var simulation := _case_simulation(scenario)
		if simulation == null:
			return false
		var selected_subject: String = scenario.get("subject", "")
		if not _result(simulation.start_interaction(0, 1, scenario.id, "", selected_subject), "开始待中断互动：" + scenario.id, simulation.error_message):
			return false
		var interaction: Dictionary = simulation.interactions.back()
		var inventory_after_start: Array = [simulation.students[0].inventory.duplicate(), simulation.students[1].inventory.duplicate()]
		if not _result(simulation.advance(interaction.duration_s / 2.0), "真实执行一半互动", simulation.error_message):
			return false
		var before_target: Dictionary = simulation.students[1].duplicate(true)
		if not _result(simulation.start_action(0, "rest"), "真实休息中断双人动作", simulation.error_message):
			return false
		_check(interaction.status == "interrupted" and interaction.result.is_empty(), "未完成动作没有伪造胜负或完成状态")
		for index: int in [0, 1]:
			_check(simulation.students[index].inventory == inventory_after_start[index], "打断不退已经扣掉的真实物品")
			_check(not simulation.students[index].current_action.has("interaction_id"), "打断后双方均解除旧互动")
		for buff_id: String in ["note_borrowed", "encouraged", "tired", "comic_afterglow", "wrong_book", "wrong_book_boost"]:
			_check(_buff(simulation, 0, buff_id).is_empty() and _buff(simulation, 1, buff_id).is_empty(), "打断不提前发完成状态：" + buff_id)
		var target_focus_after: float = simulation.students[1].focus
		_check(target_focus_after <= before_target.focus, "目标只可能支付回课程自然入段费用，不补完成专注奖励")
		_close(simulation.students[1].stamina, before_target.stamina, "打断不补完成型体力恢复")
	return true


## 目标强制回课表发生在完成清理之后，同刻切课只接续一次，终局不再开段。
func _test_completion_boundaries() -> bool:
	var boundary: float = roundf(configuration.indexes.periods.lesson_1.end_time * 86400.0)
	var simulation := _simulation(1, 1, boundary - 60.0)
	if simulation == null:
		return false
	simulation.students[1].focus = 20.0
	if not _result(simulation.start_interaction(0, 1, "remind_friend"), "换课前真实提醒同学", simulation.error_message):
		return false
	var interaction: Dictionary = simulation.interactions.back()
	if not _result(simulation.advance(60.0), "提醒恰好在换课边界完成", simulation.error_message):
		return false
	_check(interaction.status == "completed", "完成与切课同刻仍记真实完成")
	for index: int in [0, 1]:
		var starts: Array = _events(simulation, "start", index).filter(func(entry: Dictionary): return entry.elapsed_s == simulation.elapsed_s)
		_check(starts.size() == 1 and simulation.students[index].current_action.action_id == "break_rest", "同刻每人只接续一次当前课间")
	_check(not simulation.students[1].current_action.natural_entry, "目标保留效果指定的强制入段方式")
	_close(simulation.students[1].focus, 23.0, "提醒完成恢复一次且不重复收自然费")
	var terminal := _simulation(1, 7, 59940.0)
	if terminal == null or not _result(terminal.start_interaction(0, 1, "remind_friend"), "终局前真实提醒", terminal.error_message):
		return false
	interaction = terminal.interactions.back()
	if not _result(terminal.advance(60.0), "提醒与终局同刻完成", terminal.error_message):
		return false
	_check(terminal.is_round_finished() and interaction.status == "completed", "终局保留恰好完成的双人事实")
	for index: int in 4:
		_check(terminal.students[index].current_action.is_empty(), "终局清空全部在途动作")
		_check(_events(terminal, "start", index).filter(func(entry: Dictionary): return entry.elapsed_s == terminal.elapsed_s).is_empty(), "终局不短暂创建接续动作或消耗其随机数")
	var unfinished := _item_simulation("comic", 7, 59970.0)
	if unfinished == null or not _result(unfinished.start_interaction(0, 1, "give_comic_item"), "终局前开始未完成的真实漫画", unfinished.error_message):
		return false
	interaction = unfinished.interactions.back()
	var after_inventory: Dictionary = unfinished.students[0].inventory.duplicate()
	if not _result(unfinished.advance(30.0), "未完成漫画跨到终局", unfinished.error_message):
		return false
	_check(interaction.status == "interrupted" and unfinished.students[0].inventory == after_inventory, "终局取消未完成互动且不退款")
	_check(_buff(unfinished, 0, "comic_afterglow").is_empty() and _buff(unfinished, 1, "comic_afterglow").is_empty(), "终局不补漫画完成状态")
	var before: Dictionary = _authority(unfinished)
	_check(unfinished.start_interaction(0, 1, "encourage") == ERR_UNAVAILABLE and _authority(unfinished) == before, "终局拒绝新互动并保留冻结权威结果")
	return true


## 课本选择只改变后续所得科目，源课速率、实际总知识和日榜增量保持一致。
func _test_redirect_knowledge() -> bool:
	var simulation := _simulation()
	if simulation == null or not _result(simulation.start_interaction(0, 1, "swap_book", "", "math"), "真实偷换为数学课本", simulation.error_message):
		return false
	if not _result(simulation.advance(120.0), "偷换实际完成", simulation.error_message):
		return false
	var status: Dictionary = _buff(simulation, 1, "wrong_book")
	if not _check(not status.is_empty() and status.selected_subject_id == "math", "真实目标状态携带数学选择"):
		return false
	_close(simulation.effective_attribute(1, "intelligence"), -1.0, "课本状态真实降低有效智力一次")
	var chinese_before: float = simulation.students[1].knowledge.chinese
	var math_before: float = simulation.students[1].knowledge.math
	if not _result(simulation.start_action(1, "study", false), "目标按当前课程真实学习", simulation.error_message):
		return false
	if not _result(simulation.advance(60.0), "拿错课本真实学习一分钟", simulation.error_message):
		return false
	_close(simulation.students[1].knowledge.chinese, chinese_before, "拿错课本时不额外增加源课知识")
	_close(simulation.students[1].knowledge.math - math_before, 1.0, "按当前语文基速记入实际数学")
	_close(simulation.round_progression.data.daily_days["1"].gains.student_1.math, simulation.students[1].knowledge.math, "日榜账本记真实所得数学")
	_close(simulation.round_progression.data.daily_days["1"].gains.student_1.chinese, simulation.students[1].knowledge.chinese, "源科日榜没有重复入账")
	var expired_at: float = status.expires_at
	if not _result(simulation.advance(expired_at - simulation.elapsed_s), "真实推进到课本状态到期", simulation.error_message):
		return false
	_check(_buff(simulation, 1, "wrong_book").is_empty(), "课本重定向在真实到期边界清除")
	var math_at_expiry: float = simulation.students[1].knowledge.math
	chinese_before = simulation.students[1].knowledge.chinese
	if not _result(simulation.start_action(1, "study", false), "状态到期后真实回源科", simulation.error_message) or not _result(simulation.advance(60.0), "到期后真实学习一分钟", simulation.error_message):
		return false
	_close(simulation.students[1].knowledge.math, math_at_expiry, "到期后保留过去已获数学且不再继续重定向")
	_close(simulation.students[1].knowledge.chinese - chinese_before, 1.0, "到期后恢复当前课程知识归属")
	# 音乐课中仍可完成选科动作，但恢复课程没有知识，不能凭空产生重定向收益。
	var recovery := _simulation(1, 1, 50400.0)
	if recovery == null:
		return false
	if recovery.course_context().subject_kind != "recovery":
		for row: Dictionary in configuration.tables.schedule:
			if int(row.day) == 1 and configuration.subjects[row.subject_id].kind == "recovery":
				var period: Dictionary = configuration.indexes.periods[row.period_id]
				if not _result(recovery.set_debug_time(1, roundf(period.start_time * 86400.0)), "定位真实恢复课", recovery.error_message) or not _result(recovery.advance(0.0), "恢复课真实入段", recovery.error_message):
					return false
				break
	if not _check(recovery.course_context().subject_kind == "recovery", "正式课表确有恢复课供验收"):
		return false
	if not _result(recovery.start_interaction(0, 1, "swap_book", "", "math"), "恢复课完成真实偷书", recovery.error_message) or not _result(recovery.advance(120.0), "恢复课偷书真实完成", recovery.error_message):
		return false
	var knowledge_before: Dictionary = recovery.students[1].knowledge.duplicate()
	if not _result(recovery.advance(60.0), "恢复课带真实重定向状态运行一分钟", recovery.error_message):
		return false
	_check(recovery.students[1].knowledge == knowledge_before, "音乐美术不能因重定向凭空产生知识")
	return true


## 两种真实课本效果同组替换，保持后一次选择且智力惩罚不叠加。
func _test_redirect_replacement() -> bool:
	var simulation := _item_simulation("book_cover")
	if simulation == null:
		return false
	if not _result(simulation.start_interaction(0, 1, "swap_book", "", "math"), "先发动普通课本", simulation.error_message) or not _result(simulation.advance(120.0), "普通课本实际完成", simulation.error_message):
		return false
	if not _result(simulation.start_interaction(0, 1, "swap_book_boost", "", "english"), "真实强化课本覆盖普通版", simulation.error_message) or not _result(simulation.advance(120.0), "强化课本实际完成", simulation.error_message):
		return false
	var status: Dictionary = _buff(simulation, 1, "wrong_book_boost")
	_check(_buff(simulation, 1, "wrong_book").is_empty() and not status.is_empty() and status.selected_subject_id == "english", "强化替换普通版并保留最后一次科目")
	_close(simulation.effective_attribute(1, "intelligence"), -1.0, "同组替换不会叠加两次智力惩罚")
	_close(status.expires_at, simulation.elapsed_s + 720.0, "强化实际到期读取十二分钟配置")
	if not _result(simulation.start_interaction(0, 1, "swap_book", "", "math"), "普通课本再覆盖强化版", simulation.error_message) or not _result(simulation.advance(120.0), "替换动作真实完成", simulation.error_message):
		return false
	status = _buff(simulation, 1, "wrong_book")
	_check(_buff(simulation, 1, "wrong_book_boost").is_empty() and status.selected_subject_id == "math", "后普通版可替换强化版而非静默择强保留")
	_close(status.expires_at, simulation.elapsed_s + 480.0, "替换后采用实际普通八分钟到期")
	return true


## 判胜依据扣费前的真实资源；完成前资源变化和恢复存档不能改变已取快照。
func _test_arm_wrestle() -> bool:
	for scenario: Dictionary in [
		{"own": 70.0, "target": 40.0, "outcome": "initiator", "winner": 0, "loser": 1, "gain": [6.0, 0.0]},
		{"own": 30.0, "target": 60.0, "outcome": "target", "winner": 1, "loser": 0, "gain": [0.0, 6.0]},
		{"own": 40.0, "target": 40.0, "outcome": "tie", "winner": -1, "loser": -1, "gain": [3.0, 3.0]},
	]:
		var simulation := _simulation()
		if simulation == null:
			return false
		simulation.students[0].focus = 60.0
		simulation.students[1].focus = 60.0
		simulation.students[0].stamina = scenario.own
		simulation.students[1].stamina = scenario.target
		if not _result(simulation.start_interaction(0, 1, "arm_wrestle"), "真实发动胜负样本", simulation.error_message):
			return false
		var interaction: Dictionary = simulation.interactions.back()
		var instance_ids: Array[int] = [simulation.students[0].current_action.instance_id, simulation.students[1].current_action.instance_id]
		_check(interaction.stamina_snapshot == {"initiator": scenario.own, "target": scenario.target}, "发动时快照使用扣费前体力")
		_close(simulation.students[0].stamina, scenario.own - 8.0, "发起者成功发动实际扣八体力")
		_close(simulation.students[1].stamina, scenario.target - 8.0, "目标成功发动实际扣八体力")
		if not _result(simulation.advance(60.0), "胜负动作真实执行一半", simulation.error_message):
			return false
		_check(interaction.result.is_empty(), "完成前结果为空且未发胜负奖励")
		# 这是完成前资源变化输入，不能替代或预先写入胜负业务结果。
		simulation.students[0].stamina = 1.0
		simulation.students[1].stamina = 99.0
		if not _result(simulation.advance(60.0), "胜负动作真实完成", simulation.error_message):
			return false
		_check(interaction.result.outcome == scenario.outcome and interaction.result.winner_index == scenario.winner and interaction.result.loser_index == scenario.loser, "真实胜负仍采用已保存发动快照")
		for index: int in [0, 1]:
			var events: Array = _instance_events(simulation, instance_ids[index])
			if not _check(events.size() == 1 and events[0].type == "complete", "掰手腕双方各正常完成一次"):
				return false
			_close(events[0].details.resource_changes.get("focus", {}).get("actual", 0.0), scenario.gain[index] - (4.0 if index == 0 else 0.0), "胜者或平局奖励只实际发放一次")
		_check(simulation.notes.is_empty(), "胜负结果不会伪造聊天消息")
	return true


## 每项在途先通过生产保存，再恢复并沿原时长完成；日志提示外的权威内容应相同。
func _test_save_roundtrip() -> bool:
	for scenario: Dictionary in _cases():
		var original := _case_simulation(scenario)
		if original == null or not _result(original.start_interaction(0, 1, scenario.id, "", scenario.get("subject", "")), "开始待保存的真实双人动作", original.error_message):
			return false
		var interaction: Dictionary = original.interactions.back()
		if not _result(original.advance(interaction.duration_s / 3.0), "保存前真实运行三分之一", original.error_message):
			return false
		var path: String = _path("roundtrip_" + scenario.id + ".json")
		if not _result(original.save_file(path), "保存真实在途动作：" + scenario.id, original.error_message):
			return false
		var restored := _simulation(71, 1, 28800.0, null, false)
		if restored == null or not _result(restored.load_file(path, false), "生产入口恢复：" + scenario.id, restored.error_message):
			return false
		var restore_log: int = original.logs.size()
		_check(restored.logs.size() == restore_log + 1 and restored.logs[restore_log].type == "save", "恢复只增加明确读档提示")
		var restored_state: Dictionary = _authority(restored)
		restored_state.logs.remove_at(restore_log)
		_check(_same(_authority(original), restored_state), "在途恢复保持双方、库存、Buff、选科、快照与随机流")
		var remaining: float = interaction.ends_at - original.elapsed_s
		if not _result(original.advance(remaining), "原局真实完成剩余时长", original.error_message) or not _result(restored.advance(remaining), "恢复局真实完成剩余时长", restored.error_message):
			return false
		restored_state = _authority(restored)
		restored_state.logs.remove_at(restore_log)
		_check(_same(_authority(original), restored_state), "恢复后完整完成结果与后续真实决策相同：" + scenario.id)
		if scenario.has("item"):
			_check(_events(restored, "consume_item", 0).size() == 1, "恢复不重复扣物")
	return true


## 损坏只发生在已真实保存的隔离副本；失败必须保留正在运行的有效局。
func _test_corrupt_snapshot() -> bool:
	var source := _simulation()
	if source == null or not _result(source.start_interaction(0, 1, "swap_book", "", "math"), "建立选科存档校验样本", source.error_message):
		return false
	var active: Dictionary = _snapshot(source, "swap_active.json")
	if active.is_empty():
		return false
	var cases: Array[Dictionary] = []
	for invalid_subject: Variant in [null, "", "physical", "music", "missing"]:
		var changed: Dictionary = active.duplicate(true)
		changed.interactions[0].selected_subject_id = invalid_subject
		cases.append(changed)
	var missing_subject: Dictionary = active.duplicate(true)
	missing_subject.interactions[0].erase("selected_subject_id")
	cases.append(missing_subject)
	var premature_result: Dictionary = active.duplicate(true)
	premature_result.interactions[0].result = {"outcome": "tie", "winner_index": -1, "loser_index": -1}
	cases.append(premature_result)
	if not _result(source.advance(120.0), "真实完成后保存目标选科状态", source.error_message):
		return false
	var completed: Dictionary = _snapshot(source, "swap_completed.json")
	for invalid_subject: Variant in [null, "", "physical", "missing"]:
		var changed: Dictionary = completed.duplicate(true)
		changed.students[1].buffs[0].selected_subject_id = invalid_subject
		cases.append(changed)
	var missing_buff_subject: Dictionary = completed.duplicate(true)
	missing_buff_subject.students[1].buffs[0].erase("selected_subject_id")
	cases.append(missing_buff_subject)
	var arm := _simulation()
	if arm == null or not _result(arm.start_interaction(0, 1, "arm_wrestle"), "建立体力快照校验样本", arm.error_message):
		return false
	active = _snapshot(arm, "arm_active.json")
	var missing_snapshot: Dictionary = active.duplicate(true)
	missing_snapshot.interactions[0].erase("stamina_snapshot")
	cases.append(missing_snapshot)
	for invalid_value: Variant in [-1.0, "99", null]:
		var changed: Dictionary = active.duplicate(true)
		changed.interactions[0].stamina_snapshot.initiator = invalid_value
		cases.append(changed)
	var extra_snapshot: Dictionary = active.duplicate(true)
	extra_snapshot.interactions[0].stamina_snapshot.target = -0.1
	cases.append(extra_snapshot)
	if not _result(arm.advance(120.0), "真实完成后保存掰手腕结果", arm.error_message):
		return false
	completed = _snapshot(arm, "arm_completed.json")
	for invalid_result: Dictionary in [
		{}, {"outcome": "initiator", "winner_index": 1, "loser_index": 0},
		{"outcome": "tie", "winner_index": 0, "loser_index": 1},
		{"outcome": "missing", "winner_index": -1, "loser_index": -1},
	]:
		var changed: Dictionary = completed.duplicate(true)
		changed.interactions[0].result = invalid_result
		cases.append(changed)
	var receiver := _simulation()
	if receiver == null:
		return false
	var before: Dictionary = _authority(receiver)
	for index: int in cases.size():
		var path: String = _path("corrupt_%d.json" % index)
		if not _write_json(path, cases[index]):
			return false
		_check(receiver.load_file(path, false) != OK and not receiver.error_message.is_empty(), "损坏双人元数据%d必须可见拒绝" % index)
		_check(_authority(receiver) == before, "坏档%d不得覆盖有效局或部分写入资源" % index)
	return true


## 旧版本没有扩展元数据时显式迁移已有纸条和橡皮，不把新动作缺字段也视作旧档。
func _test_legacy_pair_snapshot() -> bool:
	for action_id: String in ["send_note", "eraser_prank"]:
		var original := _simulation()
		if original == null or not _result(original.start_interaction(0, 1, action_id, "旧v4原纸条" if action_id == "send_note" else ""), "建立旧动作真实保存来源", original.error_message):
			return false
		if not _result(original.advance(5.0), "旧动作真实运行五秒", original.error_message):
			return false
		var snapshot: Dictionary = _snapshot(original, "old_source_" + action_id + ".json")
		for interaction: Dictionary in snapshot.interactions:
			for key: String in ["selected_subject_id", "stamina_snapshot", "result"]:
				interaction.erase(key)
		var path: String = _path("old_v4_" + action_id + ".json")
		if not _write_json(path, snapshot):
			return false
		var restored := _simulation(1, 1, 28800.0, null, false)
		if restored == null or not _result(restored.load_file(path, false), "恢复缺新增字段的旧v4：" + action_id, restored.error_message):
			return false
		_check(restored.students[0].current_action.interaction_id == original.students[0].current_action.interaction_id and restored.rng.state == original.rng.state, "旧动作迁移保留原实例和随机流")
		if not _result(restored.advance(original.interactions[0].ends_at - original.elapsed_s), "旧动作恢复后真实完成", restored.error_message):
			return false
		_check(restored.interactions[0].status == "completed", "迁移不取消仍在同课内运行的合法双人动作")
		_check(restored.notes.size() == (1 if action_id == "send_note" else 0), "旧纸条只正常送达一次，橡皮不制造聊天")
	return true


## 后续费率立刻生效，但已消费的物品、随机流与双人结束时间不重新执行。
func _test_hot_reload() -> bool:
	var simulation := _item_simulation("comic")
	if simulation == null:
		return false
	simulation.students[0].focus = 30.0
	simulation.students[1].focus = 30.0
	if not _result(simulation.start_interaction(0, 1, "give_comic_item"), "热改前真实看漫画", simulation.error_message) or not _result(simulation.advance(60.0), "旧费率真实运行一分钟", simulation.error_message):
		return false
	_close(simulation.students[0].focus, 31.0, "发起者先付二再按正式3%恢复")
	_close(simulation.students[1].focus, 33.0, "目标按正式3%恢复")
	var old_action: Array = [simulation.students[0].current_action.duplicate(true), simulation.students[1].current_action.duplicate(true)]
	var inventory: Dictionary = simulation.students[0].inventory.duplicate()
	var random_state: int = simulation.rng.state
	var data: Dictionary = _config_data()
	_effect(data, "give_comic_item_tick_1").value = 0.06
	for row: Dictionary in data.tables.actions:
		if row.id == "give_comic_item":
			row.duration_min_s = 720
			row.duration_max_s = 720
	var changed := _load_config(data, "hot_rates.json")
	if changed == null or not _result(simulation.apply_config(changed), "接管双人新费率", simulation.error_message):
		return false
	_check(simulation.students[0].current_action == old_action[0] and simulation.students[1].current_action == old_action[1] and simulation.students[0].inventory == inventory and simulation.rng.state == random_state, "合法热改保留双人时长、扣物和随机流")
	if not _result(simulation.advance(60.0), "双人按新费率真实运行一分钟", simulation.error_message):
		return false
	_close(simulation.students[0].focus, 37.0, "发起者后续采用6%")
	_close(simulation.students[1].focus, 39.0, "目标后续采用6%且不重复执行")
	_check(_events(simulation, "consume_item", 0).size() == 1, "热改不重复消费漫画")
	var invalid_data: Dictionary = _config_data()
	_effect(invalid_data, "give_comic_item_start_2").phase = "complete"
	var invalid := _load_config(invalid_data, "hot_invalid.json")
	if invalid == null:
		return false
	var before: Dictionary = _authority(simulation)
	_check(simulation.apply_config(invalid) != OK and simulation.config == changed and _authority(simulation) == before, "非法后置消费明确拒绝，保留有效配置与在途局")
	var redirect := _simulation()
	if redirect == null or not _result(redirect.start_interaction(0, 1, "swap_book", "", "math"), "建立热改中真实课本状态", redirect.error_message) or not _result(redirect.advance(120.0), "课本真实生效", redirect.error_message):
		return false
	invalid_data = _config_data()
	for row: Dictionary in invalid_data.tables.buffs:
		if row.id == "wrong_book":
			row.knowledge_redirect = "none"
	invalid = _load_config(invalid_data, "hot_redirect_mode.json")
	if invalid == null:
		return false
	before = _authority(redirect)
	var old_config: RefCounted = redirect.config
	_check(redirect.apply_config(invalid) != OK and redirect.config == old_config and _authority(redirect) == before, "生效课本不能热改丢失选择或改变状态语义")
	return true


## 共享入口校验必须拒绝未实现枚举、非启动扣物和无胜负解析事件的效果表。
func _test_scope_validation() -> bool:
	for scenario: String in [
		"item_complete", "conditional_resolution", "missing_resolution", "reward_before_resolution",
		"wrong_recipient", "action_buff_at_complete", "duplicate_remind_route",
		"remind_route_before_resource", "split_payer_item_overflow",
		"redirect_independent", "redirect_separate_groups",
	]:
		var data: Dictionary = _config_data()
		match scenario:
			"item_complete":
				_effect(data, "feed_snack_start_2").phase = "complete"
			"conditional_resolution":
				_effect(data, "arm_wrestle_complete_1").condition = "winner"
			"missing_resolution":
				data.tables.effects = data.tables.effects.filter(func(row: Dictionary): return row.id != "arm_wrestle_complete_1")
			"reward_before_resolution":
				_effect(data, "arm_wrestle_complete_1").sequence = 2
				_effect(data, "arm_wrestle_complete_2").sequence = 1
			"wrong_recipient":
				_effect(data, "feed_snack_start_2").recipient = "ally"
			"action_buff_at_complete":
				_effect(data, "encourage_complete_2").buff_id = "sprinting"
			"duplicate_remind_route":
				var extra: Dictionary = _effect(data, "remind_friend_complete_2").duplicate(true)
				extra.id = "remind_friend_complete_3"
				extra.sequence = 3
				data.tables.effects.append(extra)
			"remind_route_before_resource":
				_effect(data, "remind_friend_complete_2").sequence = 1
				_effect(data, "remind_friend_complete_1").sequence = 2
			"split_payer_item_overflow":
				var first: Dictionary = _effect(data, "feed_snack_start_2")
				first.recipient = "both"
				first.value = 6000000000000000000
				var extra: Dictionary = first.duplicate(true)
				extra.id = "feed_snack_start_3"
				extra.sequence = 3
				extra.recipient = "self"
				data.tables.effects.append(extra)
			"redirect_independent":
				for buff: Dictionary in data.tables.buffs:
					if buff.id == "wrong_book":
						buff.stacking = "independent"
			"redirect_separate_groups":
				for buff: Dictionary in data.tables.buffs:
					if buff.id == "wrong_book_boost":
						buff.stack_group = "another_wrong_book"
		var changed := _load_config(data, "invalid_scope_" + scenario + ".json")
		if changed == null:
			return false
		var probe := ClassroomSimulation.new()
		_check(probe.setup(changed, 1) != OK and not probe.error_message.is_empty(), "执行契约在入口明确拒绝：" + scenario)
	return true


## 画面只读取真实记录；帧时钟、相机和重复刷新不能发奖、改知识或伪造受击。
func _test_view_projection() -> bool:
	for scenario: Dictionary in _cases():
		var simulation := _case_simulation(scenario)
		if simulation == null or not _result(simulation.start_interaction(0, 1, scenario.id, "", scenario.get("subject", "")), "视图对应真实互动开始", simulation.error_message):
			return false
		var interaction: Dictionary = simulation.interactions.back()
		var room := ClassroomView.new()
		room.size = Vector2(384, 256)
		root.add_child(room)
		room.set_process(false)
		room.set_view_location("auto")
		room.bind_game(simulation)
		var before: Dictionary = _authority(simulation)
		room.refresh_state()
		_check(room.visual_students[0].status.contains("→") and room.visual_students[1].status.contains("←"), "画面双方方向来自真实参与者：" + scenario.id)
		_check(room.visual_students[0].action == configuration.actions[scenario.id].name, "画面动作名来自正式配置")
		room._process(123.0)
		_check(_authority(simulation) == before, "视觉帧不推进任何权威业务")
		_check(room.visual_outcomes.is_empty() and room.visual_impacts.is_empty(), "执行中不提前显示结果或橡皮受击")
		if not _result(simulation.advance(interaction.duration_s), "视图等待真实完成", simulation.error_message):
			room.free()
			return false
		before = _authority(simulation)
		room.refresh_state()
		var outcomes: Array = room.visual_outcomes.filter(func(row: Dictionary): return row.interaction_id == interaction.interaction_id)
		_check(outcomes.size() == 1 and outcomes[0].status == "completed" and outcomes[0].action_name == configuration.actions[scenario.id].name, "短暂完成提示关联真实动作与完成事实")
		_check(room.visual_impacts.size() == (1 if scenario.id == "use_eraser" else 0), "只有真实完成的强化橡皮产生目标受击")
		_check(_authority(simulation) == before, "结果刷新不改变库存、资源、日志或随机流")
		room.free()
	return true


## 完整权威状态用于原子性比对，允许变化的错误文本不属于业务结果。
func _authority(simulation: ClassroomSimulation) -> Dictionary:
	return {
		"students": simulation.students.duplicate(true), "logs": simulation.logs.duplicate(true),
		"interactions": simulation.interactions.duplicate(true), "notes": simulation.notes.duplicate(true),
		"violations": simulation.violations.duplicate(true), "rng": simulation.rng.state,
		"next_action": simulation.next_action_number, "next_interaction": simulation.next_interaction_number,
		"next_violation": simulation.next_violation_number, "day": simulation.day,
		"clock": simulation.clock_seconds, "elapsed": simulation.elapsed_s,
		"round": simulation.round_progression.data.duplicate(true),
	}


## 业务日志只能读取生产执行器已写入的真实记录。
func _events(simulation: ClassroomSimulation, event_type: String, student_index: int) -> Array:
	return simulation.logs.filter(func(entry: Dictionary): return entry.type == event_type and entry.student_index == student_index)


## 确切实例应只有一个结束事实，不能靠动作名称混入后续实例。
func _instance_events(simulation: ClassroomSimulation, instance_id: int) -> Array:
	return simulation.logs.filter(func(entry: Dictionary): return entry.type in ["complete", "interrupt"] and int(entry.details.get("instance_id", -1)) == instance_id)


## 状态查询只取生产施加的现存实例，不构造替代Buff。
func _buff(simulation: ClassroomSimulation, index: int, buff_id: String) -> Dictionary:
	for instance: Dictionary in simulation.students[index].buffs:
		if instance.buff_id == buff_id:
			return instance
	return {}


## 正式JSON仅读取为副本；测试热改不会写回权威源文件。
func _config_data() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string("res://config/game_config.json"))


## 配置中的效果身份必须存在，夹具失效立即暴露。
func _effect(data: Dictionary, effect_id: String) -> Dictionary:
	for effect: Dictionary in data.tables.effects:
		if effect.id == effect_id:
			return effect
	assert(false, "正式配置缺少待测效果：" + effect_id)
	return {}


## 配置副本也通过生产加载入口校验，不能直接更换运行时索引。
func _load_config(data: Dictionary, filename: String) -> GameConfig:
	var path: String = _path(filename)
	if not _write_json(path, data):
		return null
	var result := GameConfig.new()
	if not _result(result.load_file(path), "生产入口读取隔离配置", result.error_message):
		return null
	return result


## 保存夹具必须从真实局产生，仅损坏用例在取得副本后修改。
func _snapshot(simulation: ClassroomSimulation, filename: String) -> Dictionary:
	var path: String = _path(filename)
	if not _result(simulation.save_file(path), "生产入口生成真实存档", simulation.error_message):
		return {}
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not _check(data is Dictionary, "真实保存结果为完整JSON对象"):
		return {}
	return data


## 所有文件名都登记到独占目录，清理不使用递归删除或猜测路径。
func _path(filename: String) -> String:
	var path: String = fixture_root.path_join(filename)
	if path not in fixture_files:
		fixture_files.append(path)
	return path


## 只在本进程缓存写入副本，失败会明确累计为失败断言。
func _write_json(path: String, data: Dictionary) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not _check(file != null, "写入隔离副本：" + path):
		return false
	file.store_string(JSON.stringify(data, "\t", true, true))
	file.close()
	return true


## JSON往返只允许数值表示误差，整数、键、数组顺序与随机流均保持精确。
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


## 生产错误消息保留在断言中，前置失败时立即停止依赖它的本组场景。
func _result(result: Error, message: String, detail: String = "") -> bool:
	return _check(result == OK, "%s：错误码%d %s" % [message, result, detail])


## 浮点容差仅处理连续积分舍入，不改写执行器结果。
func _close(actual: float, expected: float, message: String) -> void:
	_check(absf(actual - expected) < 0.000001, "%s：实际%s，预期%s" % [message, actual, expected])


## 只计实际执行断言，后续成功不能覆盖已发生失败。
func _check(condition: bool, message: String) -> bool:
	checks += 1
	if not condition:
		failures.append(message)
	return condition


## 失败保留独占证据，成功仅清理已登记文件；从不访问正式存档。
func _finish() -> void:
	for controller in owned_controllers:
		controller.free()
	if failures.is_empty():
		for path: String in fixture_files:
			if FileAccess.file_exists(path):
				_result(DirAccess.remove_absolute(path), "清理本次双人验证文件")
		if not fixture_root.is_empty():
			_result(DirAccess.remove_absolute(fixture_root), "清理双人验证独占目录")
	if failures.is_empty():
		print("PAIR_EXPANSION_TEST_PASS checks=%d" % checks)
		quit(0)
	else:
		for message: String in failures:
			push_error(message)
		print("PAIR_EXPANSION_TEST_FAIL checks=%d failures=%d fixtures=%s" % [checks, failures.size(), fixture_root])
		quit(1)
