extends SceneTree
## 批次3双人扩展：抢走漫画与合伙恶作剧的目标资格、数值结算、分心状态与存档往返。

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
	fixture_root = OS.get_cache_dir().path_join("PrankComic_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	if not _result(DirAccess.make_dir_recursive_absolute(fixture_root), "建立独占测试目录"):
		_finish()
		return
	# 本组验证互动自身规则，不含每日发点；把起始日推到局外隔离每日属性点影响。
	configuration.globals["first_daily_attribute_day"] = 99
	if _empty() == null:
		_finish()
		return
	_check(_test_config_contract(), "批次3配置与动作契约完整")
	_check(_test_take_comic_rules(), "抢走漫画规则场景完整执行")
	_check(_test_distracted_knowledge(), "分心状态知识结算场景完整执行")
	_check(_test_prank_together_rules(), "合伙恶作剧规则场景完整执行")
	_check(_test_roundtrip_and_boundary(), "存档往返与边界场景完整执行")
	_finish()


## 建立尚未自主决策的四人局；default_seed用于复现固定随机流。
func _empty(default_seed: int = 417703) -> ClassroomSimulation:
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
func _at_lesson(seed_value: int = 417703) -> ClassroomSimulation:
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


## 配置契约：两动作启用、效果表数值、分心状态与阶段开放。
func _test_config_contract() -> bool:
	var ok: bool = true
	var comic: Dictionary = configuration.actions.get("take_comic", {})
	var prank: Dictionary = configuration.actions.get("prank_together", {})
	if not _check(not comic.is_empty() and not prank.is_empty(), "权威配置存在两项批次3动作"):
		return false
	ok = _check(String(comic.target) == "pair" and String(comic.scene) == "any" and is_equal_approx(float(comic.duration_min_s), 60.0) and bool(comic.enabled), "抢漫画是60秒双人任意场景动作且已启用") and ok
	ok = _check(String(comic.source) == "player", "抢漫画保持玩家主动入口") and ok
	ok = _check(String(prank.target) == "pair" and String(prank.scene) == "classroom" and is_equal_approx(float(prank.duration_min_s), 120.0) and bool(prank.enabled), "恶作剧降级为教室120秒双人动作且已启用") and ok
	ok = _check(String(prank.source) == "player", "恶作剧保持玩家主动入口") and ok
	# 效果表：抢漫画启动-3专注，完成发起者+6、目标回课表并挂分心。
	var comic_start: Array = configuration.phase_effects("take_comic", "start")
	ok = _check(comic_start.size() == 1 and String(comic_start[0].recipient) == "self" and is_equal_approx(float(comic_start[0].value), -3.0), "抢漫画启动扣3专注") and ok
	var comic_complete: Array = configuration.phase_effects("take_comic", "complete")
	var gain_effect: Dictionary = {}
	var buff_effect: Dictionary = {}
	var entry_effect: Dictionary = {}
	for effect: Dictionary in comic_complete:
		if effect.type == "resource" and String(effect.recipient) == "self":
			gain_effect = effect
		elif effect.type == "apply_buff":
			buff_effect = effect
		elif effect.type == "start_action":
			entry_effect = effect
	ok = _check(not gain_effect.is_empty() and is_equal_approx(float(gain_effect.value), 6.0), "抢漫画完成发起者获得6专注") and ok
	ok = _check(not buff_effect.is_empty() and String(buff_effect.buff_id) == "distracted", "抢漫画完成目标挂分心状态") and ok
	ok = _check(not entry_effect.is_empty() and String(entry_effect.next_action_id) == "current_course" and String(entry_effect.event) == "forced_entry", "抢漫画完成目标强制回课表") and ok
	# 恶作剧保留既有数值并去掉盟友行，新增分心行。
	var prank_start: Array = configuration.phase_effects("prank_together", "start")
	ok = _check(prank_start.size() == 1 and is_equal_approx(float(prank_start[0].value), -8.0), "恶作剧发起者先付8专注") and ok
	var prank_complete: Array = configuration.phase_effects("prank_together", "complete")
	ok = _check(prank_complete.size() == 3, "恶作剧完成三条效果（无盟友行）") and ok
	var prank_buffs: int = 0
	for effect: Dictionary in prank_complete:
		if effect.type == "apply_buff":
			prank_buffs += 1
			ok = _check(String(effect.buff_id) == "distracted", "恶作剧完成目标挂分心状态") and ok
		elif effect.type == "resource" and String(effect.recipient) == "target":
			ok = _check(is_equal_approx(float(effect.value), -10.0), "恶作剧完成目标扣10专注") and ok
		elif effect.type == "resource" and String(effect.recipient) == "self":
			ok = _check(is_equal_approx(float(effect.value), 2.0), "恶作剧完成发起者回2专注") and ok
	ok = _check(prank_buffs == 1, "恶作剧只有一条分心效果") and ok
	# 分心状态定义：10分钟知识×0.75。
	var distracted: Dictionary = configuration.buffs.get("distracted", {})
	ok = _check(String(distracted.lifecycle) == "timed" and is_equal_approx(float(distracted.duration_s), 600.0) and is_equal_approx(float(distracted.knowledge_multiplier), 0.75), "分心状态按10分钟知识0.75倍定义") and ok
	ok = _check("take_comic" in configuration.phase_scope.enabled_actions and "prank_together" in configuration.phase_scope.enabled_actions, "阶段范围开放两项批次3动作") and ok
	return ok


## 抢漫画规则：目标资格、发起打断、完成收益与强制回课表；不转移物品。
func _test_take_comic_rules() -> bool:
	var ok: bool = true
	var simulation := _at_lesson()
	if simulation == null:
		return false
	# 目标没在看漫画时拒绝。
	ok = _check(not simulation.can_start_interaction(0, 1, "take_comic", ""), "目标没看漫画时抢漫画不可发起") and ok
	var refuse_reason: String = simulation.interaction_unavailable_reason(0, 1, "take_comic", "")
	ok = _check(refuse_reason.contains("看漫画"), "目标资格原因明确：%s" % refuse_reason) and ok
	# 让1号进入个人漫画阅读：先隔离自主池再让行为树开read_comic。
	simulation.phase_scope.social_auto_actions = []
	if not _result(simulation.start_action(1, "read_comic", true, -1, "目标开始看漫画", ""), "目标进入漫画阅读", simulation.error_message):
		return false
	ok = _check(simulation.can_start_interaction(0, 1, "take_comic", ""), "目标看漫画时抢漫画可发起") and ok
	# 压低双方专注避免完成收益触顶，使启动/完成数值可精确断言。
	simulation.students[0].focus = 50.0
	var before_focus: float = 50.0
	if not _result(simulation.start_interaction(0, 1, "take_comic", "", "", "抢漫画验证"), "真实发起抢漫画", simulation.error_message):
		return false
	var interaction: Dictionary = simulation.interactions.back()
	ok = _check(String(interaction.action_id) == "take_comic" and int(interaction.initiator_index) == 0 and int(interaction.target_index) == 1, "抢漫画互动身份正确") and ok
	ok = _check(String(simulation.students[1].current_action.action_id) == "take_comic", "发起时目标阅读被打断进入互动") and ok
	ok = _check(absf(float(simulation.students[0].focus) - (before_focus - 3.0)) < 1.0e-6, "发起者启动扣3专注") and ok
	# 完成后：发起者完成效果+6（按结算日志断言，不混入接续动作的自然入段扣费）。
	if not _result(simulation.advance(61.0), "推进到抢漫画完成", simulation.error_message):
		return false
	ok = _check(interaction.status == "completed", "抢漫画互动真实完成") and ok
	var gain_logs: Array = simulation.logs.filter(func(entry: Dictionary): return entry.type == "interaction_resource" and String(entry.details.action_id) == "take_comic" and String(entry.details.phase) == "complete" and int(entry.details.initiator_index) == 0 and String(entry.details.resource) == "focus")
	ok = _check(gain_logs.size() == 1 and absf(float(gain_logs[0].details.actual) - 6.0) < 1.0e-6, "发起者完成效果恰为+6专注") and ok
	ok = _check(String(simulation.students[1].current_action.action_id) != "take_comic", "完成后目标不再停留抢漫画") and ok
	var has_distracted: bool = false
	for buff: Dictionary in simulation.students[1].buffs:
		if String(buff.buff_id) == "distracted":
			has_distracted = true
	ok = _check(has_distracted, "目标完成时挂上分心状态") and ok
	# 物品版阅读同样可抢，且已消耗的物品不返还、不转移。
	var item_case := _at_lesson(911277)
	if item_case == null:
		return false
	item_case.phase_scope.social_auto_actions = []
	var held_original: int = int(item_case.students[1].inventory.get("comic", 0))
	item_case.students[1].inventory["comic"] = held_original + 1
	if not _result(item_case.start_action(1, "read_comic_item", false, -1, "目标开始看珍藏漫画", ""), "目标进入物品漫画阅读", item_case.error_message):
		return false
	# 物品在启动阅读时已消耗1件：启动后存量即原量，抢走完成后不返还、也不转移给发起者。
	var held_after_start: int = int(item_case.students[1].inventory.get("comic", 0))
	var initiator_original: int = int(item_case.students[0].inventory.get("comic", 0))
	ok = _check(held_after_start == held_original and simulation_can_start(item_case), "物品版阅读同样可抢且启动已消耗1件") and ok
	if not _result(item_case.start_interaction(0, 1, "take_comic", "", "", "物品版抢漫画"), "真实发起物品版抢漫画", item_case.error_message):
		return false
	if not _result(item_case.advance(61.0), "推进到物品版完成", item_case.error_message):
		return false
	print("PROBE_INV target=", item_case.students[1].inventory.get("comic", -9), " initiator=", item_case.students[0].inventory.get("comic", -9), " after_start=", held_after_start, " original=", held_original)
	ok = _check(int(item_case.students[1].inventory.get("comic", 0)) == held_after_start, "已消耗物品不返还") and ok
	ok = _check(int(item_case.students[0].inventory.get("comic", 0)) == initiator_original, "漫画不转移给发起者") and ok
	return ok


## 辅助：物品版用例的可发起断言。
func simulation_can_start(simulation: ClassroomSimulation) -> bool:
	return simulation.can_start_interaction(0, 1, "take_comic", "")


## 分心状态对知识结算生效：挂分心的自习知识只有0.75倍。
func _test_distracted_knowledge() -> bool:
	var ok: bool = true
	var simulation := _at_lesson(550231)
	if simulation == null:
		return false
	# 三科知识拉平消除弱科差异，注意力归零消除属性加成，得到纯倍率断言。
	for student: Dictionary in simulation.students:
		student.attributes.attention = 0.0
		for subject: String in ["chinese", "math", "english", "physical"]:
			student.knowledge[subject] = 100.0
	# 直接对本人挂分心状态并进入真实自习，对照无状态的同刻基线。
	if not _result(simulation.start_action(0, "study", true, -1, "分心中自习", ""), "本人进入真实自习", simulation.error_message):
		return false
	simulation._apply_buff(0, "distracted")
	if not _result(simulation.advance(300.0), "推进五分钟分心自习", simulation.error_message):
		return false
	var lesson_subject: String = String(simulation.course_context().subject_id)
	var distracted_gain: float = float(simulation.students[0].knowledge[lesson_subject]) - 100.0
	var control := _at_lesson(550231)
	if control == null:
		return false
	for student: Dictionary in control.students:
		student.attributes.attention = 0.0
		for subject: String in ["chinese", "math", "english", "physical"]:
			student.knowledge[subject] = 100.0
	if not _result(control.start_action(0, "study", true, -1, "对照组自习", ""), "对照进入真实自习", control.error_message):
		return false
	if not _result(control.advance(300.0), "推进五分钟对照自习", control.error_message):
		return false
	var normal_gain: float = float(control.students[0].knowledge[lesson_subject]) - 100.0
	ok = _check(normal_gain > 0.0, "对照组真实获得知识") and ok
	ok = _check(absf(distracted_gain - normal_gain * 0.75) < 1.0e-6, "分心期间知识恰为0.75倍") and ok
	return ok


## 合伙恶作剧规则：教室限定、两人数值与分心；宿舍发起被场景校验拒绝。
func _test_prank_together_rules() -> bool:
	var ok: bool = true
	var simulation := _at_lesson(773311)
	if simulation == null:
		return false
	# 压低双方专注，避免完成收益触顶或耗尽截断，数值可精确断言。
	simulation.students[0].focus = 50.0
	simulation.students[1].focus = 50.0
	var before_focus: float = 50.0
	var before_target: float = 50.0
	if not _result(simulation.start_interaction(0, 1, "prank_together", "", "", "恶作剧验证"), "真实发起合伙恶作剧", simulation.error_message):
		return false
	var interaction: Dictionary = simulation.interactions.back()
	ok = _check(String(interaction.action_id) == "prank_together" and int(interaction.target_index) == 1, "恶作剧互动身份正确") and ok
	ok = _check(absf(float(simulation.students[0].focus) - (before_focus - 8.0)) < 1.0e-6, "发起者启动扣8专注") and ok
	if not _result(simulation.advance(121.0), "推进到恶作剧完成", simulation.error_message):
		return false
	ok = _check(interaction.status == "completed", "恶作剧互动真实完成") and ok
	# 完成效果按结算日志断言：不混入完成后接续动作的入段扣费。
	var prank_logs: Array = simulation.logs.filter(func(entry: Dictionary): return entry.type == "interaction_resource" and String(entry.details.action_id) == "prank_together" and String(entry.details.phase) == "complete" and String(entry.details.resource) == "focus")
	# 结算日志记录互动双方身份：两条效果以actual区分（目标-10、发起者+2）。
	var target_loss: Array = prank_logs.filter(func(entry: Dictionary): return absf(float(entry.details.actual) + 10.0) < 1.0e-6)
	var initiator_gain: Array = prank_logs.filter(func(entry: Dictionary): return absf(float(entry.details.actual) - 2.0) < 1.0e-6)
	ok = _check(target_loss.size() == 1, "目标完成扣10专注") and ok
	ok = _check(initiator_gain.size() == 1, "发起者完成回2专注") and ok
	var has_distracted: bool = false
	for buff: Dictionary in simulation.students[1].buffs:
		if String(buff.buff_id) == "distracted":
			has_distracted = true
	ok = _check(has_distracted, "目标完成时挂上分心状态") and ok
	# 场景限定：宿舍里的两人不能合伙恶作剧。
	var dorm_case := _at_dorm_free(881519)
	if dorm_case == null:
		return false
	ok = _check(not dorm_case.can_start_interaction(0, 1, "prank_together", ""), "宿舍里不能合伙恶作剧") and ok
	return ok


## 定位到宿舍自由时段的真实局（课表外）。
func _at_dorm_free(seed_value: int) -> ClassroomSimulation:
	var simulation := _empty(seed_value)
	if simulation == null:
		return null
	if not _result(simulation.set_debug_time(1, 61200.0), "定位宿舍自由时段", simulation.error_message):
		return null
	if not _check(simulation.course_context().kind == "outside", "定位处于课表外自由时段"):
		return null
	return simulation


## 存档往返：在途抢漫画随档恢复并真实完成；课表外抢漫画完成回自由时段动作。
func _test_roundtrip_and_boundary() -> bool:
	var ok: bool = true
	var simulation := _at_lesson(405061)
	if simulation == null:
		return false
	simulation.phase_scope.social_auto_actions = []
	if not _result(simulation.start_action(1, "read_comic", true, -1, "目标开始看漫画", ""), "目标进入漫画阅读", simulation.error_message):
		return false
	if not _result(simulation.start_interaction(0, 1, "take_comic", "", "", "在途存档验证"), "真实发起在途抢漫画", simulation.error_message):
		return false
	if not _result(simulation.advance(30.0), "推进半分钟产生在途状态", simulation.error_message):
		return false
	var save_path: String = fixture_root.path_join("comic_save.json")
	if not _result(simulation.save_file(save_path), "保存抢漫画在途存档", simulation.error_message):
		return false
	var restored := _empty()
	if restored == null:
		return false
	if not _result(restored.load_file(save_path, false), "读取抢漫画在途存档", restored.error_message):
		return false
	ok = _check(String(restored.students[0].current_action.action_id) == "take_comic", "读档保留在途抢漫画动作") and ok
	if not _result(restored.advance(40.0), "读档后推进到完成", restored.error_message):
		return false
	# 推进期间NPC可能已发起新互动：按动作取抢漫画互动验证真实完成。
	var comic_interactions: Array = restored.interactions.filter(func(entry: Dictionary): return String(entry.action_id) == "take_comic")
	var interaction: Dictionary = comic_interactions.back()
	ok = _check(interaction.status == "completed", "读档后抢漫画真实完成") and ok
	# 边界：课表外抢漫画完成，目标强制回课表解析为自由时段动作而不是虚构课程。
	var free_case := _at_dorm_free(662077)
	if free_case == null:
		return false
	free_case.phase_scope.social_auto_actions = []
	if not _result(free_case.start_action(1, "read_comic", true, -1, "目标在宿舍看漫画", ""), "目标进入漫画阅读", free_case.error_message):
		return false
	if not _result(free_case.start_interaction(0, 1, "take_comic", "", "", "自由时段抢漫画"), "真实发起自由时段抢漫画", free_case.error_message):
		return false
	if not _result(free_case.advance(61.0), "推进到自由时段抢漫画完成", free_case.error_message):
		return false
	var after_action: String = String(free_case.students[1].current_action.get("action_id"))
	ok = _check(after_action != "take_comic" and not after_action.is_empty(), "自由时段完成后目标进入真实接续动作：%s" % after_action) and ok
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
		print("PRANK_COMIC_TEST_PASS checks=%d" % checks)
		quit(0)
	else:
		for message: String in failures:
			push_error(message)
		print("PRANK_COMIC_TEST_FAIL checks=%d failures=%d fixtures=%s" % [checks, failures.size(), fixture_root])
		quit(1)


## 本组写入的临时文件清单。
func fixture_files_list() -> Array[String]:
	return [fixture_root.path_join("comic_save.json")]
