extends SceneTree
## 用生产保存、迁移和显式恢复入口验证七天账本，不修改系统时间或正式玩家文件。

const SUBJECTS: Array[String] = ["chinese", "math", "english", "physical"]
# 独占缓存目录与实际写入清单用于隔离配置副本、旧版夹具和损坏存档。
var fixture_root: String = ""
var fixture_files: Array[String] = []
var configuration: GameConfig
var owned_controllers: Array[ClassroomBehaviorController] = []
var checks: int = 0
var failures: Array[String] = []


## 场景树就绪后运行真实入口，不用伪造文件系统成功结果。
func _initialize() -> void:
	call_deferred("_run")


## 每个场景必须真实执行至返回，任何运行时错误均不能跳过验证却输出通过。
func _run() -> void:
	configuration = GameConfig.new()
	if not _result(configuration.load_file(), "正式配置加载", configuration.error_message):
		_finish()
		return
	fixture_root = OS.get_cache_dir().path_join("ClassroomRoundSave_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	if not _result(DirAccess.make_dir_recursive_absolute(fixture_root), "创建独占持久化验证目录"):
		_finish()
		return
	_check(_test_roundtrip(), "v4在途互动、开考快照和终局往返完整执行")
	_check(_test_large_units_roundtrip(), "超过JSON精确整数范围的总分刻度仍可原样往返")
	_check(_test_rewound_roundtrip(), "开发回退保存后仍可证明并保留已发生的未来历史")
	_check(_test_offline_same_course(), "同课恢复保留真实剩余动作时长")
	_check(_test_offline_frozen_events(), "跨天多考试只补冻结纯事件，不补在线执行")
	_check(_test_legacy_migration(), "v1至v3保留原进度并明确标记缺失历史")
	_check(_test_legacy_pair_migration(), "v2和v3迁移保留真实在途互动及仅剩进度")
	_check(_test_legacy_missed_exams(), "旧档错过开考不造分，终局明确缺项")
	_check(_test_corrupt_snapshots(), "损坏新版账本在覆盖有效局前明确拒绝")
	_finish()


## 建立四人执行器和真实树，读取文件前不提前启动或抽取课程动作。
func _empty_simulation(game_config: GameConfig = null, seed_value: int = 261107) -> ClassroomSimulation:
	var simulation := ClassroomSimulation.new()
	var source: GameConfig = configuration if game_config == null else game_config
	if not _result(simulation.setup(source, seed_value), "建立隔离四人局", simulation.error_message):
		return null
	var controller := ClassroomBehaviorController.new()
	root.add_child(controller)
	controller.setup(simulation)
	owned_controllers.append(controller)
	simulation.decision_handler = controller.decide
	return simulation


## 开发时钟只定位真实入口，后续推进仍通过四棵生产行为树。
func _new_at(test_day: int, seconds: float, game_config: GameConfig = null) -> ClassroomSimulation:
	var simulation := _empty_simulation(game_config)
	if simulation == null:
		return null
	if not _result(simulation.set_debug_time(test_day, seconds), "显式定位隔离开发时间", simulation.error_message):
		return null
	if not _result(simulation.advance(0.0), "生产树开始当前课表", simulation.error_message):
		return null
	return simulation


## 保存后恢复在途纸条、语文快照与随机状态；剩余时间真实完成后再比较终局。
func _test_roundtrip() -> bool:
	var source := _new_at(7, 50399.0)
	if source == null:
		return false
	if not _result(source.advance(1.0), "真实生成14:00考试快照", source.error_message):
		return false
	if not _result(source.start_interaction(0, 1, "send_note", "存档后继续真实纸条"), "考试中实际发动纸条", source.error_message):
		return false
	if not _result(source.advance(5.0), "先执行纸条五秒", source.error_message):
		return false
	var saved: Dictionary = _snapshot(source, "roundtrip_active.json")
	if not _check(not saved.is_empty() and saved.save_version == 4 and saved.has("round_progression"), "生产写出完整v4账本"):
		return false
	_check(saved.round_progression.exams.chinese.rows[0].score_units is String, "成绩整数磁盘使用精确十进制文本")
	var restored := _empty_simulation()
	if restored == null or not _result(restored.load_file(_path("roundtrip_active.json"), false), "恢复原时刻在途互动与快照", restored.error_message):
		return false
	_check(_same(restored.students, source.students) and _same(restored.interactions, source.interactions) and _same(restored.notes, source.notes), "人物、纸条与互动关联往返原样保留：" + _difference(restored.students, source.students))
	_check(str(restored.rng.state) == str(source.rng.state), "恢复不重抽动作或每日奖励随机流")
	_close(restored.elapsed_s, source.elapsed_s, "在线已执行时间精确保留")
	_check(_same(restored.get_exam_board("chinese"), source.get_exam_board("chinese")), "开考快照不因读档重新取值")
	_check(_same(restored.get_exam_board("physical"), source.get_exam_board("physical")), "已公布体育成绩不因读档重算")
	for subject: String in SUBJECTS:
		_check(_same(restored.get_daily_board(7, subject), source.get_daily_board(7, subject)), "当天真实增量账本往返：" + subject)
	if not _result(source.advance(15.0), "原局执行纸条剩余十五秒", source.error_message) or not _result(restored.advance(15.0), "恢复局执行同样剩余十五秒", restored.error_message):
		return false
	_check(source.notes.size() == 1 and _same(restored.notes, source.notes), "原局与读档局各真实送达一次")
	_check(_same(restored.students, source.students) and str(restored.rng.state) == str(source.rng.state), "继续执行后状态与随机流保持确定性：" + _difference(restored.students, source.students))
	if not _result(restored.advance(60000.0 - restored.clock_seconds), "读档局真实执行至七天结束", restored.error_message):
		return false
	var terminal: Dictionary = _snapshot(restored, "roundtrip_finished.json")
	if terminal.is_empty():
		return false
	var finished := _empty_simulation()
	if finished == null or not _result(finished.load_file(_path("roundtrip_finished.json"), false), "恢复已结束局", finished.error_message):
		return false
	_check(finished.is_round_finished() and _same(finished.students, restored.students), "终局状态与无在途动作保存往返")
	_check(_same(finished.get_final_board(), restored.get_final_board()), "真实最终成绩、缺项状态及来源保持不变")
	var frozen_students: Array = finished.students.duplicate(true)
	var frozen_rng: String = str(finished.rng.state)
	if not _result(finished.advance(86400.0), "已结束读档局不再执行下一天", finished.error_message):
		return false
	_check(finished.students == frozen_students and str(finished.rng.state) == frozen_rng, "已结束读档局不再学习或发奖")
	return true


## 四科分别可精确表示，整数求和故意跨过2^53；只用字符串保存才能避免把奇数总刻度改成偶数。
func _test_large_units_roundtrip() -> bool:
	var source_config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://config/game_config.json"))
	for row: Dictionary in source_config.tables.globals:
		if row.key == "score_decimal_places":
			row.value = 0
	for row: Dictionary in source_config.tables.subjects:
		if row.kind == "knowledge":
			row.max_score = 1000000000000000 if row.id == "physical" else 3000000000000001
	if not _write_json("large_units_config.json", source_config):
		return false
	var large_config := GameConfig.new()
	if not _result(large_config.load_file(_path("large_units_config.json")), "大整数刻度副本通过真实配置校验", large_config.error_message):
		return false
	var source := _new_at(7, 50399.0, large_config)
	if source == null:
		return false
	# 明确的开考前知识前置让各科自然趋近满分，不填成绩或完成记录。
	for student: Dictionary in source.students:
		for subject: String in SUBJECTS:
			student.knowledge[subject] = 1000000.0
	if not _result(source.advance(9601.0), "四科按真实边界开考公布并形成大整数总分", source.error_message):
		return false
	var totals: Dictionary = source.get_final_board()
	if not _check(totals.status == "published" and totals.rows.size() == 4, "大整数刻度依然产生真实四人最终榜"):
		return false
	for row: Dictionary in totals.rows:
		_check(row.score_units == 10000000000000003, "四科相加保留超过2^53的奇数整数总刻度")
	var saved: Dictionary = _snapshot(source, "large_units_finished.json")
	if saved.is_empty():
		return false
	_check(saved.round_progression.final.rows[0].score_units == "10000000000000003", "磁盘总刻度不是损失精度的JSON数字")
	var restored := _empty_simulation(large_config)
	if restored == null or not _result(restored.load_file(_path("large_units_finished.json"), false), "大整数终局通过真实读取验证", restored.error_message):
		return false
	for row: Dictionary in restored.get_final_board().rows:
		_check(row.score_units is int and row.score_units == 10000000000000003, "重读后总刻度仍为原始int64奇数")
	return true


## 保存当前时刻与历史最远边界分开，合法回退不能被误当成伪造未来成绩。
func _test_rewound_roundtrip() -> bool:
	var scenarios: Array[Dictionary] = [
		{"day": 1, "start": 0.0, "duration": 60000.0, "rewind": 28800.0},
		{"day": 7, "start": 50399.0, "duration": 2701.0, "rewind": 50399.0},
	]
	for index in scenarios.size():
		var scenario: Dictionary = scenarios[index]
		var source := _new_at(scenario.day, scenario.start)
		if source == null or not _result(source.advance(scenario.duration), "回退前真实形成日榜或考试历史", source.error_message):
			return false
		var history: Dictionary = {}
		for subject: String in SUBJECTS:
			history[subject] = source.get_daily_board(scenario.day, subject)
		if not _result(source.set_debug_time(scenario.day, scenario.rewind), "形成历史后显式回退开发时间", source.error_message):
			return false
		for subject: String in SUBJECTS:
			var after_rewind: Dictionary = source.get_daily_board(scenario.day, subject)
			if history[subject].status == "published":
				_check(_same(after_rewind, history[subject]), "已发布日榜在回退时立即保持原样")
			# 尚未发布的当天范围可以显式标注开发时钟跳转，不能把它误当作已发布历史。
			history[subject] = after_rewind
		var filename: String = "rewound_history_%d.json" % index
		if _snapshot(source, filename).is_empty():
			return false
		var restored := _empty_simulation()
		if restored == null or not _result(restored.load_file(_path(filename), false), "合法已发生历史在回退档中真实重读", restored.error_message):
			return false
		for subject: String in SUBJECTS:
			_check(_same(restored.get_daily_board(scenario.day, subject), source.get_daily_board(scenario.day, subject)), "回退重读不删除已发生日榜")
			_check(_same(restored.get_exam_board(subject), source.get_exam_board(subject)), "回退重读不删除已发生考试快照或成绩")
		var advance_to: float = 60000.0 if scenario.day == 1 else 53100.0
		if not _result(restored.advance(advance_to - restored.clock_seconds), "回退档再次真实经过原历史边界", restored.error_message):
			return false
		for subject: String in SUBJECTS:
			_check(_same(restored.get_daily_board(scenario.day, subject), history[subject]), "再次过界不覆写旧日榜")
			_check(_same(restored.get_exam_board(subject), source.get_exam_board(subject)), "再次过界不重算旧开考快照")
	return true


## 显式恢复目标与原课程相同，关闭时长不能变成纸条进度、定时状态消耗或知识收益。
func _test_offline_same_course() -> bool:
	var source := _new_at(7, 50399.0)
	if source == null or not _result(source.advance(101.0), "进入语文考试实际执行100秒", source.error_message):
		return false
	if not _result(source.start_interaction(0, 1, "send_note", "同课恢复不提前送达"), "开始待恢复真实纸条", source.error_message):
		return false
	source.students[2].buffs.append({"buff_id": "inspired", "expires_at": source.elapsed_s + 300.0, "action_instance_id": null})
	if not _result(source.advance(5.0), "保存前实际执行五秒", source.error_message):
		return false
	var saved: Dictionary = _snapshot(source, "same_course.json")
	if saved.is_empty():
		return false
	var restored := _empty_simulation()
	if restored == null or not _result(restored.load_file_at_time(_path("same_course.json"), 7, source.clock_seconds + 100.0), "显式恢复到关闭一百秒后的同一课程", restored.error_message):
		return false
	_check(_same(restored.students, source.students), "同课恢复保留资源、知识、库存、原动作与Buff到期时刻：" + _difference(restored.students, source.students))
	_check(restored.notes.is_empty() and restored.interactions[0].status == "active", "纸条关闭期间不完成也不送达")
	_close(restored.elapsed_s, source.elapsed_s, "关闭期间不增加在线时长")
	_check(str(restored.rng.state) == str(source.rng.state), "同课恢复不消费随机流")
	_check(_same(restored.get_exam_board("chinese"), source.get_exam_board("chinese")), "已有快照不因晚恢复同课而替换")
	if not _result(restored.advance(14.75), "恢复后实际执行至纸条完成前四分之一秒", restored.error_message):
		return false
	_check(restored.notes.is_empty(), "读档后仍须实际执行原剩余十五秒")
	if not _result(restored.advance(0.25), "恢复后精确执行到纸条真实完成边界", restored.error_message):
		return false
	_check(restored.notes.size() == 1 and restored.interactions[0].status == "completed", "纸条只在恢复后真实运行足够时长才送达")
	return true


## 保存独立有效智力与旧计分参数，恢复时即使活体动作被打断和配置已更新也只用冻结来源。
func _test_offline_frozen_events() -> bool:
	var original_config := _variant_config("frozen_source_config.json", 0.03, 150.0, 4.0)
	var later_config := _variant_config("frozen_later_config.json", 0.08, 120.0, 9.0)
	if original_config == null or later_config == null:
		return false
	var source := _new_at(4, 59985.0, original_config)
	if source == null:
		return false
	# 这是可解释的退出前状态夹具，不填日榜、快照或成绩完成记录。
	for index in source.students.size():
		var student: Dictionary = source.students[index]
		student.attributes.intelligence = 2.0
		for subject: String in SUBJECTS:
			student.knowledge[subject] = 100.0 + index * 10.0
	if not _result(source.start_interaction(0, 1, "send_note", "关闭期间不得送达"), "退出前真实发起纸条", source.error_message):
		return false
	for student: Dictionary in source.students:
		student.buffs.append({"buff_id": "sprinting", "expires_at": null, "action_instance_id": student.current_action.instance_id})
	if not _result(source.advance(5.0), "退出前仅真实执行五秒", source.error_message):
		return false
	var before_students: Array = source.students.duplicate(true)
	var before_rng: String = str(source.rng.state)
	var before_elapsed: float = source.elapsed_s
	var saved: Dictionary = _snapshot(source, "frozen_exit.json")
	if saved.is_empty():
		return false
	_check(saved.round_progression.frozen.students[0].effective_intelligence == 6.0, "保存明确冻结退出时的有效智力")
	var restored := _empty_simulation(later_config)
	if restored == null or not _result(restored.load_file_at_time(_path("frozen_exit.json"), 7, 60000.0), "跨日跨过全部考试边界的显式恢复", restored.error_message):
		return false
	_check(restored.is_round_finished(), "离线跨过16:40后发布纯事件并进入终局")
	_close(restored.elapsed_s, before_elapsed, "离线多日不增加在线动作时长")
	_check(str(restored.rng.state) == before_rng, "离线不选新动作或抽取奖励随机数")
	_check(restored.notes.is_empty() and restored.interactions[0].status == "interrupted", "真实纸条离线跨课被打断而非完成")
	for index in restored.students.size():
		var student: Dictionary = restored.students[index]
		_close(student.focus, before_students[index].focus, "离线不恢复或消耗专注")
		_close(student.stamina, before_students[index].stamina, "离线不恢复或消耗体力")
		_check(_same(student.knowledge, before_students[index].knowledge), "离线不增加任何科目知识")
		_check(_same(student.inventory, before_students[index].inventory) and _same(student.daily_item_claim_days, before_students[index].daily_item_claim_days), "离线不补第7天物品或领取记录")
		_check(student.current_action.is_empty() and student.buffs.is_empty(), "跨课打断与终局清理动作所属状态")
		_close(restored.effective_attribute(index, "intelligence"), 2.0, "活体动作智力Buff已清理")
	for subject: String in SUBJECTS:
		var exam: Dictionary = restored.get_exam_board(subject)
		if not _check(exam.status == "published" and exam.source == "offline_frozen" and exam.rows.size() == 4, "多考试均由明确离线冻结来源结算：" + subject):
			return false
		for row: Dictionary in exam.rows:
			var index: int = int(row.student_id.trim_prefix("student_"))
			_close(row.knowledge, before_students[index].knowledge[subject], "考试使用退出前冻结科目知识")
			_close(row.effective_intelligence, 6.0, "考试保留退出时智力，不能重读清理后或新配表智力")
			_close(row.exam_intelligence_coefficient, 0.03, "离线考试保留原系数")
			_close(row.max_score, 50.0 if subject == "physical" else 150.0, "离线考试保留退出时原科目满分")
			_check(row.config_fingerprint == original_config.fingerprint, "冻结成绩可追溯退出时配置")
		var daily: Dictionary = restored.get_daily_board(7, subject)
		if not _check(daily.status == "published" and daily.source == "offline_frozen", "关闭期间第7天日榜明确采用冻结事件来源"):
			return false
		for row: Dictionary in daily.rows:
			_close(row.knowledge, 0.0, "关闭整日没有虚构当日知识增量")
	_check(restored.get_daily_board(4, "chinese").source == "offline_frozen", "退出当天越过日榜边界也标明离线来源")
	for skipped_day in [5, 6]:
		for subject: String in SUBJECTS:
			var skipped: Dictionary = restored.get_daily_board(skipped_day, subject)
			_check(skipped.status == "published" and skipped.source == "offline_frozen", "连续关闭期间跨日知识榜逐日标明冻结来源")
			for row: Dictionary in skipped.rows:
				_close(row.knowledge, 0.0, "连续关闭整日没有新增知识")
	_check(restored.get_final_board().status == "published", "冻结三科与体育齐全时生成真实完整总榜")
	var first_boards: Array = _boards(restored)
	var first_students: Array = restored.students.duplicate(true)
	if not _result(restored.load_file_at_time(_path("frozen_exit.json"), 7, 60000.0), "反复读取同一退出档并恢复同一目标", restored.error_message):
		return false
	_check(_boards(restored) == first_boards and restored.students == first_students and restored.notes.is_empty(), "重复恢复不增加成绩、奖励、知识或纸条送达")
	var saved_after: Dictionary = _snapshot(restored, "frozen_finished.json")
	if saved_after.is_empty():
		return false
	var again := _empty_simulation(later_config)
	if again == null or not _result(again.load_file_at_time(_path("frozen_finished.json"), 9, 70000.0), "已结束v4再次跨日恢复", again.error_message):
		return false
	_check(_same(_boards(again), first_boards) and _same(again.students, first_students) and again.clock_seconds == 60000.0 and again.day == 7, "已结束局再次恢复保持终局时刻与全部原结果")
	return true


## 旧字段仅从真实保存降版删除当时不存在的新字段，养成、在途动作与领取记录按原版本保留。
func _test_legacy_migration() -> bool:
	var source := _new_at(2, 30600.0)
	if source == null or not _result(source.advance(60.0), "旧档源执行真实数学一分钟", source.error_message):
		return false
	var snapshot: Dictionary = _snapshot(source, "legacy_source.json")
	if snapshot.is_empty():
		return false
	for version in [1, 2, 3]:
		var filename: String = "legacy_v%d.json" % version
		var legacy: Dictionary = _legacy(snapshot, version)
		if not _write_json(filename, legacy):
			return false
		var restored := _empty_simulation()
		if restored == null or not _result(restored.load_file(_path(filename), false), "显式迁移v%d旧档" % version, restored.error_message):
			return false
		for index in source.students.size():
			for key: String in ["attributes", "unspent_points", "focus", "stamina", "knowledge", "inventory", "buffs", "current_action"]:
				_check(_same(restored.students[index][key], source.students[index][key]), "v%d迁移不改变角色%d的%s" % [version, index, key])
			_check(restored.students[index].daily_item_claim_days == (source.students[index].daily_item_claim_days if version == 3 else []), "v3领取日保留，v1/v2不猜旧领取史")
		_check(str(restored.rng.state) == str(source.rng.state) and restored.next_action_number == source.next_action_number, "旧档迁移不重开动作或抽取随机数")
		_close(restored.elapsed_s, source.elapsed_s, "旧档迁移保持原在线时长")
		var missing: Dictionary = restored.get_daily_board(1, "math")
		_check(missing.status == "unrecorded" and not missing.reason.is_empty() and missing.rows.is_empty(), "旧档过去榜明确未记录而非重建历史")
		var partial: Dictionary = restored.get_daily_board(2, "math")
		_check(partial.status == "pending" and not partial.reason.is_empty(), "迁移当天有显式部分统计原因")
		_close(partial.start_seconds, source.clock_seconds, "迁移当天从接入时刻统计")
		var knowledge_before: Array = restored.students.map(func(student: Dictionary): return student.knowledge.duplicate(true))
		var dorm_before: Dictionary = _dorm_knowledge_by_student(restored)
		if not _result(restored.advance(60000.0 - restored.clock_seconds), "迁移当天实际执行至日榜边界", restored.error_message):
			return false
		var dorm_after: Dictionary = _dorm_knowledge_by_student(restored)
		for subject: String in SUBJECTS:
			var board: Dictionary = restored.get_daily_board(2, subject)
			if not _check(board.status == "published" and board.knowledge_scope == "school" and board.rows.size() == 4 and not board.reason.is_empty(), "旧档接入当天发布实际部分在校日榜"):
				return false
			for row: Dictionary in board.rows:
				var index: int = int(row.student_id.trim_prefix("student_"))
				var dorm_gain: float = dorm_after[row.student_id][subject] - dorm_before[row.student_id][subject]
				_close(row.knowledge, restored.students[index].knowledge[subject] - knowledge_before[index][subject] - dorm_gain, "部分日榜只统计接入后真实在校新增")
				_close(restored.get_dorm_summary(2, index).totals[subject], dorm_gain, "迁移后宿舍收益独立记录且不反推旧档")
		var upgraded: Dictionary = _snapshot(restored, "legacy_upgraded_v%d.json" % version)
		if not _check(not upgraded.is_empty() and upgraded.save_version == 4, "旧档下次保存明确升级v4"):
			return false
		var verified := _empty_simulation()
		if verified == null or not _result(verified.load_file(_path("legacy_upgraded_v%d.json" % version), false), "迁移后v4部分日榜能完整重读", verified.error_message):
			return false
	return true


## 从动作日志和在途实例统计真实宿舍来源，保持对日榜与新账本的独立校验。
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


## 旧版已真实保存的双人关系与五秒执行结果不能因增加榜单字段被重开或丢失。
func _test_legacy_pair_migration() -> bool:
	var source := _new_at(1, 28800.0)
	if source == null or not _result(source.start_interaction(0, 1, "send_note", "旧版在途真实纸条"), "开始旧版互动迁移源", source.error_message):
		return false
	if not _result(source.advance(5.0), "旧版互动源实际执行五秒", source.error_message):
		return false
	var saved: Dictionary = _snapshot(source, "legacy_pair_source.json")
	if saved.is_empty():
		return false
	for version in [2, 3]:
		var filename: String = "legacy_pair_v%d.json" % version
		if not _write_json(filename, _legacy(saved, version)):
			return false
		var restored := _empty_simulation()
		if restored == null or not _result(restored.load_file(_path(filename), false), "迁移v%d真实在途互动" % version, restored.error_message):
			return false
		_check(_same(restored.interactions, source.interactions) and restored.notes.is_empty(), "旧版互动状态与未送达语义原样保留")
		_check(_same(restored.students[0].current_action, source.students[0].current_action) and _same(restored.students[1].current_action, source.students[1].current_action), "旧版双方动作实例、已执行五秒与剩余时长保持")
		_check(restored.students[0].daily_item_claim_days == ([1] if version == 3 else []), "只有v3既有领取记录保留，不凭库存猜v2历史")
		if not _result(restored.advance(14.75), "迁移后执行到原纸条结束前四分之一秒", restored.error_message):
			return false
		_check(restored.notes.is_empty(), "旧版在途互动迁移不提前完成")
		if not _result(restored.advance(0.25), "迁移后执行满原剩余十五秒", restored.error_message):
			return false
		_check(restored.notes.size() == 1 and restored.interactions[0].status == "completed", "迁移纸条只按真实剩余时间送达一次")
	return true


## 旧档没有跨过开考时的历史，接入时的当前知识不能被当成开考快照。
func _test_legacy_missed_exams() -> bool:
	var source := _new_at(7, 54000.0)
	if source == null:
		return false
	var saved: Dictionary = _snapshot(source, "legacy_missed_source.json")
	if saved.is_empty():
		return false
	for version in [1, 2, 3]:
		var filename: String = "legacy_missed_v%d.json" % version
		if not _write_json(filename, _legacy(saved, version)):
			return false
		var restored := _empty_simulation()
		if restored == null or not _result(restored.load_file(_path(filename), false), "第7天15:00接入v%d旧档" % version, restored.error_message):
			return false
		for subject: String in ["chinese", "math", "physical"]:
			var exam: Dictionary = restored.get_exam_board(subject)
			_check(exam.status == "unrecorded" and exam.rows.is_empty() and not exam.reason.is_empty(), "错过%s开考明确缺史，不猜分或补零" % subject)
		_check(restored.get_exam_board("english").status == "pending", "接入前未开始的英语仍可正常取值")
		if not _result(restored.advance(60000.0 - restored.clock_seconds), "旧档继续真实执行英语及终局", restored.error_message):
			return false
		_check(restored.get_exam_board("english").status == "published", "旧档后续实际开考科目正常生成真实成绩")
		var final: Dictionary = restored.get_final_board()
		_check(restored.is_round_finished() and final.status == "incomplete" and final.rows.is_empty(), "缺史仍结束本局，不能伪装完整四科总分")
		_check(final.missing_subjects.size() == 3 and final.missing_subjects.has("chinese") and final.missing_subjects.has("math") and final.missing_subjects.has("physical") and not final.reason.is_empty(), "最终缺项逐科可见且原因明确")
	# 旧档若关闭期间直接错过全部开考，迁移起点是恢复时刻，不能套新版冻结方案猜历史。
	var old_source := _new_at(6, 50000.0)
	if old_source == null:
		return false
	var old_saved: Dictionary = _snapshot(old_source, "legacy_offline_source.json")
	if old_saved.is_empty() or not _write_json("legacy_offline_v3.json", _legacy(old_saved, 3)):
		return false
	var late := _empty_simulation()
	if late == null or not _result(late.load_file_at_time(_path("legacy_offline_v3.json"), 7, 60000.0), "无冻结字段的旧档跨过全部考试恢复", late.error_message):
		return false
	_check(late.is_round_finished() and late.get_final_board().status == "incomplete" and late.get_final_board().missing_subjects.size() == 4, "旧档跨过全部开考仍明确缺四科，不伪造离线冻结成绩：%s" % late.get_round_summary())
	return true


## 缺字段、重复身份、成绩篡改与时序矛盾必须在替换当前有效局之前拒绝。
func _test_corrupt_snapshots() -> bool:
	var source := _new_at(7, 50399.0)
	if source == null or not _result(source.advance(2701.0), "建立真实已公布语文与体育存档源", source.error_message):
		return false
	var snapshot: Dictionary = _snapshot(source, "corrupt_source.json")
	if snapshot.is_empty():
		return false
	var cases: Array[Dictionary] = []
	var labels: Array[String] = []
	var changed: Dictionary = snapshot.duplicate(true)
	changed.erase("round_progression")
	_add_case(cases, labels, changed, "v4缺少整个七天账本")
	changed = snapshot.duplicate(true)
	changed.round_progression.erase("frozen")
	_add_case(cases, labels, changed, "v4缺少冻结来源")
	changed = snapshot.duplicate(true)
	changed.round_progression.daily_days.erase("1")
	_add_case(cases, labels, changed, "v4缺少日期记录")
	changed = snapshot.duplicate(true)
	changed.round_progression.daily_days["8"] = changed.round_progression.daily_days["7"].duplicate(true)
	_add_case(cases, labels, changed, "v4多出日期记录")
	changed = snapshot.duplicate(true)
	changed.round_progression.frozen.students[0].knowledge.chinese += 1.0
	_add_case(cases, labels, changed, "冻结知识与真实人物不一致")
	changed = snapshot.duplicate(true)
	changed.round_progression.frozen.students[0].effective_intelligence += 1.0
	_add_case(cases, labels, changed, "同配置冻结有效智力被篡改")
	changed = snapshot.duplicate(true)
	changed.round_progression.frozen.parameters.chinese.max_score += 1.0
	_add_case(cases, labels, changed, "同配置冻结满分被篡改")
	changed = snapshot.duplicate(true)
	changed.round_progression.exams.chinese.rows[0].knowledge += 1.0
	_add_case(cases, labels, changed, "考试知识篡改但成绩未对应")
	changed = snapshot.duplicate(true)
	changed.round_progression.exams.chinese.rows[0].score_units = "01"
	_add_case(cases, labels, changed, "整数刻度非规范十进制文本")
	changed = snapshot.duplicate(true)
	changed.round_progression.exams.chinese.rows[0].score_units = 0
	_add_case(cases, labels, changed, "整数刻度被改成会丢精度的JSON数字")
	changed = snapshot.duplicate(true)
	changed.round_progression.exams.chinese.rows[1].student_id = changed.round_progression.exams.chinese.rows[0].student_id
	_add_case(cases, labels, changed, "考试行角色身份重复")
	changed = snapshot.duplicate(true)
	changed.round_progression.daily_days["7"].gains.student_0.chinese = source.students[0].knowledge.chinese + 1.0
	_add_case(cases, labels, changed, "当天增量大于真实累计知识")
	changed = snapshot.duplicate(true)
	changed.round_progression.last_position.clock_seconds += 1.0
	_add_case(cases, labels, changed, "账本时刻与主存档不一致")
	changed = snapshot.duplicate(true)
	changed.round_progression.exams.chinese.status = "pending"
	changed.round_progression.exams.chinese.rows = []
	_add_case(cases, labels, changed, "已过公布边界却伪装未开考")
	changed = snapshot.duplicate(true)
	changed.round_progression.exams.math.status = "published"
	changed.round_progression.exams.math.rows = changed.round_progression.exams.chinese.rows.duplicate(true)
	for row: Dictionary in changed.round_progression.exams.math.rows:
		row.subject_id = "math"
	_add_case(cases, labels, changed, "未来数学尚未开考却填已公布成绩")
	var future_snapshot: Dictionary = changed.duplicate(true)
	future_snapshot.round_progression.exams.math.status = "snapshot"
	_add_case(cases, labels, future_snapshot, "未来数学尚未开考却填完整快照")
	changed = snapshot.duplicate(true)
	var future_daily: Dictionary = changed.round_progression.daily_days["7"]
	future_daily.status = "published"
	future_daily.source = "online"
	for subject: String in SUBJECTS:
		var rows: Array = []
		for student: Dictionary in source.students:
			rows.append({"student_id": student.id, "name": student.name, "knowledge": 0.0, "rank": 1})
		future_daily.boards[subject] = rows
	_add_case(cases, labels, changed, "未到16:40提前公布自洽四人知识榜")
	var target := _new_at(1, 28800.0)
	if target == null or not _result(target.advance(45.0), "建立待保护的有效运行局", target.error_message):
		return false
	var protected: Dictionary = _authority(target)
	for index in cases.size():
		if not _write_json("corrupt_case.json", cases[index]):
			return false
		_check(target.load_file(_path("corrupt_case.json"), false) != OK and not target.error_message.is_empty(), "明确拒绝损坏新版：" + labels[index])
		_check(_authority(target) == protected, "拒绝前不覆盖当前有效局：" + labels[index])
	# 已终局总分必须能由单科重新验证，不能把自洽人物状态当作伪造榜单的许可。
	if not _result(source.advance(60000.0 - source.clock_seconds), "真实执行至完整考试发布", source.error_message):
		return false
	var terminal: Dictionary = _snapshot(source, "corrupt_terminal_source.json")
	if terminal.is_empty():
		return false
	terminal.round_progression.final.rows[0].score_units = str(int(terminal.round_progression.final.rows[0].score_units) + 1)
	if not _write_json("corrupt_terminal.json", terminal):
		return false
	_check(target.load_file(_path("corrupt_terminal.json"), false) != OK and not target.error_message.is_empty(), "篡改最终总分明确拒绝")
	_check(_authority(target) == protected, "最终总分损坏不覆盖当前有效局")
	return true


## 只保存真正受保护的权威状态；错误消息允许更新以展示失败原因。
func _authority(simulation: ClassroomSimulation) -> Dictionary:
	return {
		"students": simulation.students.duplicate(true), "interactions": simulation.interactions.duplicate(true),
		"notes": simulation.notes.duplicate(true), "violations": simulation.violations.duplicate(true),
		"day": simulation.day, "clock_seconds": simulation.clock_seconds, "elapsed_s": simulation.elapsed_s,
		"rng_state": str(simulation.rng.state), "next_action_number": simulation.next_action_number,
		"logs": simulation.logs.duplicate(true), "boards": _boards(simulation),
	}


## 查询所有持久历史，重复读取比较只使用真实公共接口。
func _boards(simulation: ClassroomSimulation) -> Array:
	var result: Array = [simulation.get_round_summary(), simulation.get_final_board()]
	for subject: String in SUBJECTS:
		result.append(simulation.get_exam_board(subject))
		for round_day in range(1, 8):
			result.append(simulation.get_daily_board(round_day, subject))
	return result


## JSON数字可变为浮点；只放宽数值的存储类型，结构、顺序、字段与数值仍逐项严格比较。
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
		return left == right or absf(float(left) - float(right)) < 0.0000000001
	return typeof(left) == typeof(right) and left == right


## 首个不同字段连同完整精度数值进入失败消息，避免浮点或结构根因被笼统比较掩盖。
func _difference(left: Variant, right: Variant, path: String = "students") -> String:
	if _same(left, right):
		return ""
	if left is Dictionary and right is Dictionary:
		if left.size() != right.size():
			return "%s字段数%s/%s" % [path, left.size(), right.size()]
		for key: Variant in left:
			if not right.has(key):
				return "%s缺少字段%s" % [path, key]
			if not _same(left[key], right[key]):
				return _difference(left[key], right[key], "%s.%s" % [path, key])
	if left is Array and right is Array:
		if left.size() != right.size():
			return "%s长度%s/%s" % [path, left.size(), right.size()]
		for index in left.size():
			if not _same(left[index], right[index]):
				return _difference(left[index], right[index], "%s[%s]" % [path, index])
	return "%s实际%s，预期%s" % [path, JSON.stringify(left, "", true, true), JSON.stringify(right, "", true, true)]


## 变体只调整独占副本，随动作智力状态用于验证冻结先于活体清理的来源约定。
func _variant_config(filename: String, coefficient: float, exam_max: float, intelligence_delta: float) -> GameConfig:
	var source: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://config/game_config.json"))
	for row: Dictionary in source.tables.globals:
		if row.key == "exam_intelligence_coefficient":
			row.value = coefficient
	for row: Dictionary in source.tables.subjects:
		if row.id in ["chinese", "math", "english"]:
			row.max_score = exam_max
	for row: Dictionary in source.tables.buffs:
		if row.id == "sprinting":
			row.intelligence_delta = intelligence_delta
	if not _write_json(filename, source):
		return null
	var loaded := GameConfig.new()
	if not _result(loaded.load_file(_path(filename)), "冻结来源配置副本经过生产校验", loaded.error_message):
		return null
	return loaded


## 真实v4快照降为旧格式时只剔除当时没有的字段，不制造过去动作或默认物品。
func _legacy(source: Dictionary, version: int) -> Dictionary:
	var result: Dictionary = source.duplicate(true)
	result.save_version = version
	result.erase("round_progression")
	if version < 3:
		for student: Dictionary in result.students:
			student.erase("daily_item_claim_days")
	if version == 1:
		for key: String in ["interactions", "notes", "violations", "next_interaction_number", "next_violation_number"]:
			result.erase(key)
	return result


## 损坏副本与标签并行记录，保证每种预期拒绝都能指向确切问题。
func _add_case(cases: Array[Dictionary], labels: Array[String], snapshot: Dictionary, label: String) -> void:
	cases.append(snapshot)
	labels.append(label)


## 生产保存器写真实文件并立即解析，文件失败不沿用先前缓存。
func _snapshot(simulation: ClassroomSimulation, filename: String) -> Dictionary:
	var path: String = _path(filename)
	_track(path)
	_track(path + ".tmp")
	if not _result(simulation.save_file(path), "生产保存独占验证局", simulation.error_message):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not _check(parsed is Dictionary, "实际保存内容可解析"):
		return {}
	return parsed


## 所有旧档和坏档只写进本进程缓存，读写失败明确停止当前场景。
func _write_json(filename: String, data: Dictionary) -> bool:
	var path: String = _path(filename)
	_track(path)
	var output := FileAccess.open(path, FileAccess.WRITE)
	if not _check(output != null, "独占文件可写：" + filename):
		return false
	output.store_string(JSON.stringify(data, "", true, true))
	var result: Error = output.get_error()
	output.close()
	return _result(result, "独占文件完整落盘：" + filename)


## 文件路径仅由独占根目录与测试内固定名称组成。
func _path(filename: String) -> String:
	return fixture_root.path_join(filename)


## 重复覆盖同一夹具只登记一次，清理不扩大到其他路径。
func _track(path: String) -> void:
	if path not in fixture_files:
		fixture_files.append(path)


## 生产错误保持原始原因，并让依赖该结果的测试场景立即返回。
func _result(result: Error, message: String, detail: String = "") -> bool:
	return _check(result == OK, "%s：错误码%d %s" % [message, result, detail])


## 时间、知识与资源比较保留小容差，不改被测数据。
func _close(actual: float, expected: float, message: String) -> void:
	_check(absf(actual - expected) < 0.000001, "%s：实际%s，预期%s" % [message, actual, expected])


## 每个实际断言均计数，失败不被默认成功或后续覆盖吞掉。
func _check(condition: bool, message: String) -> bool:
	checks += 1
	if not condition:
		failures.append(message)
	return condition


## 释放真实树；成功只删除登记文件，失败保留独占证据并以非零结束。
func _finish() -> void:
	for controller in owned_controllers:
		controller.free()
	if failures.is_empty():
		for path: String in fixture_files:
			if FileAccess.file_exists(path):
				_result(DirAccess.remove_absolute(path), "清理本次持久化验证文件")
		if not fixture_root.is_empty():
			_result(DirAccess.remove_absolute(fixture_root), "清理本次持久化独占目录")
	if failures.is_empty():
		print("ROUND_PERSISTENCE_TEST_PASS checks=%d" % checks)
		quit(0)
	else:
		for message: String in failures:
			push_error(message)
		print("ROUND_PERSISTENCE_TEST_FAIL checks=%d failures=%d fixtures=%s" % [checks, failures.size(), fixture_root])
		quit(1)
