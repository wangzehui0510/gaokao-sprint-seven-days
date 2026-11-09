extends SceneTree
## 使用真实四人行为树、课程及计分边界验收七天局，不直接填入已完成榜单或考试记录。

const SUBJECTS: Array[String] = ["chinese", "math", "english", "physical"]
const DAILY_END: float = 60000.0
# 独占缓存只存本次配置副本和验证存档，正式JSON、Excel与玩家存档均不修改。
var fixture_root: String = ""
var fixture_files: Array[String] = []
var configuration: GameConfig
var owned_controllers: Array[ClassroomBehaviorController] = []
var checks: int = 0
var failures: Array[String] = []


## 场景树就绪后加载正式执行器，语法或依赖失败不能被当作业务验收通过。
func _initialize() -> void:
	call_deferred("_run")


## 每个场景必须返回实际完成标记，运行时错误不能跳过后续断言而报告成功。
func _run() -> void:
	configuration = GameConfig.new()
	if not _result(configuration.load_file(), "正式配置通过生产入口", configuration.error_message):
		_finish()
		return
	fixture_root = OS.get_cache_dir().path_join("ClassroomSevenDay_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	if not _result(DirAccess.make_dir_recursive_absolute(fixture_root), "创建独占七天局验证目录"):
		_finish()
		return
	_check(_test_whole_round(), "真实四人从第1天连续执行到第7天终局")
	_check(_test_daily_raw_order(), "知识榜按未舍入真实增量排序并列")
	_check(_test_snapshot_and_hot_reload(), "开考快照、真实互动、调表与公布时序完整执行")
	_check(_test_boundary_expiration(), "同刻状态到期先于开考取值")
	_check(_test_rewind_keeps_history(), "开发时间回退不能覆写既有快照和榜单")
	_check(_test_terminal_interactions(), "局末未完成与恰好完成纸条的边界完整执行")
	_finish()


## 新局只接入生产树，动作与榜单必须由后续真实时间入口产生。
func _empty_simulation(game_config: GameConfig = null, seed_value: int = 261107) -> ClassroomSimulation:
	var simulation := ClassroomSimulation.new()
	var source: GameConfig = configuration if game_config == null else game_config
	if not _result(simulation.setup(source, seed_value), "建立四人真实局", simulation.error_message):
		return null
	var controller := ClassroomBehaviorController.new()
	root.add_child(controller)
	controller.setup(simulation)
	owned_controllers.append(controller)
	simulation.decision_handler = controller.decide
	return simulation


## 开发定位显式标明验证时钟，不修改电脑日期或伪装现实时间流逝。
func _new_at(test_day: int, seconds: float, game_config: GameConfig = null) -> ClassroomSimulation:
	var simulation := _empty_simulation(game_config)
	if simulation == null:
		return null
	if not _result(simulation.set_debug_time(test_day, seconds), "显式定位开发时钟", simulation.error_message):
		return null
	if not _result(simulation.advance(0.0), "四棵真实行为树进入当前活动", simulation.error_message):
		return null
	return simulation


## 连续推进覆盖全部纯事件，总知识扣除真实宿舍动作收益后核对在校榜与历史。
func _test_whole_round() -> bool:
	var simulation := _new_at(1, 0.0)
	if simulation == null:
		return false
	_check(not simulation.is_round_finished(), "新局处于运行状态")
	_check(simulation.get_round_summary().session_days == 7, "局生命周期明确为七天")
	var published: Dictionary = {}
	for test_day in range(1, 8):
		var baseline: Dictionary = _knowledge_by_student(simulation)
		var dorm_baseline: Dictionary = _dorm_knowledge_by_student(simulation)
		for subject: String in SUBJECTS:
			var pending: Dictionary = simulation.get_daily_board(test_day, subject)
			_check(pending.status == "pending", "第%d天%s尚未到统计边界" % [test_day, subject])
		if not _result(simulation.advance(DAILY_END), "第%d天真实执行至16:40" % test_day, simulation.error_message):
			return false
		_check(simulation.day == test_day, "日榜在实际第%d天形成" % test_day)
		_close(simulation.clock_seconds, DAILY_END, "第%d天落在精确16:40" % test_day)
		var dorm_gains: Dictionary = _dorm_knowledge_by_student(simulation)
		for subject: String in SUBJECTS:
			var board: Dictionary = simulation.get_daily_board(test_day, subject)
			if not _check(board.status == "published" and board.rows.size() == 4, "第%d天%s真实发布四人知识榜" % [test_day, subject]):
				return false
			_check(board.source == "online", "连续在线日榜保留真实在线来源")
			_check(board.knowledge_scope == "school", "新局日榜明确只统计在校来源")
			_close(board.start_seconds, 0.0, "完整日从00:00统计新增知识")
			_close(board.end_seconds, DAILY_END, "完整日统计止于16:40")
			var rows: Dictionary = _index_rows(board.rows)
			if rows.size() != 4:
				return false
			for index in simulation.students.size():
				var student: Dictionary = simulation.students[index]
				var dorm_gain: float = dorm_gains[student.id][subject] - dorm_baseline[student.id][subject]
				_close(rows[student.id].knowledge, student.knowledge[subject] - baseline[student.id][subject] - dorm_gain, "第%d天%s按角色%s真实在校新增知识计榜" % [test_day, subject, student.id])
				_close(simulation.get_dorm_summary(test_day, index).totals[subject], dorm_gain, "第%d天%s宿舍独立明细与真实动作记录一致" % [test_day, subject])
			_check_ranking(board.rows, "knowledge", "真实每日知识榜")
			published["%d/%s" % [test_day, subject]] = board.duplicate(true)
		for previous_key: String in published:
			var parts: PackedStringArray = previous_key.split("/")
			_check(simulation.get_daily_board(int(parts[0]), parts[1]) == published[previous_key], "后续推进保持已发布历史：" + previous_key)
		for student: Dictionary in simulation.students:
			_check(student.daily_item_claim_days.size() == test_day, "连续实际课程每天各领一次物品：" + student.id)
		if test_day < 7:
			_check(not simulation.is_round_finished(), "第%d天出知识榜后继续本局" % test_day)
			if not _result(simulation.advance(86400.0 - DAILY_END), "第%d天课后真实执行到次日午夜" % test_day, simulation.error_message):
				return false
			_check(simulation.day == test_day + 1 and simulation.clock_seconds == 0.0, "真实跨午夜后进入下一局内日")
	_check(simulation.is_round_finished(), "第7天16:40进入已结束状态")
	_close(simulation.elapsed_s, 6.0 * 86400.0 + DAILY_END, "终局只记录真实推进至16:40的在线秒数")
	var totals: Dictionary = simulation.get_final_board()
	if not _check(totals.status == "published" and totals.rows.size() == 4, "完整七天局具有四人最终榜"):
		return false
	var units_by_student: Dictionary = {}
	for student: Dictionary in simulation.students:
		units_by_student[student.id] = 0
	for subject: String in SUBJECTS:
		var exam: Dictionary = simulation.get_exam_board(subject)
		if not _check(exam.status == "published" and exam.rows.size() == 4, "最终榜四科均有真实已发布成绩：" + subject):
			return false
		_check(exam.source == "online", "实际在线开考不能标为离线冻结来源")
		for row: Dictionary in exam.rows:
			_check_subject_formula(row, "连续七天" + subject)
			units_by_student[row.student_id] += int(row.score_units)
		_check_ranking(exam.rows, "score_units", "单科成绩榜")
	for row: Dictionary in totals.rows:
		_check(row.score_units == units_by_student[row.student_id], "总分逐科先舍入再用整数刻度相加：" + row.student_id)
		_check(row.subject_scores.size() == 4, "最终榜展示四科来源：" + row.student_id)
	_check_ranking(totals.rows, "score_units", "真实最终榜")
	_check(simulation.students.all(func(student: Dictionary): return student.current_action.is_empty()), "终局四人均不残留可执行动作")
	_check(simulation.interactions.is_empty(), "真实七天不擅自开启NPC主动互动")
	return _check_terminal_read_only(simulation, "完整七天局")


## 一秒真实学习产生小于显示精度的知识差，排序不能先按界面一位小数归组。
func _test_daily_raw_order() -> bool:
	var simulation := _new_at(1, 59999.0)
	if simulation == null:
		return false
	var attentions: Array[float] = [0.0, 0.0001, 0.0002, 0.0001]
	for index in simulation.students.size():
		simulation.students[index].attributes.attention = attentions[index]
	if not _result(simulation.advance(1.0), "16:39:59实际学习一秒后发布当日榜", simulation.error_message):
		return false
	var board: Dictionary = simulation.get_daily_board(1, "math")
	if not _check(board.status == "published" and board.rows.size() == 4, "真实末秒学习产生四人知识榜"):
		return false
	var rows: Dictionary = _index_rows(board.rows)
	if rows.size() != 4:
		return false
	_check(rows.student_2.knowledge > rows.student_1.knowledge and rows.student_1.knowledge > rows.student_0.knowledge, "微小有效专注力差异真实产生不同知识增量")
	_check(roundf(rows.student_0.knowledge * 10.0) == roundf(rows.student_2.knowledge * 10.0), "显示一位小数相同的前置确实成立")
	_check(rows.student_2.rank < rows.student_1.rank and rows.student_1.rank < rows.student_0.rank, "知识名次按真实未舍入值排序")
	_check(rows.student_1.knowledge == rows.student_3.knowledge and rows.student_1.rank == rows.student_3.rank, "真正相同的增量仍并列")
	return true


## 明确的开考前知识与属性夹具只用于可验证算例，所有快照、发布和动作仍走生产边界。
func _test_snapshot_and_hot_reload() -> bool:
	var simulation := _new_at(7, 50399.0)
	if simulation == null:
		return false
	for index in simulation.students.size():
		var student: Dictionary = simulation.students[index]
		student.attributes.intelligence = 2.0
		for subject: String in SUBJECTS:
			student.knowledge[subject] = 100.0 if index < 2 else 200.0 + index
	_check(simulation.get_exam_board("chinese").status == "pending", "13:59:59语文尚未开考")
	if not _result(simulation.advance(1.0), "真实跨过14:00边界", simulation.error_message):
		return false
	var chinese: Dictionary = simulation.get_exam_board("chinese")
	if not _check(chinese.status == "snapshot" and chinese.rows.size() == 4, "14:00语文只保存快照而不提前公布"):
		return false
	var physical: Dictionary = simulation.get_exam_board("physical")
	_check(physical.status == "published", "体育14:00取值并即时公布，不占额外课时")
	_close(physical.start_seconds, 50400.0, "体育14:00取值")
	_close(physical.end_seconds, 50400.0, "体育14:00即发布")
	for row: Dictionary in chinese.rows:
		_check(row.effective_intelligence == 2.0, "语文快照使用开考有效智力")
		_check_subject_formula(row, "语文开考快照")
	for repeat in 3:
		if not _result(simulation.focus_command(), "开考后重复专注%d" % repeat, simulation.error_message):
			return false
	if not _result(simulation.start_interaction(0, 1, "send_note", "开考后的真实纸条"), "考试中发起真实纸条", simulation.error_message):
		return false
	if not _result(simulation.advance(20.0), "真实纸条完成后继续考试", simulation.error_message):
		return false
	_check(simulation.notes.size() == 1, "互动仍按真实完成送达")
	_check(simulation.get_exam_board("chinese") == chinese, "重复专注与真实纸条不能重取语文快照")
	for student: Dictionary in simulation.students:
		student.attributes.intelligence = 8.0
		student.knowledge.chinese += 500.0
	var changed := _changed_config("future_score_parameters.json", 0.06, 120.0, 2)
	if changed == null or not _result(simulation.apply_config(changed), "开考后更新未来计分参数", simulation.error_message):
		return false
	_check(simulation.get_exam_board("chinese") == chinese, "调表与当前知识/智力变化不重算已取值语文")
	_check(simulation.get_exam_board("physical") == physical, "调表不覆写14:00已公布体育")
	if not _result(simulation.advance(53099.0 - simulation.clock_seconds), "推进至语文结束前一秒", simulation.error_message):
		return false
	_check(simulation.get_exam_board("chinese").status == "snapshot", "语文44分59秒仍未公布")
	if not _result(simulation.advance(1.0), "语文45分钟结束后实际公布", simulation.error_message):
		return false
	var chinese_published: Dictionary = simulation.get_exam_board("chinese")
	_check(chinese_published.status == "published" and chinese_published.rows == chinese.rows, "公布只改变状态，不重算开考成绩")
	if not _result(simulation.advance(600.0), "真实推进至14:55数学开考", simulation.error_message):
		return false
	var mathematics: Dictionary = simulation.get_exam_board("math")
	if not _check(mathematics.status == "snapshot" and mathematics.rows.size() == 4, "数学按自身开考边界取值"):
		return false
	for row: Dictionary in mathematics.rows:
		_check(row.effective_intelligence == 8.0 and row.exam_intelligence_coefficient == 0.06 and row.max_score == 120.0 and row.score_decimal_places == 2, "数学采用尚未取值前的新属性与计分参数")
		_check_subject_formula(row, "数学新参数快照")
	if not _result(simulation.advance(DAILY_END - simulation.clock_seconds), "继续真实执行英语及最终发布", simulation.error_message):
		return false
	var totals: Dictionary = simulation.get_final_board()
	if not _check(totals.status == "published", "三场考试真实完成后可以发布总榜"):
		return false
	var by_student: Dictionary = _index_rows(totals.rows)
	_check(by_student.student_0.score_units == by_student.student_1.score_units and by_student.student_0.rank == by_student.student_1.rank, "相同培养结果同分并列，不随机拆名次")
	var final_units: Dictionary = {}
	for student: Dictionary in simulation.students:
		final_units[student.id] = 0
	for subject: String in SUBJECTS:
		for row: Dictionary in simulation.get_exam_board(subject).rows:
			final_units[row.student_id] += int(row.score_units) * int(pow(10.0, 2 - row.score_decimal_places))
	for row: Dictionary in totals.rows:
		_check(row.score_decimal_places == 2 and row.score_units == final_units[row.student_id], "历史不同小数位先精确换算总分刻度，不重新舍入单科")
	return true


## 到期状态作为明确测试前置，不伪装成新增玩法来源；到期处理仍由真实时间执行器完成。
func _test_boundary_expiration() -> bool:
	var simulation := _new_at(7, 50399.0)
	if simulation == null:
		return false
	for student: Dictionary in simulation.students:
		student.attributes.intelligence = 2.0
		student.knowledge.chinese = 100.0
		student.buffs.append({"buff_id": "inspired", "expires_at": simulation.elapsed_s + 1.0, "action_instance_id": null})
	_check(simulation.effective_attribute(0, "intelligence") == 3.0, "显式到期夹具在开考前真实生效")
	if not _result(simulation.advance(1.0), "状态与开考同刻边界真实处理", simulation.error_message):
		return false
	var board: Dictionary = simulation.get_exam_board("chinese")
	if not _check(board.status == "snapshot" and board.rows.size() == 4, "同刻到期后仍保存真实四人快照"):
		return false
	for row: Dictionary in board.rows:
		_check(row.effective_intelligence == 2.0, "已到期智力修正不进入开考快照")
	_check(simulation.students.all(func(student: Dictionary): return student.buffs.is_empty()), "同刻到期状态从四人权威状态移除")
	return true


## 时间回退只重复走实际执行器，已发生事件不因再次过界被重取或覆盖。
func _test_rewind_keeps_history() -> bool:
	var simulation := _new_at(7, 50399.0)
	if simulation == null:
		return false
	for student: Dictionary in simulation.students:
		student.knowledge.chinese = 100.0
	if not _result(simulation.advance(2701.0), "首次真实取值并公布语文", simulation.error_message):
		return false
	var chinese: Dictionary = simulation.get_exam_board("chinese").duplicate(true)
	var physical: Dictionary = simulation.get_exam_board("physical").duplicate(true)
	for student: Dictionary in simulation.students:
		student.knowledge.chinese += 200.0
		student.attributes.intelligence += 5.0
	if not _result(simulation.set_debug_time(7, 50399.0), "已出榜局显式回退至开考前", simulation.error_message):
		return false
	if not _result(simulation.advance(2701.0), "再次真实经过语文快照和发布边界", simulation.error_message):
		return false
	_check(simulation.get_exam_board("chinese") == chinese, "日期回退不覆盖旧语文快照或成绩")
	_check(simulation.get_exam_board("physical") == physical, "日期回退不重复取体育成绩")
	return true


## 恰好到期的完成先结算；结束边界仍未完成的纸条整体打断，不产生送达或后续动作。
func _test_terminal_interactions() -> bool:
	for completes_at_boundary in [false, true]:
		var start_seconds: float = 59980.0 if completes_at_boundary else 59999.0
		var simulation := _new_at(7, start_seconds)
		if simulation == null:
			return false
		if not _result(simulation.start_interaction(0, 1, "send_note", "终局时序验证"), "临近终局发动真实纸条", simulation.error_message):
			return false
		var before_rng: String = str(simulation.rng.state)
		if not _result(simulation.advance(DAILY_END - start_seconds), "真实执行至终局边界", simulation.error_message):
			return false
		_check(simulation.is_round_finished(), "纸条不会阻止七日局按时结束")
		_check(simulation.notes.size() == (1 if completes_at_boundary else 0), "恰好完成才送达，仍未完成不送达")
		_check(simulation.interactions[0].status == ("completed" if completes_at_boundary else "interrupted"), "终局互动记录真实反映完成或打断")
		_check(simulation.students.all(func(student: Dictionary): return student.current_action.is_empty()), "局末清理双方及其他同学活动")
		_check(str(simulation.rng.state) == before_rng, "终局不额外选动作或消费奖励随机流")
		if not _check_terminal_read_only(simulation, "临近终局纸条"):
			return false
	return true


## 已结束局只读与保存仍可用，任何后续时间推进和拒绝指令均不能改变权威结果。
func _check_terminal_read_only(simulation: ClassroomSimulation, label: String) -> bool:
	var before_students: Array = simulation.students.duplicate(true)
	var before_rng: String = str(simulation.rng.state)
	var before_time: float = simulation.elapsed_s
	var before_boards: Array = [simulation.get_final_board(), simulation.get_exam_board("chinese"), simulation.get_daily_board(7, "chinese")]
	var before_notes: Array = simulation.notes.duplicate(true)
	if not _result(simulation.advance(3.0 * 86400.0), label + "结束后推进明确不再执行玩法", simulation.error_message):
		return false
	_check(simulation.focus_command() != OK and not simulation.error_message.is_empty(), label + "结束后专注明确拒绝")
	_check(simulation.start_action(0, "rest") != OK and not simulation.error_message.is_empty(), label + "结束后普通动作明确拒绝")
	_check(simulation.start_interaction(0, 1, "send_note", "结束后不应送达") != OK and not simulation.error_message.is_empty(), label + "结束后双人互动明确拒绝")
	_check(simulation.students == before_students and str(simulation.rng.state) == before_rng and simulation.notes == before_notes, label + "终局推进与拒绝指令均不改人物、物品、纸条或随机流")
	_close(simulation.elapsed_s, before_time, label + "结束后不扩大在线动作时长")
	_check([simulation.get_final_board(), simulation.get_exam_board("chinese"), simulation.get_daily_board(7, "chinese")] == before_boards, label + "终局可查阅真实历史且无副作用")
	var path: String = fixture_root.path_join("finished_%d.json" % fixture_files.size())
	fixture_files.append(path)
	fixture_files.append(path + ".tmp")
	return _result(simulation.save_file(path), label + "终局仍能真实保存", simulation.error_message)


## 配置变化只写缓存副本并走正式校验，不改权威数值源或阶段动作范围。
func _changed_config(filename: String, coefficient: float, chinese_math_score: float, decimal_places: int = 1) -> GameConfig:
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://config/game_config.json"))
	for row: Dictionary in data.tables.globals:
		if row.key == "exam_intelligence_coefficient":
			row.value = coefficient
		elif row.key == "score_decimal_places":
			row.value = decimal_places
	for row: Dictionary in data.tables.subjects:
		if row.id in ["chinese", "math"]:
			row.max_score = chinese_math_score
	var path: String = fixture_root.path_join(filename)
	fixture_files.append(path)
	var output := FileAccess.open(path, FileAccess.WRITE)
	if not _check(output != null, "计分配置副本可写"):
		return null
	output.store_string(JSON.stringify(data, "", true, true))
	output.close()
	var loaded := GameConfig.new()
	if not _result(loaded.load_file(path), "未来计分参数副本通过生产校验", loaded.error_message):
		return null
	return loaded


## 对知识字典创建只读基线，避免把后续原地变化当作当日开始值。
func _knowledge_by_student(simulation: ClassroomSimulation) -> Dictionary:
	var result: Dictionary = {}
	for student: Dictionary in simulation.students:
		result[student.id] = student.knowledge.duplicate(true)
	return result


## 从已结束日志和唯一在途实例独立汇总宿舍知识，不用被测日榜或宿舍账本生成预期。
func _dorm_knowledge_by_student(simulation: ClassroomSimulation) -> Dictionary:
	var result: Dictionary = {}
	for index in simulation.students.size():
		var student: Dictionary = simulation.students[index]
		result[student.id] = {"chinese": 0.0, "math": 0.0, "english": 0.0, "physical": 0.0}
		for entry: Dictionary in simulation.logs:
			if entry.student_index == index and entry.type in ["complete", "interrupt"] and entry.details.knowledge_source == "dorm":
				result[student.id][entry.details.subject_id] += entry.details.knowledge_gain
		var action: Dictionary = student.current_action
		if not action.is_empty() and simulation.config.actions[action.action_id].knowledge_source == "dorm":
			result[student.id][action.subject_id] += action.knowledge_gain
	return result


## 榜单必须包含唯一的四名真实角色，结构错误立即显式保留失败。
func _index_rows(rows: Array) -> Dictionary:
	var result: Dictionary = {}
	for row: Dictionary in rows:
		if not _check(row.has_all(["student_id", "name", "rank"]) and not result.has(row.student_id), "榜单行身份、姓名和名次完整且角色唯一"):
			return {}
		result[row.student_id] = row
	return result


## 用独立公式核对正常数值算例，避免直接调用被测计分器来证明自身正确。
func _check_subject_formula(row: Dictionary, label: String) -> void:
	if not _check(row.has_all(["knowledge", "effective_intelligence", "max_score", "score_scale", "exam_intelligence_coefficient", "score_decimal_places", "score_units", "score"]), label + "保留可解释的完整开考参数"):
		return
	var scale: float = pow(10.0, row.score_decimal_places)
	var effective_knowledge: float = row.knowledge * (1.0 + row.exam_intelligence_coefficient * row.effective_intelligence)
	var expected_units: int = int(roundf(row.max_score * (1.0 - exp(-effective_knowledge / row.score_scale)) * scale))
	_check(row.score_units == expected_units, label + "单科依据真实保存参数先舍入")
	_close(row.score, float(expected_units) / scale, label + "显示分数与整数刻度一致")


## 降序名次只依赖真实值，相同值必须并列，不对未确认的跳号样式作假设。
func _check_ranking(rows: Array, value_key: String, label: String) -> void:
	if not _check(rows.size() == 4 and rows[0].rank == 1, label + "四人榜从第一名开始"):
		return
	for index in range(1, rows.size()):
		var previous: Dictionary = rows[index - 1]
		var current: Dictionary = rows[index]
		_check(previous[value_key] >= current[value_key], label + "按实际值降序")
		_check(current.rank == previous.rank if current[value_key] == previous[value_key] else current.rank > previous.rank, label + "同值同名次，低值排后")


## 所有生产入口错误携带原始原因并让当前场景停止。
func _result(result: Error, message: String, detail: String = "") -> bool:
	return _check(result == OK, "%s：错误码%d %s" % [message, result, detail])


## 普通知识、时间和成绩比较只使用小容差，不改动被测权威数值。
func _close(actual: float, expected: float, message: String) -> void:
	_check(absf(actual - expected) < 0.000001, "%s：实际%s，预期%s" % [message, actual, expected])


## 每条断言真实计数，结构或业务失败均进入最终非零退出码。
func _check(condition: bool, message: String) -> bool:
	checks += 1
	if not condition:
		failures.append(message)
	return condition


## 释放真实树；成功只删除本次登记文件，失败保留独占目录便于定位。
func _finish() -> void:
	for controller in owned_controllers:
		controller.free()
	if failures.is_empty():
		for path: String in fixture_files:
			if FileAccess.file_exists(path):
				_result(DirAccess.remove_absolute(path), "清理本次七天局文件")
		if not fixture_root.is_empty():
			_result(DirAccess.remove_absolute(fixture_root), "清理独占七天局目录")
	if failures.is_empty():
		print("SEVEN_DAY_ROUND_TEST_PASS checks=%d" % checks)
		quit(0)
	else:
		for message: String in failures:
			push_error(message)
		print("SEVEN_DAY_ROUND_TEST_FAIL checks=%d failures=%d fixtures=%s" % [checks, failures.size(), fixture_root])
		quit(1)
