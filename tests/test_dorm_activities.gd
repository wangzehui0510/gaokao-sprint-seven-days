extends "res://tests/test_dorm_ledger.gd"
## 宿舍活动专项沿用真实账本夹具；资源、知识与成绩只能来自生产执行过程。

# 六项已确认活动与三门选科用于独立检查候选完整性，不作为被测执行器的替代结果。
const DORM_IDS: Array[String] = ["dorm_study", "dorm_practice", "dorm_game", "dorm_workout", "dorm_wash", "dorm_rest"]
const CULTURAL_IDS: Array[String] = ["chinese", "math", "english"]


## 每组均要求执行到结束标记，任何场景中断都会计入失败。
func _run() -> void:
	configuration = GameConfig.new()
	if not _result(configuration.load_file(), "正式配置加载", configuration.error_message):
		_finish()
		return
	fixture_root = OS.get_cache_dir().path_join("ClassroomDormActivities_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	if not _result(DirAccess.make_dir_recursive_absolute(fixture_root), "建立独占宿舍活动目录"):
		_finish()
		return
	_check(_test_six_activity_numbers(), "六项正式活动数值和结束休息完整执行")
	_check(_test_precise_depletion(), "真实消耗至零和候选过滤完整执行")
	_check(_test_recovery_persistence(), "在途恢复保存及再次选择完整执行")
	_check(_test_interrupt_and_boundaries(), "主动打断、午夜、上课与终局完整执行")
	_check(_test_weighted_ai(), "四人属性加权活动及并列弱科对称选科完整执行")
	_check(_test_step_equivalence(), "真实耗尽、午夜和上课的大步小步一致性完整执行")
	_check(_test_wrong_book_independence(), "真实错误课本不重定向宿舍显式选科完整执行")
	_check(_test_tiny_physical_snapshot(), "一秒健身产生的真实微小成绩可保存重读")
	_finish()


## 每项活动先用真实刷题制造恢复空间，再核对正式时长、净资源及各科知识。
func _test_six_activity_numbers() -> bool:
	var cases: Array[Dictionary] = [
		{"id": "dorm_study", "subject": "chinese", "seconds": 1200.0, "focus": -12.0, "stamina": -4.0, "knowledge": 4.0},
		{"id": "dorm_practice", "subject": "english", "seconds": 600.0, "focus": -15.0, "stamina": -3.0, "knowledge": 3.5},
		{"id": "dorm_game", "subject": "", "seconds": 900.0, "focus": 15.0, "stamina": -4.5, "knowledge": 0.0},
		{"id": "dorm_workout", "subject": "physical", "seconds": 600.0, "focus": 5.0, "stamina": -20.0, "knowledge": 1.2},
		{"id": "dorm_wash", "subject": "", "seconds": 300.0, "focus": 10.0, "stamina": 3.0, "knowledge": 0.0},
		{"id": "dorm_rest", "subject": "", "seconds": 600.0, "focus": 10.0, "stamina": 3.0, "knowledge": 0.0},
	]
	for entry: Dictionary in cases:
		var simulation := _at(1, 61200.0)
		if simulation == null or not _play(simulation, 0, "dorm_practice", 600.0, "math"):
			return false
		_close(simulation.students[0].focus, 85.0, "正式刷题真实消耗十五专注")
		_close(simulation.students[0].stamina, 97.0, "正式刷题真实消耗三体力")
		var before: Dictionary = simulation.students[0].duplicate(true)
		var selected: String = entry.subject if entry.subject in CULTURAL_IDS else ""
		if not _result(simulation.start_action(0, entry.id, false, -1, "六项真实数值验证", selected), "开始正式活动：" + entry.id, simulation.error_message):
			return false
		var instance_id: int = simulation.students[0].current_action.instance_id
		_close(simulation.students[0].focus, before.focus, "活动无额外启动专注费用：" + entry.id)
		_close(simulation.students[0].stamina, before.stamina, "活动无额外启动体力费用：" + entry.id)
		_close(simulation.students[0].current_action.duration_s, entry.seconds, "正式活动时长：" + entry.id)
		_check(not simulation.students[0].current_action.dorm_recovery, "主动活动不是强制恢复标记：" + entry.id)
		if not _result(simulation.advance(entry.seconds), "执行完整活动：" + entry.id, simulation.error_message):
			return false
		_close(simulation.students[0].focus - before.focus, entry.focus, "真实专注净变化：" + entry.id)
		_close(simulation.students[0].stamina - before.stamina, entry.stamina, "真实体力净变化及上限截取：" + entry.id)
		for subject: String in before.knowledge:
			_close(simulation.students[0].knowledge[subject] - before.knowledge[subject], entry.knowledge if subject == entry.subject else 0.0, "知识只归实际科目：%s/%s" % [entry.id, subject])
		var ended: Dictionary = _ended(simulation, 0, instance_id)
		if not _check(not ended.is_empty() and ended.type == "complete", "完整活动有真实完成记录：" + entry.id):
			return false
		_close(ended.details.executed_s, entry.seconds, "完成日志保存实际执行时长：" + entry.id)
		_close(ended.details.knowledge_gain, entry.knowledge, "完成日志保存真实收益：" + entry.id)
		_close(ended.details.resource_changes.get("focus", {}).get("actual", 0.0), entry.focus, "完成日志专注不显示请求恢复量：" + entry.id)
		_close(ended.details.resource_changes.get("stamina", {}).get("actual", 0.0), entry.stamina, "完成日志体力不显示超额恢复量：" + entry.id)
		_check(simulation.students[0].inventory.is_empty() and simulation.students[0].daily_item_claim_days.is_empty(), "宿舍活动不冒领首次上课奖励：" + entry.id)
		var recovery: Dictionary = simulation.students[0].current_action.duplicate(true)
		if not _check(recovery.action_id == "dorm_rest" and recovery.dorm_recovery, "每项结束均进入已确认恢复：" + entry.id):
			return false
		_close(recovery.duration_s, 600.0, "恢复持续十分钟：" + entry.id)
		if not _result(simulation.advance(599.0), "恢复尚差一秒", simulation.error_message):
			return false
		_check(simulation.students[0].current_action.instance_id == recovery.instance_id, "恢复结束前不重新选动作：" + entry.id)
		var rng_before: String = str(simulation.rng.state)
		if not _result(simulation.advance(1.0), "恢复恰好完成后自主选择", simulation.error_message):
			return false
		_check(simulation.students[0].current_action.instance_id != recovery.instance_id and not simulation.students[0].current_action.dorm_recovery, "恢复完成即回到普通自主活动：" + entry.id)
		_check(simulation.students[0].current_action.action_id in DORM_IDS and str(simulation.rng.state) != rng_before, "恢复后由同一随机流真实选择：" + entry.id)
	return true


## 连续真实刷题和健身触及零点，不预填人物资源或知识。
func _test_precise_depletion() -> bool:
	var focus_case := _at(1, 61200.0)
	if focus_case == null or not _practice_six(focus_case):
		return false
	_close(focus_case.students[0].focus, 10.0, "六段真实刷题后剩十专注")
	if not _result(focus_case.start_action(0, "dorm_practice", false, -1, "精确耗尽专注", "math"), "开始第七段真实刷题", focus_case.error_message):
		return false
	var focus_instance: int = focus_case.students[0].current_action.instance_id
	if not _result(focus_case.advance(399.5), "推进至专注耗尽前半秒", focus_case.error_message):
		return false
	_check(focus_case.students[0].focus > 0.0 and focus_case.students[0].current_action.instance_id == focus_instance, "正资源余量时旧刷题仍执行")
	# 用真实浮点余量除正式费率确定最后边界，不把先前分段的机器误差当作额外资源。
	var focus_remaining: float = focus_case.students[0].focus / (1.5 / 60.0)
	_close(focus_remaining, 0.5, "专注实际余量恰支持最后半秒")
	if not _result(focus_case.advance(focus_remaining), "恰好推进至专注零点", focus_case.error_message):
		return false
	_close(focus_case.students[0].focus, 0.0, "专注在四百秒精确归零")
	_close(focus_case.students[0].stamina, 80.0, "刷题仅消耗真实六十六又三分之二分钟体力")
	_close(focus_case.students[0].knowledge.math, 21.0 + 7.0 / 3.0, "资源耗尽保留部分刷题知识")
	var ended: Dictionary = _ended(focus_case, 0, focus_instance)
	if not _check(not ended.is_empty() and ended.type == "interrupt" and ended.message.contains("专注耗尽"), "耗尽明确记录中断原因"):
		return false
	_close(ended.details.executed_s, 400.0, "耗尽不是按整段十分钟补发")
	_check(focus_case.students[0].current_action.dorm_recovery, "耗尽后立即进入真实恢复")
	if not _assert_zero_candidates(focus_case, ["dorm_game", "dorm_workout", "dorm_wash", "dorm_rest"], ["dorm_study", "dorm_practice"], "零专注"):
		return false
	var stamina_case := _at(1, 61200.0)
	if stamina_case == null or not _play(stamina_case, 0, "dorm_study", 60.0, "chinese"):
		return false
	for index in 4:
		if not _play(stamina_case, 0, "dorm_workout", 600.0):
			return false
	_close(stamina_case.students[0].stamina, 19.8, "真实自习加四段健身后已有疲劳")
	if not _result(stamina_case.start_action(0, "dorm_workout", false), "开始部分体力可支持的第五段健身", stamina_case.error_message):
		return false
	var stamina_instance: int = stamina_case.students[0].current_action.instance_id
	if not _result(stamina_case.advance(593.5), "推进至体力耗尽前半秒", stamina_case.error_message):
		return false
	_check(stamina_case.students[0].stamina > 0.0 and stamina_case.students[0].current_action.instance_id == stamina_instance, "微量体力仍有真实执行时间")
	var stamina_remaining: float = stamina_case.students[0].stamina / (2.0 / 60.0)
	_close(stamina_remaining, 0.5, "体力实际余量恰支持最后半秒")
	if not _result(stamina_case.advance(stamina_remaining), "推进至体力零点", stamina_case.error_message):
		return false
	_close(stamina_case.students[0].stamina, 0.0, "健身第五段在五百九十四秒耗尽")
	# 总健身49.9分钟，其中39.9分钟正常、10分钟处于既有疲劳区间。
	_close(stamina_case.students[0].knowledge.physical, 0.12 * (39.9 + 10.0 * 0.7), "跨疲劳阈值按实际秒数积分")
	ended = _ended(stamina_case, 0, stamina_instance)
	if not _check(not ended.is_empty() and ended.type == "interrupt" and ended.message.contains("体力耗尽"), "健身体力耗尽明确中断"):
		return false
	_close(ended.details.executed_s, 594.0, "健身停止在精确体力零点")
	_close(ended.details.knowledge_gain, 0.12 * 9.9 * 0.7, "部分健身仅获得实际疲劳收益")
	return _assert_zero_candidates(stamina_case, ["dorm_wash", "dorm_rest"], ["dorm_study", "dorm_practice", "dorm_game", "dorm_workout"], "零体力")


## 零资源候选查询保持权威状态；拒绝新动作后，真实行为树也只能选择可执行活动。
func _assert_zero_candidates(simulation: ClassroomSimulation, allowed: Array, blocked: Array, label: String) -> bool:
	var authority: Array = simulation.students.duplicate(true)
	var rng_before: String = str(simulation.rng.state)
	_check(_same_members(_candidate_ids(simulation, 0), allowed), label + "候选仅含真正可执行活动")
	_check(simulation.students == authority and str(simulation.rng.state) == rng_before, label + "候选查询不改变权威状态")
	for action_id: String in blocked:
		var selected: String = "math" if action_id in ["dorm_study", "dorm_practice"] else ""
		var reason: String = simulation.action_unavailable_reason(0, action_id, false, selected)
		_check(reason.contains("耗尽") and not simulation.can_start_action(0, action_id, false, selected), label + "说明真实不可用原因：" + action_id)
		_check(simulation.start_action(0, action_id, false, -1, "零资源拒绝验证", selected) == ERR_UNAVAILABLE, label + "启动入口拒绝消耗型动作：" + action_id)
		_check(simulation.students == authority and str(simulation.rng.state) == rng_before, label + "拒绝保留原恢复实例和随机流：" + action_id)
	# 同刻开发定位仅结束旧实例，不流逝时间、不恢复资源，再由生产树执行零资源选择。
	if not _result(simulation.set_debug_time(simulation.day, simulation.clock_seconds), label + "同刻定位等待自主选择", simulation.error_message):
		return false
	if not _result(simulation.advance(0.0), label + "真实行为树选择", simulation.error_message):
		return false
	_check(simulation.students[0].current_action.action_id in allowed and not simulation.students[0].current_action.dorm_recovery, label + "自主树不会抽到不可执行活动")
	return true


## 恢复标记、已执行秒数与随机流均从生产存档往返，不因读档重新选活动。
func _test_recovery_persistence() -> bool:
	var source := _at(1, 61200.0)
	if source == null or not _play(source, 0, "dorm_study", 1200.0, "english"):
		return false
	if not _result(source.advance(123.0), "真实恢复执行两分三秒", source.error_message):
		return false
	var action: Dictionary = source.students[0].current_action.duplicate(true)
	var saved: Dictionary = _save(source, "mandatory_recovery.json")
	if saved.is_empty():
		return false
	_check(saved.students[0].current_action.dorm_recovery, "生产存档明确保存强制恢复身份")
	var restored := _empty()
	if restored == null or not _result(restored.load_file(_path("mandatory_recovery.json"), false), "读取在途十分钟恢复", restored.error_message):
		return false
	_check(_same(restored.students[0].current_action, action) and str(restored.rng.state) == str(source.rng.state), "恢复读档不重建实例或消耗随机流")
	_close(restored.elapsed_s - action.started_at, 123.0, "恢复保留真实已执行时长")
	if not _result(source.advance(477.0), "原局恢复完成后重选", source.error_message) or not _result(restored.advance(477.0), "读档局恢复完成后重选", restored.error_message):
		return false
	_check(_same(source.students, restored.students) and str(source.rng.state) == str(restored.rng.state), "原局与读档局完成恢复后的四人选择一致")
	_check(not restored.students[0].current_action.dorm_recovery, "恢复完成后不会无限安排下一段强制恢复")
	return true


## 中断保留累计收益；同刻完成、午夜、上课和终局遵循真实边界顺序。
func _test_interrupt_and_boundaries() -> bool:
	var interrupted := _at(1, 61200.0)
	if interrupted == null or not _play(interrupted, 0, "dorm_practice", 137.0, "english"):
		return false
	var previous: Dictionary = interrupted.students[0].current_action.duplicate(true)
	if not _play(interrupted, 0, "dorm_wash", 30.0):
		return false
	_close(interrupted.students[0].knowledge.english, 0.35 * 137.0 / 60.0, "主动换动作保留此前实际刷题收益")
	var ended: Dictionary = _ended(interrupted, 0, previous.instance_id)
	if not _check(not ended.is_empty() and ended.type == "interrupt", "主动切换明确记录旧活动中断"):
		return false
	_close(ended.details.executed_s, 137.0, "主动切换不会补足原定时长")
	_close(interrupted.get_dorm_summary(1).totals.english, interrupted.students[0].knowledge.english, "主动打断的部分收益仍在宿舍明细")
	var midnight := _at(1, 86340.0)
	if midnight == null or not _result(midnight.start_action(0, "dorm_practice", false, -1, "午夜边界", "english"), "午夜前开始刷题", midnight.error_message):
		return false
	var midnight_id: int = midnight.students[0].current_action.instance_id
	if not _result(midnight.advance(60.0), "真实经过午夜", midnight.error_message):
		return false
	_check(midnight.day == 2 and midnight.clock_seconds == 0.0 and midnight.students[0].current_action.dorm_recovery, "午夜结束旧实例并进入次日休息")
	ended = _ended(midnight, 0, midnight_id)
	_check(not ended.is_empty() and ended.type == "interrupt", "午夜旧活动被打断而非假完成")
	_close(midnight.get_dorm_summary(1).totals.english, 0.35, "午夜前实际收益归前一日")
	_close(midnight.get_dorm_summary(2).totals.english, 0.0, "午夜时不把前日收益复制到次日")
	if not _result(midnight.advance(60.0), "次日真实恢复一分钟", midnight.error_message):
		return false
	_close(midnight.get_dorm_summary(2).totals.english, 0.0, "恢复不会暗中继续前一日学习")
	for entry: Dictionary in [{"seconds": 28740.0, "duration": 60.0, "completed": false}, {"seconds": 27600.0, "duration": 1200.0, "completed": true}]:
		var school := _at(1, entry.seconds)
		if school == null or not _result(school.start_action(0, "dorm_study", false, -1, "早课边界", "math"), "上课前真实数学自习", school.error_message):
			return false
		var instance_id: int = school.students[0].current_action.instance_id
		if not _result(school.advance(entry.duration), "真实推进至八点上课", school.error_message):
			return false
		_check(school.clock_seconds == 28800.0 and school.students[0].current_action.action_id == "study", "上课立即接续真实课程")
		_close(school.students[0].knowledge.math, 0.2 * entry.duration / 60.0, "上课前仅累计实际自习时间")
		ended = _ended(school, 0, instance_id)
		_check(not ended.is_empty() and ended.type == ("complete" if entry.completed else "interrupt"), "恰好完成优先于换课，否则保留真实中断")
		_check(not school.logs.any(func(log: Dictionary) -> bool: return log.student_index == 0 and log.type == "dorm_recovery"), "上课同刻不短暂创建额外宿舍恢复")
	var terminal := _at(7, 49800.0)
	if terminal == null or not _result(terminal.start_action(0, "dorm_workout", false), "末日首场开考前真实健身", terminal.error_message):
		return false
	var workout_id: int = terminal.students[0].current_action.instance_id
	if not _result(terminal.advance(600.0), "健身恰好在首场开考时完成", terminal.error_message):
		return false
	_check(_ended(terminal, 0, workout_id).type == "complete" and terminal.students[0].current_action.action_id == "exam", "末日首场开考先结清健身再进入考试")
	var physical_board: Dictionary = terminal.get_exam_board("physical")
	_close(_student_row(physical_board.rows, "student_0").knowledge, 1.2, "体育开考快照包含同刻完成的宿舍健身")
	if not _result(terminal.advance(9600.0), "真实经过末日三场考试至终局", terminal.error_message):
		return false
	_check(terminal.is_round_finished() and terminal.clock_seconds == 60000.0 and terminal.students.all(func(student: Dictionary) -> bool: return student.current_action.is_empty()), "第七天16:40结束并清理全部动作")
	_check(terminal.get_exam_board("physical") == physical_board, "后续课程与终局不回写已公布体育快照")
	var authority: Array = terminal.students.duplicate(true)
	var terminal_rng: String = str(terminal.rng.state)
	for action_id: String in DORM_IDS:
		var selected: String = "math" if action_id in ["dorm_study", "dorm_practice"] else ""
		_check(terminal.start_action(0, action_id, false, -1, "终局拒绝", selected) == ERR_UNAVAILABLE, "终局拒绝宿舍新活动：" + action_id)
	if not _result(terminal.advance(86400.0), "终局后推进保持冻结", terminal.error_message):
		return false
	_check(terminal.students == authority and str(terminal.rng.state) == terminal_rng, "终局指令和推进不改变资源知识或随机流")
	return true


## 固定种子独立重放属性权重CDF，保留四人六活动、三科选科及随机流完整覆盖。
func _test_weighted_ai() -> bool:
	var activity_seen: Array[Dictionary] = [{}, {}, {}, {}]
	var subject_seen: Array[Dictionary] = [{}, {}, {}, {}]
	for sample in 96:
		var simulation := _empty()
		if simulation == null:
			return false
		# 随机种子属于独立测试局的输入，未改动人物、资源、库存或已产生的结果。
		simulation.rng.seed = 9001 + sample
		if not _result(simulation.set_debug_time(1, 61200.0), "固定种子宿舍采样定位", simulation.error_message):
			return false
		var expected_rng := RandomNumberGenerator.new()
		expected_rng.seed = simulation.rng.seed
		expected_rng.state = simulation.rng.state
		var expected: Array[Dictionary] = []
		for index in 4:
			var candidates: Array[Dictionary] = simulation.get_dorm_candidates(index)
			if not _check(_same_members(_candidate_ids(simulation, index), DORM_IDS), "四人初始均可执行六项宿舍活动"):
				return false
			var total_weight: float = 0.0
			for candidate: Dictionary in candidates:
				total_weight += float(candidate.weight)
			var choice: float = float(expected_rng.randi()) / 4294967296.0 * total_weight
			var cursor: float = 0.0
			var action_id: String = ""
			for candidate: Dictionary in candidates:
				cursor += float(candidate.weight)
				if choice < cursor:
					action_id = candidate.action_id
					break
			if not _check(not action_id.is_empty(), "独立CDF抽样实际命中正式候选"):
				return false
			var definition: Dictionary = configuration.actions[action_id]
			var subject_id: String = ""
			if action_id in ["dorm_study", "dorm_practice"]:
				# 新局三科同为零，所有并列弱科应对称，仅用一次共享随机数选科。
				subject_id = CULTURAL_IDS[int(float(expected_rng.randi()) / 4294967296.0 * 3.0)]
			elif action_id == "dorm_workout":
				subject_id = "physical"
			expected_rng.randf_range(definition.duration_min_s, definition.duration_max_s)
			expected.append({"action": action_id, "subject": subject_id})
		if not _result(simulation.advance(0.0), "四棵正式行为树提交宿舍选择", simulation.error_message):
			return false
		for index in 4:
			var action: Dictionary = simulation.students[index].current_action
			_check(action.action_id == expected[index].action and action.subject_id == expected[index].subject, "角色%d的活动和科目符合独立属性权重重放" % index)
			_check(not action.dorm_recovery, "随机选中休息也保持普通活动身份")
			activity_seen[index][action.action_id] = true
			if action.action_id in ["dorm_study", "dorm_practice"]:
				subject_seen[index][action.action_id + "/" + action.subject_id] = true
		_check(str(simulation.rng.state) == str(expected_rng.state), "四人共用随机流仅抽动作、必要选科和真实时长")
	for index in 4:
		_check(activity_seen[index].size() == 6, "固定种子集合覆盖角色%d全部六项活动" % index)
		for action_id: String in ["dorm_study", "dorm_practice"]:
			for subject_id: String in CULTURAL_IDS:
				_check(subject_seen[index].has(action_id + "/" + subject_id), "角色%d实际选择过%s/%s" % [index, action_id, subject_id])
	return true


## 同种子真实活动分别大步和37秒小步推进，跨耗尽、恢复、午夜及次日上课后比较权威状态。
func _test_step_equivalence() -> bool:
	var large := _at(1, 61200.0)
	var small := _at(1, 61200.0)
	if large == null or small == null or not _practice_six(large) or not _practice_six(small):
		return false
	for simulation: ClassroomSimulation in [large, small]:
		if not _result(simulation.start_action(0, "dorm_practice", false, -1, "大步小步耗尽验证", "math"), "开始真实剩十专注刷题", simulation.error_message):
			return false
	if not _result(large.advance(55000.0), "一次真实推进跨夜至次日课程", large.error_message):
		return false
	var remaining: float = 55000.0
	while remaining > 0.0:
		var duration: float = minf(37.0, remaining)
		if not _result(small.advance(duration), "小步真实推进跨同样时间", small.error_message):
			return false
		remaining -= duration
	_check(large.day == small.day and large.day == 2, "大步小步抵达相同次日")
	_close(large.clock_seconds, small.clock_seconds, "大步小步游戏时钟一致")
	_close(large.elapsed_s, small.elapsed_s, "大步小步在线时长一致")
	_check(_same(large.students, small.students), "大步小步四人资源、知识、库存、状态与在途实例一致：" + _first_difference(large.students, small.students))
	_check(str(large.rng.state) == str(small.rng.state) and large.next_action_number == small.next_action_number, "大步小步动作序列和随机流一致")
	_check(_same(large.round_progression.data, small.round_progression.data), "大步小步在校及宿舍权威账本一致：" + _first_difference(large.round_progression.data, small.round_progression.data))
	_check(_same(_action_history(large), _action_history(small)), "大步小步完成与打断时刻和实际收益一致：" + _first_difference(_action_history(large), _action_history(small)))
	return true


## 正式偷换课本跨入宿舍后仍正常计时，但宿舍所选英语不转入课本指定的语文。
func _test_wrong_book_independence() -> bool:
	var simulation := _at(1, 59760.0)
	if simulation == null or not _result(simulation.start_interaction(0, 1, "swap_book", "", "chinese"), "放学前真实偷换语文课本", simulation.error_message):
		return false
	if not _result(simulation.advance(120.0), "真实偷书完成", simulation.error_message):
		return false
	var wrong_book: Dictionary = _find_buff(simulation, 1, "wrong_book")
	if not _check(not wrong_book.is_empty() and wrong_book.selected_subject_id == "chinese", "真实错误课本状态携带语文"):
		return false
	if not _result(simulation.advance(120.0), "错误课本真实持续至放学", simulation.error_message):
		return false
	var before: Dictionary = simulation.students[1].knowledge.duplicate(true)
	if not _play(simulation, 1, "dorm_study", 60.0, "english"):
		return false
	_close(simulation.students[1].knowledge.english - before.english, 0.21, "同学一点专注属性下宿舍显式英语获得真实收益")
	_close(simulation.students[1].knowledge.chinese, before.chinese, "错误课本不能重定向宿舍英语")
	_close(simulation.students[1].knowledge.math, before.math, "原数学课程也不接收宿舍英语")
	_check(_find_buff(simulation, 1, "wrong_book").expires_at == wrong_book.expires_at, "宿舍活动不清除或刷新错误课本到期时间")
	var summary: Dictionary = simulation.get_dorm_summary(1, 1)
	_check(_has_row(summary.rows, "dorm_study", "english", 0.21), "真实宿舍来源行归英语")
	if not _result(simulation.advance(wrong_book.expires_at - simulation.elapsed_s), "推进至真实错误课本到期", simulation.error_message):
		return false
	_check(_find_buff(simulation, 1, "wrong_book").is_empty() and simulation.students[1].current_action.subject_id == "english", "错误课本按原时刻到期且不改宿舍选科")
	return true


## 一秒真实健身与开考同刻产生非零微小原始成绩，JSON往返不应误判为坏档。
func _test_tiny_physical_snapshot() -> bool:
	var source := _at(7, 50399.0)
	if source == null or not _play(source, 0, "dorm_workout", 1.0):
		return false
	var board: Dictionary = source.get_exam_board("physical")
	var row: Dictionary = _student_row(board.rows, "student_0")
	if not _check(not row.is_empty() and board.status == "published", "一秒健身后真实体育成绩已取值公布"):
		return false
	_close(row.knowledge, 0.002, "体育快照知识只来自真实一秒健身")
	_check(row.unrounded_score > 0.0 and row.unrounded_score < 0.001 and row.score_units == 0, "微小原始成绩保留，显示整数刻度按正式精度舍入")
	var saved: Dictionary = _save(source, "tiny_physical_snapshot.json")
	if saved.is_empty():
		return false
	var restored := _empty()
	if restored == null or not _result(restored.load_file(_path("tiny_physical_snapshot.json"), false), "真实微小体育成绩生产存档可重读", restored.error_message):
		return false
	_check(_same(restored.get_exam_board("physical"), board), "微小成绩、知识和开考参数完整往返")
	_check(str(restored.rng.state) == str(source.rng.state), "微小成绩读档不重新计算角色选择")
	return true


## 真实启动并推进指定时间；只向明确需要选科的活动传入科目。
func _play(simulation: ClassroomSimulation, index: int, action_id: String, seconds: float, subject_id: String = "") -> bool:
	return _result(simulation.start_action(index, action_id, false, -1, "宿舍活动真实执行验证", subject_id), "真实开始：" + action_id, simulation.error_message) and _result(simulation.advance(seconds), "真实执行：%s/%s秒" % [action_id, seconds], simulation.error_message)


## 六段刷题之间主动接管刚开始的恢复，未推进的恢复不得赠送资源。
func _practice_six(simulation: ClassroomSimulation) -> bool:
	for index in 6:
		if not _play(simulation, 0, "dorm_practice", 600.0, "math"):
			return false
	return true


## 候选身份来自生产可用性查询，不自行拼凑实际可执行结果。
func _candidate_ids(simulation: ClassroomSimulation, index: int) -> Array[String]:
	var result: Array[String] = []
	for candidate: Dictionary in simulation.get_dorm_candidates(index):
		result.append(candidate.action_id)
	return result


## 集合比较允许配置顺序不同，同时拒绝重复候选。
func _same_members(left: Array, right: Array) -> bool:
	if left.size() != right.size():
		return false
	var unique: Dictionary = {}
	for value: Variant in left:
		if value not in right or unique.has(value):
			return false
		unique[value] = true
	return true


## 从真实完成或打断日志读取指定实例，缺失时让调用方显式断言失败。
func _ended(simulation: ClassroomSimulation, index: int, instance_id: int) -> Dictionary:
	for entry: Dictionary in simulation.logs:
		if entry.student_index == index and entry.type in ["complete", "interrupt"] and entry.details.instance_id == instance_id:
			return entry
	return {}


## 提取四人真实动作历史，分段积分的资源日志数量不属于业务动作序列。
func _action_history(simulation: ClassroomSimulation) -> Array:
	return simulation.logs.filter(func(entry: Dictionary) -> bool: return entry.type in ["complete", "interrupt", "dorm_recovery"])


## 比较失败时报告首个具体字段与数值，不能仅留下无法定位的不一致提示。
func _first_difference(left: Variant, right: Variant, path: String = "$") -> String:
	if _same(left, right):
		return ""
	if left is Dictionary and right is Dictionary:
		for key: Variant in left:
			if not right.has(key):
				return path + "." + str(key) + "缺少字段"
			if not _same(left[key], right[key]):
				return _first_difference(left[key], right[key], path + "." + str(key))
		return path + "字段数量不同"
	if left is Array and right is Array:
		if left.size() != right.size():
			return "%s数组长度%d/%d" % [path, left.size(), right.size()]
		for index: int in left.size():
			if not _same(left[index], right[index]):
				return _first_difference(left[index], right[index], "%s[%d]" % [path, index])
	return "%s实际%s/%s" % [path, str(left), str(right)]


## 查询真实状态并返回副本，测试不借此制造或刷新效果。
func _find_buff(simulation: ClassroomSimulation, index: int, buff_id: String) -> Dictionary:
	for buff: Dictionary in simulation.students[index].buffs:
		if buff.buff_id == buff_id:
			return buff.duplicate(true)
	return {}


## 榜单按真实角色身份取行，避免依赖同分时的数组顺序。
func _student_row(rows: Array, student_id: String) -> Dictionary:
	for row: Dictionary in rows:
		if row.student_id == student_id:
			return row
	return {}


## 专项使用独立完成标记，成功仅清理本进程登记的夹具；失败保留定位证据。
func _finish() -> void:
	for controller in controllers:
		controller.free()
	if failures.is_empty():
		for path: String in fixture_files:
			if FileAccess.file_exists(path):
				_result(DirAccess.remove_absolute(path), "清理当前活动验证文件")
		if not fixture_root.is_empty():
			_result(DirAccess.remove_absolute(fixture_root), "清理当前活动验证目录")
	if failures.is_empty():
		print("DORM_ACTIVITIES_TEST_PASS checks=%d" % checks)
		quit(0)
	else:
		for message: String in failures:
			push_error(message)
		print("DORM_ACTIVITIES_TEST_FAIL checks=%d failures=%d fixtures=%s" % [checks, failures.size(), fixture_root])
		quit(1)
