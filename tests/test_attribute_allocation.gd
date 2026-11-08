extends SceneTree
## 属性分配使用配置已有点数与真实学习、互动、考试及保存执行链，不制造每日点数或NPC策略。

# 所有文件仅位于本进程独占缓存，正式玩家存档和权威配置不参与写入。
var fixture_root: String = ""
var fixture_files: Array[String] = []
var configuration: GameConfig
var owned_controllers: Array[ClassroomBehaviorController] = []
var checks: int = 0
var failures: Array[String] = []


## 等场景树就绪再建立生产行为树。
func _initialize() -> void:
	call_deferred("_run")


## 场景必须真实返回完成标记，脚本中断不能跳过断言后报告通过。
func _run() -> void:
	configuration = GameConfig.new()
	if not _result(configuration.load_file(), "加载正式配置", configuration.error_message):
		_finish()
		return
	fixture_root = OS.get_cache_dir().path_join("ClassroomAttribute_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	if not _result(DirAccess.make_dir_recursive_absolute(fixture_root), "建立属性验证独占目录"):
		_finish()
		return
	_check(_test_learning_immediately(), "分配后下一段真实学习即时采用基础专注力")
	_check(_test_effective_buffs(), "基础属性与真实定时状态修正叠加并实际到期")
	_check(_test_maximum_and_recovery(), "上限提高不赠资源，后续比例恢复读取新上限")
	_check(_test_rejected_atomicity(), "非法目标、属性、数量与不足点数不部分提交")
	_check(_test_representation_rejection(), "实际数值无法表示增加量时不扣点或报成功")
	_check(_test_save_roundtrip(), "已分配属性和剩余点数与在途纸条实际往返")
	_check(_test_exam_history(), "后续智力影响未来取值但不重算既有考试")
	_check(_test_terminal_rejection(), "终局拒绝所有新分配并保留保存和查询")
	_check(_test_no_daily_or_npc_allocation(), "真实跨日不会新增点数或代替NPC自动分配")
	_finish()


## 新局仅使用正式配置初始点数，课程与收益均由四棵生产树开始。
func _simulation(at_day: int, seconds: float) -> ClassroomSimulation:
	var simulation := ClassroomSimulation.new()
	if not _result(simulation.setup(configuration, 261107), "建立真实四人局", simulation.error_message):
		return null
	var controller := ClassroomBehaviorController.new()
	root.add_child(controller)
	controller.setup(simulation)
	owned_controllers.append(controller)
	simulation.decision_handler = controller.decide
	if not _result(simulation.set_debug_time(at_day, seconds), "设置独立开发时钟", simulation.error_message):
		return null
	if not _result(simulation.advance(0.0), "真实树进入当前课程", simulation.error_message):
		return null
	return simulation


## 先完成一分钟学习建立真实对照，加点本身不改变动作身份、费用、资源或随机流。
func _test_learning_immediately() -> bool:
	var simulation := _simulation(1, 28800.0)
	if simulation == null or not _result(simulation.advance(60.0), "先真实学习一分钟", simulation.error_message):
		return false
	var baseline_gain: float = simulation.students[0].knowledge.chinese
	var before: Dictionary = _authority(simulation)
	if not _result(simulation.allocate_attribute("attention", 2), "分配已有两点专注力", simulation.error_message):
		return false
	_close(simulation.students[0].attributes.attention, 2.0, "只增加自己的基础专注力")
	_check(simulation.students[0].unspent_points == int(configuration.global_value("initial_attribute_points")) - 2, "准确扣除两点待分配点数")
	_check(simulation.students.slice(1) == before.students.slice(1), "其他三名角色状态不变")
	_check(_actions(simulation) == before.actions, "四人动作、剩余时长与已结算进度不变")
	_check(str(simulation.rng.state) == before.rng_state and simulation.next_action_number == before.next_action_number, "分配不重抽动作、物品或推进动作编号")
	_close(simulation.students[0].focus, before.students[0].focus, "分配不重复扣启动费")
	_close(simulation.students[0].stamina, before.students[0].stamina, "分配不改变当前体力")
	_close(simulation.elapsed_s, before.elapsed_s, "分配不推进在线时间")
	_check(simulation.round_progression.data == before.round, "分配本身不增加知识或改写榜单")
	_check(simulation.logs.size() == before.logs.size() + 1, "成功分配记录一条真实业务日志")
	var event: Dictionary = simulation.logs.back()
	_check(event.student_index == 0 and event.details.attribute_id == "attention" and event.details.amount == 2, "日志保存真实分配对象和点数")
	if not _result(simulation.advance(60.0), "同一学习段再真实学习一分钟", simulation.error_message):
		return false
	var expected: float = baseline_gain * (1.0 + 2.0 * configuration.global_value("learning_focus_coefficient"))
	_close(simulation.students[0].knowledge.chinese - baseline_gain, expected, "新专注力立即影响后续一分钟知识")
	_close(simulation.students[1].knowledge.chinese, baseline_gain * 2.0, "未分配同学仍按原效率学习")
	_close(simulation.get_daily_board(1, "chinese").rows.size(), 0.0, "学习后尚未到日榜时刻不提前公布")
	_close(simulation.round_progression.data.daily_days["1"].gains.student_0.chinese, baseline_gain + expected, "日榜账本只累计真实分配前后知识增量")
	return true


## 配表合法定时状态是明确前置，仅用于验证叠加；实际学习积分和到期仍走生产执行器。
func _test_effective_buffs() -> bool:
	var simulation := _simulation(1, 28800.0)
	if simulation == null:
		return false
	for buff_id: String in ["prepared", "encouraged", "stretched", "inspired"]:
		simulation.students[0].buffs.append({"buff_id": buff_id, "expires_at": simulation.elapsed_s + 120.0, "action_instance_id": null})
	var focus: float = simulation.students[0].focus
	var stamina: float = simulation.students[0].stamina
	for attribute: String in ["attention", "discipline", "health", "intelligence"]:
		_close(simulation.effective_attribute(0, attribute), 1.0, "合法状态前置真实提供一点有效属性：" + attribute)
		if not _result(simulation.allocate_attribute(attribute, 2), "基础属性分配与已有状态叠加：" + attribute, simulation.error_message):
			return false
		_close(simulation.students[0].attributes[attribute], 2.0, "基础值不吸收临时状态：" + attribute)
		_close(simulation.effective_attribute(0, attribute), 3.0, "有效值为基础与临时修正之和：" + attribute)
	_check(simulation.students[0].unspent_points == 0, "四种属性共花完真实初始八点")
	_close(simulation.get_resource_max(0, "focus"), 130.0, "自律状态和基础自律共同增加专注上限")
	_close(simulation.get_resource_max(0, "stamina"), 130.0, "健康状态和基础健康共同增加体力上限")
	_close(simulation.students[0].focus, focus, "状态叠加分配不赠送当前专注")
	_close(simulation.students[0].stamina, stamina, "状态叠加分配不赠送当前体力")
	if not _result(simulation.advance(60.0), "状态生效期间真实学习一分钟", simulation.error_message):
		return false
	_close(simulation.students[0].knowledge.chinese, 1.15, "学习采用基础2加状态1的有效专注力")
	if not _result(simulation.advance(60.0), "推进至四个状态真实到期边界", simulation.error_message):
		return false
	_check(simulation.students[0].buffs.is_empty(), "定时状态到期由核心移除")
	for attribute: String in ["attention", "discipline", "health", "intelligence"]:
		_close(simulation.effective_attribute(0, attribute), 2.0, "状态到期只撤修正，不撤已分配基础值：" + attribute)
	_close(simulation.get_resource_max(0, "focus"), 120.0, "自律状态到期保留已分配上限")
	_close(simulation.get_resource_max(0, "stamina"), 120.0, "健康状态到期保留已分配上限")
	var knowledge: float = simulation.students[0].knowledge.chinese
	if not _result(simulation.advance(60.0), "状态结束后继续真实学习", simulation.error_message):
		return false
	_close(simulation.students[0].knowledge.chinese - knowledge, 1.1, "状态结束后按剩余基础专注力继续学习")
	return true


## 提高资源上限不按比例补满，既有绝对资源保持；随后睡觉按新上限连续恢复。
func _test_maximum_and_recovery() -> bool:
	var simulation := _simulation(1, 28800.0)
	if simulation == null:
		return false
	var before: Dictionary = _authority(simulation)
	if not _result(simulation.allocate_attribute("discipline", 2), "分配两点自律", simulation.error_message):
		return false
	if not _result(simulation.allocate_attribute("health", 3), "分配三点健康", simulation.error_message):
		return false
	_close(simulation.get_resource_max(0, "focus"), 120.0, "专注上限按每点十增加")
	_close(simulation.get_resource_max(0, "stamina"), 130.0, "体力上限按每点十增加")
	_close(simulation.students[0].focus, before.students[0].focus, "提高上限不赠送专注")
	_close(simulation.students[0].stamina, before.students[0].stamina, "提高上限不赠送体力")
	_check(_actions(simulation) == before.actions and str(simulation.rng.state) == before.rng_state, "提高上限不改变在途动作或随机流")
	# 低资源是恢复场景的明确前置，不直接填入任何恢复结果。
	simulation.students[0].focus = 20.0
	simulation.students[0].stamina = 20.0
	if not _result(simulation.start_action(0, "sleep"), "真实发动免费睡觉", simulation.error_message):
		return false
	if not _result(simulation.advance(60.0), "真实睡觉恢复一分钟", simulation.error_message):
		return false
	_close(simulation.students[0].focus, 20.6, "专注按新120上限的0.5%恢复")
	_close(simulation.students[0].stamina, 23.9, "体力按新130上限的3%恢复")
	_check(simulation.students[0].unspent_points == 3, "提高两种上限合计只花五点")
	return true


## 每类无效请求都与调用前完整权威状态比较，不能留下部分扣点或隐性副作用。
func _test_rejected_atomicity() -> bool:
	var simulation := _simulation(1, 28800.0)
	if simulation == null:
		return false
	var requests: Array[Dictionary] = [
		{"attribute": "", "amount": 1, "index": 0},
		{"attribute": "focus", "amount": 1, "index": 0},
		{"attribute": "attention", "amount": 0, "index": 0},
		{"attribute": "attention", "amount": -1, "index": 0},
		{"attribute": "attention", "amount": 9, "index": 0},
		{"attribute": "health", "amount": 1, "index": 1},
		{"attribute": "health", "amount": 1, "index": -1},
		{"attribute": "health", "amount": 1, "index": 4},
	]
	for request: Dictionary in requests:
		var before: Dictionary = _authority(simulation)
		var result: Error = simulation.allocate_attribute(request.attribute, request.amount, request.index)
		_check(result != OK and not simulation.error_message.is_empty(), "非法请求明确可见拒绝：" + str(request))
		_check(_authority(simulation) == before, "拒绝不改属性、点数、资源、动作、随机流或日志：" + str(request))
	if not _result(simulation.allocate_attribute("attention", 8), "允许一次花完已有点数", simulation.error_message):
		return false
	var spent: Dictionary = _authority(simulation)
	_check(simulation.allocate_attribute("intelligence") != OK, "点数花完后默认分配一点仍明确拒绝")
	_check(_authority(simulation) == spent, "不足点数不会扣成负数或改变其他属性")
	return true


## 有限大基础值作为表示边界前置，不以任意业务上限取代真实浮点检查。
func _test_representation_rejection() -> bool:
	var simulation := _simulation(1, 28800.0)
	if simulation == null:
		return false
	simulation.students[0].attributes.attention = 9007199254740992.0
	var before: Dictionary = _authority(simulation)
	_check(simulation.allocate_attribute("attention", 1) != OK, "2^53基础值无法精确增加一点时拒绝")
	_check(not simulation.error_message.is_empty() and _authority(simulation) == before, "实际表示失败保留全部点数与权威状态")
	return true


## v4已有属性字段直接往返，在途纸条、剩余点数与随机流不因保存重启。
func _test_save_roundtrip() -> bool:
	var source := _simulation(1, 28800.0)
	if source == null:
		return false
	for entry: Dictionary in [{"id": "attention", "amount": 2}, {"id": "discipline", "amount": 1}, {"id": "health", "amount": 1}, {"id": "intelligence", "amount": 2}]:
		if not _result(source.allocate_attribute(entry.id, entry.amount), "保存前分配已有点数：" + entry.id, source.error_message):
			return false
	if not _result(source.start_interaction(0, 1, "send_note", "分配属性后继续真实纸条"), "发动真实在途纸条", source.error_message):
		return false
	if not _result(source.advance(5.0), "纸条先执行五秒", source.error_message) or not _save(source, "active_attributes.json"):
		return false
	var restored := _simulation(1, 0.0)
	if restored == null or not _result(restored.load_file(_path("active_attributes.json"), false), "从独占缓存真实恢复", restored.error_message):
		return false
	_check(_same(restored.students, source.students), "四人基础属性、已花点数、库存、在途动作与进度往返")
	_check(_same(restored.interactions, source.interactions) and restored.notes.is_empty(), "恢复不提前送达纸条")
	_check(str(restored.rng.state) == str(source.rng.state), "恢复不重抽动作或奖励随机流")
	_check(restored.students[0].unspent_points == 2, "剩余两点真实保存")
	_close(restored.get_resource_max(0, "focus"), 110.0, "读档恢复已分配自律上限")
	_close(restored.get_resource_max(0, "stamina"), 110.0, "读档恢复已分配健康上限")
	if not _result(source.allocate_attribute("intelligence"), "原局继续花一点", source.error_message) or not _result(restored.allocate_attribute("intelligence"), "恢复局继续花同一点", restored.error_message):
		return false
	if not _result(source.advance(15.0), "原局纸条执行剩余十五秒", source.error_message) or not _result(restored.advance(15.0), "恢复局纸条执行同样剩余时间", restored.error_message):
		return false
	_check(_same(restored.students, source.students) and _same(restored.notes, source.notes), "恢复后继续分配与真实送达保持确定一致")
	_check(restored.notes.size() == 1 and restored.students[0].unspent_points == 1, "只送达一次且只消费保存后的一个点数")
	return true


## 从末日早课真实学习到开考，智力分配只影响未来快照，已取值成绩保持原样。
func _test_exam_history() -> bool:
	var simulation := _simulation(7, 28800.0)
	if simulation == null or not _result(simulation.advance(50399.0 - simulation.clock_seconds), "真实学习到语文开考前一秒", simulation.error_message):
		return false
	_check(simulation.students[0].knowledge.chinese > 0.0, "开考知识来自实际课程学习")
	if not _result(simulation.allocate_attribute("intelligence", 2), "开考前分配两点智力", simulation.error_message):
		return false
	if not _result(simulation.advance(1.0), "语文与体育实际取值", simulation.error_message):
		return false
	var chinese: Dictionary = simulation.get_exam_board("chinese")
	var physical: Dictionary = simulation.get_exam_board("physical")
	_check(chinese.status == "snapshot" and physical.status == "published", "实际开考生成语文快照与体育公布")
	_check(_row(chinese, "student_0").effective_intelligence == 2.0, "语文采用开考前已分配智力")
	if not _result(simulation.allocate_attribute("intelligence", 3), "语文开考后继续分配三点智力", simulation.error_message):
		return false
	_check(simulation.get_exam_board("chinese") == chinese and simulation.get_exam_board("physical") == physical, "后续分配不重取已发生语文或体育")
	if not _result(simulation.advance(53700.0 - simulation.clock_seconds), "真实经过语文公布和数学开考", simulation.error_message):
		return false
	var mathematics: Dictionary = simulation.get_exam_board("math")
	_check(mathematics.status == "snapshot" and _row(mathematics, "student_0").effective_intelligence == 5.0, "数学采用后来分配后的五点智力")
	_check(simulation.get_exam_board("chinese").status == "published" and simulation.get_exam_board("chinese").rows == chinese.rows, "语文公布仍保存原两点智力结果")
	if not _result(simulation.allocate_attribute("intelligence"), "数学开考后再分配一点智力", simulation.error_message):
		return false
	_check(simulation.get_exam_board("math") == mathematics, "数学既有快照不重算")
	if not _result(simulation.advance(57300.0 - simulation.clock_seconds), "真实执行至英语开考", simulation.error_message):
		return false
	_check(_row(simulation.get_exam_board("english"), "student_0").effective_intelligence == 6.0, "英语采用最新六点智力")
	if not _result(simulation.advance(60000.0 - simulation.clock_seconds), "真实执行至最终榜", simulation.error_message):
		return false
	_check(simulation.is_round_finished() and simulation.get_final_board().status == "published", "不同取值智力的真实单科可形成完整总榜")
	_check(simulation.get_exam_board("chinese").rows == chinese.rows and simulation.get_exam_board("math").rows == mathematics.rows, "最终榜不回写已取值单科历史")
	return true


## 结束局仍保存剩余点数，拒绝分配不会清空角色数据或只读历史。
func _test_terminal_rejection() -> bool:
	var simulation := _simulation(7, 59999.0)
	if simulation == null or not _result(simulation.advance(1.0), "真实经过终局边界", simulation.error_message):
		return false
	_check(simulation.is_round_finished(), "终局明确标记已结束")
	var before: Dictionary = _authority(simulation)
	for attribute: String in ["attention", "discipline", "health", "intelligence"]:
		_check(simulation.allocate_attribute(attribute) != OK, "终局拒绝继续分配：" + attribute)
		_check(_authority(simulation) == before, "终局拒绝保留剩余点数和整局：" + attribute)
	_check(simulation.students[0].unspent_points == int(configuration.global_value("initial_attribute_points")), "终局保留未花初始点数")
	if not _save(simulation, "finished_attributes.json"):
		return false
	var restored := _simulation(1, 0.0)
	if restored == null or not _result(restored.load_file(_path("finished_attributes.json"), false), "真实恢复可保存的结束局", restored.error_message):
		return false
	_check(restored.is_round_finished() and _same(restored.get_final_board(), simulation.get_final_board()), "结束局查阅与保存恢复继续可用")
	return true


## 日点与NPC分配仍未开放，不能因配置存在相应字段就自动发点或改变NPC养成。
func _test_no_daily_or_npc_allocation() -> bool:
	var simulation := _simulation(1, 28800.0)
	if simulation == null or not _result(simulation.allocate_attribute("attention", 3), "跨日前先真实花三点", simulation.error_message):
		return false
	var remaining: int = simulation.students[0].unspent_points
	if not _result(simulation.advance(86400.0), "四人真实执行整整一天到次日08:00", simulation.error_message):
		return false
	_check(simulation.day == 2 and simulation.clock_seconds == 28800.0, "实际跨过配置中的次日发点时刻")
	_check(simulation.students[0].unspent_points == remaining, "当前范围不凭daily_attribute_points字段新增点数")
	for index: int in range(1, simulation.students.size()):
		_check(simulation.students[index].unspent_points == int(configuration.global_value("initial_attribute_points")), "NPC保留原有未分配点数：" + str(index))
		for attribute: String in ["attention", "discipline", "health", "intelligence"]:
			_close(simulation.students[index].attributes[attribute], 0.0, "NPC不自动分配属性：" + str(index) + "/" + attribute)
	return true


## 单科结果必须含指定真实角色，缺记录直接让相应断言失败。
func _row(board: Dictionary, student_id: String) -> Dictionary:
	for row: Dictionary in board.rows:
		if row.student_id == student_id:
			return row
	_check(false, "成绩缺少真实角色：" + student_id)
	return {}


## 收集动作完整副本，验证分配不会重开、重抽或改变已结算累计值。
func _actions(simulation: ClassroomSimulation) -> Array:
	var result: Array = []
	for student: Dictionary in simulation.students:
		result.append(student.current_action.duplicate(true))
	return result


## 错误文本允许改变，其他所有权威状态与业务日志必须严格保持。
func _authority(simulation: ClassroomSimulation) -> Dictionary:
	return {
		"students": simulation.students.duplicate(true), "actions": _actions(simulation),
		"round": simulation.round_progression.data.duplicate(true), "events": simulation.round_progression.events.duplicate(true),
		"logs": simulation.logs.duplicate(true), "interactions": simulation.interactions.duplicate(true),
		"notes": simulation.notes.duplicate(true), "violations": simulation.violations.duplicate(true),
		"day": simulation.day, "clock_seconds": simulation.clock_seconds, "elapsed_s": simulation.elapsed_s,
		"rng_state": str(simulation.rng.state), "next_action_number": simulation.next_action_number,
		"next_interaction_number": simulation.next_interaction_number, "next_violation_number": simulation.next_violation_number,
	}


## 生产保存器仅写本进程独占文件，临时文件同样登记以便清理。
func _save(simulation: ClassroomSimulation, filename: String) -> bool:
	var path: String = _path(filename)
	fixture_files.append(path)
	fixture_files.append(path + ".tmp")
	return _result(simulation.save_file(path), "真实保存属性验证局：" + filename, simulation.error_message)


## 固定文件名只能落在本次缓存根目录。
func _path(filename: String) -> String:
	return fixture_root.path_join(filename)


## JSON往返只容许浮点表示误差，字段、容器与顺序逐项保持。
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


## 生产错误携带真实原因，依赖失败结果的场景立即返回。
func _result(result: Error, message: String, detail: String = "") -> bool:
	return _check(result == OK, "%s：错误码%d %s" % [message, result, detail])


## 连续积分数值只容许表示误差，不修改被测结果。
func _close(actual: float, expected: float, message: String) -> void:
	_check(absf(actual - expected) < 0.000001, "%s：实际%s，预期%s" % [message, actual, expected])


## 每次实际断言计数，失败不被后续成功覆盖。
func _check(condition: bool, message: String) -> bool:
	checks += 1
	if not condition:
		failures.append(message)
	return condition


## 只清理登记文件；失败保留隔离证据并以非零结束。
func _finish() -> void:
	for controller in owned_controllers:
		controller.free()
	if failures.is_empty():
		for path: String in fixture_files:
			if FileAccess.file_exists(path):
				_result(DirAccess.remove_absolute(path), "清理本次验证文件")
		if not fixture_root.is_empty():
			_result(DirAccess.remove_absolute(fixture_root), "清理属性验证独占目录")
	if failures.is_empty():
		print("ATTRIBUTE_ALLOCATION_TEST_PASS checks=%d" % checks)
		quit(0)
	else:
		for message: String in failures:
			push_error(message)
		print("ATTRIBUTE_ALLOCATION_TEST_FAIL checks=%d failures=%d fixtures=%s" % [checks, failures.size(), fixture_root])
		quit(1)
