extends "res://tests/test_ai_integration.gd"
## 概率专项独立核对保底、并列弱科、查询无副作用和属性驱动的实际抽样。


## 复用独占夹具与生产入口，任何用例中断均记失败，不用空循环代表覆盖。
func _run() -> void:
	fixture_root = OS.get_cache_dir().path_join("ClassroomAiProbability_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	if not _result(DirAccess.make_dir_recursive_absolute(fixture_root), "创建概率验收独占目录"):
		_finish("AI_UPGRADE")
		return
	_check(_test_builds_and_queries(), "权威初始点与候选查询完整执行")
	_check(_test_configuration_boundary(), "非法AI参数与自主池在边界明确拒绝")
	_check(_test_floor_distribution(), "极端权重归一后仍满足保底")
	_check(_test_weak_subject_distribution(), "真实知识、并列公平和一次随机选科完整执行")
	_check(_test_weak_subject_precision(), "实际积分机器误差并列与真实微小知识差完整区分")
	_check(_test_npc_preset_reload(), "占位预设只影响新局，热改与跨配置读档保留已有属性")
	_check(_test_competitive_weights(), "实际学习领先目标和属性发起概率完整执行")
	_finish("AI_UPGRADE")


## 占位角色只消耗自己的初始点；枚举候选不能影响真实后续随机流。
func _test_builds_and_queries() -> bool:
	var simulation := _at(12345, 1, 28800.0, "res://config/game_config.json", "res://config/phase_scope.json", false)
	if simulation == null:
		return false
	_check(simulation.students[0].unspent_points == 8, "本人保留初始八点")
	for index: int in range(1, 4):
		var row: Dictionary = simulation.config.indexes.npc_attributes[simulation.students[index].id]
		_check(simulation.students[index].unspent_points == 0, "占位预设消耗本人初始点")
		for attribute: String in ClassroomSimulation.ATTRIBUTE_KEYS:
			_close(simulation.students[index].attributes[attribute], row[attribute], "占位属性来自权威表")
	var state: Dictionary = _state(simulation)
	var candidates: Array[Dictionary] = simulation.get_social_candidates(0)
	_check(not candidates.is_empty(), "真实08:00课堂产生非空社交候选")
	_check(candidates.any(func(row: Dictionary) -> bool: return row.action_id == "swap_book"), "候选实际覆盖偷换课本")
	for attempt in 8:
		_check(simulation.get_social_candidates(0) == candidates, "重复查询候选稳定")
		simulation.get_auto_candidates(0)
		simulation.get_dorm_candidates(0)
	_check(_same(state, _state(simulation)), "全部查询不改变知识、资源、历史或随机流")
	var classroom_ids: Array = simulation.get_auto_candidates(0).map(func(row: Dictionary) -> String: return row.action_id)
	_check(classroom_ids.size() == 3 and "daydream" in classroom_ids and "read_comic" in classroom_ids and "bathroom" in classroom_ids, "正式文化课候选恰为发呆漫画厕所")
	_release(simulation)
	return true


## 与导出器分别验证运行时入口，坏配置不能静默落回旧参数或脚本异常。
func _test_configuration_boundary() -> bool:
	var invalid: Array[Array] = [
		["personality_ref_attr", 0.0], ["dorm_weight_floor", -0.1], ["dorm_weight_floor", 0.2],
		["social_auto_base", -0.1], ["social_auto_base", 1.0], ["k_threshold", -0.1], ["k_threshold", 1.1],
		["g_study", -1.0], ["g_game", -1.0], ["g_workout", -1.0], ["g_playful", -1.0], ["g_weak", -1.0], ["g_lead", -1.0],
	]
	for index in invalid.size():
		var entry: Array = invalid[index]
		var path: String = _config("invalid_parameter_%d.json" % index, {entry[0]: entry[1]})
		var configuration := GameConfig.new()
		_check(configuration.load_file(path) != OK and not configuration.error_message.is_empty(), "非法参数明确拒绝：" + entry[0])
	var configuration := GameConfig.new()
	if not _result(configuration.load_file(), "合法正式配置", configuration.error_message):
		return false
	for value: Variant in ["not_an_array", ["borrow_notes", "borrow_notes"], ["send_note"], ["missing"]]:
		var scope: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://config/phase_scope.json"))
		scope.social_auto_actions = value
		var path: String = _path("invalid_scope_%d.json" % fixture_files.size())
		if not _write_json(path, scope):
			return false
		var rejected := ClassroomSimulation.new()
		_check(rejected.setup(configuration, 9811, path) != OK and not rejected.error_message.is_empty(), "竞争池类型重复或未批准动作明确拒绝")
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://config/game_config.json"))
	data.tables.npc_attributes[0].attention = 99.0
	var bad_path: String = _path("invalid_npc.json")
	if not _write_json(bad_path, data):
		return false
	var rejected_config := GameConfig.new()
	_check(rejected_config.load_file(bad_path) != OK and not rejected_config.error_message.is_empty(), "占位源表不能凭空赠送属性点")
	return true


## 独立检验数学不变量，小项不能在最终归一时再次跌破保底。
func _test_floor_distribution() -> bool:
	var simulation := _empty()
	if simulation == null:
		return false
	var cases: Array[Array] = [[1000.0, 1.0, 1.0, 1.0, 1.0, 1.0], [1.0, 0.000001, 0.000001], [6.0, 5.0, 4.0, 3.0, 2.0, 1.0]]
	for raw: Array in cases:
		var weights: Array[float] = []
		weights.assign(raw)
		for floor_probability: float in [0.0, 0.05, 1.0 / 6.0]:
			var probabilities: Array[float] = simulation._weighted_with_floor(weights, floor_probability)
			var total: float = 0.0
			for probability: float in probabilities:
				total += probability
			_close(total, 1.0, "保底后概率总和为一")
			for index: int in probabilities.size():
				_check(probabilities[index] / total >= floor_probability - 1e-15, "归一后每项仍满足下限")
				_check(is_finite(probabilities[index]), "概率保持有限")
	var extreme: Array[float] = [1000.0, 1.0, 1.0, 1.0, 1.0, 1.0]
	var adjusted: Array[float] = simulation._weighted_with_floor(extreme, 0.05)
	_close(adjusted[0], 0.75, "五个小项各占百分之五后大项保留百分之七十五")
	_release(simulation)
	return true


## 先用真实自习建立强科，观察并列弱科的实际分布，不直接填知识。
func _test_weak_subject_distribution() -> bool:
	var simulation := _at(31519, 1, 61200.0, "res://config/game_config.json", "res://config/phase_scope.json", false)
	if simulation == null:
		return false
	_check(simulation.weak_subjects(0) == ["chinese", "math", "english"], "初始三科全部并列")
	var expected_rng := RandomNumberGenerator.new()
	expected_rng.seed = simulation.rng.seed
	expected_rng.state = simulation.rng.state
	expected_rng.randi()
	simulation.select_cultural_subject(0)
	_check(str(simulation.rng.state) == str(expected_rng.state), "一次选科只消耗一次共享随机数")
	var counts: Dictionary = {"chinese": 0, "math": 0, "english": 0}
	for sample in 9000:
		counts[simulation.select_cultural_subject(0)] += 1
	for subject: String in counts:
		_check(absf(float(counts[subject]) / 9000.0 - 1.0 / 3.0) < 0.025, "全零并列科目无固定偏置：" + subject)
	if not _result(simulation.start_action(0, "dorm_study", false, -1, "真实知识弱科验收", "chinese"), "真实选择语文自习", simulation.error_message) or not _result(simulation.advance(1200.0), "真实执行完整自习", simulation.error_message):
		return false
	_check(simulation.students[0].knowledge.chinese > 0.0 and simulation.weak_subjects(0) == ["math", "english"], "实际知识最少的数学英语同时为弱科")
	counts = {"chinese": 0, "math": 0, "english": 0}
	for sample in 10000:
		counts[simulation.select_cultural_subject(0)] += 1
	for subject: String in counts:
		var expected: float = 0.2 if subject == "chinese" else 0.4
		_check(absf(float(counts[subject]) / 10000.0 - expected) < 0.025, "并列弱科得到相同倾向：" + subject)
	_release(simulation)
	return true


## 三秒整段与一秒加两秒真实积分产生末位差，不能将其误当成偏科。
func _test_weak_subject_precision() -> bool:
	var simulation := _at(31520, 1, 61200.0, "res://config/game_config.json", "res://config/phase_scope.json", false)
	if simulation == null:
		return false
	for subject: String in ["chinese", "english"]:
		if not _result(simulation.start_action(0, "dorm_study", false, -1, "机器精度并列验收", subject), "真实选择三秒自习：" + subject, simulation.error_message) or not _result(simulation.advance(3.0), "实际积累三秒知识：" + subject, simulation.error_message):
			return false
	if not _result(simulation.start_action(0, "dorm_study", false, -1, "分段机器精度验收", "math"), "真实开始数学自习", simulation.error_message):
		return false
	for seconds: float in [1.0, 2.0]:
		if not _result(simulation.advance(seconds), "分段实际积累相同三秒数学知识", simulation.error_message):
			return false
	var chinese: float = simulation.students[0].knowledge.chinese
	var math: float = simulation.students[0].knowledge.math
	var rounding_difference: float = absf(chinese - math)
	if not _check(chinese > 0.0 and math > 0.0 and rounding_difference > 0.0 and rounding_difference < 1e-15, "真实同量积分确实产生非零机器末位差"):
		return false
	var rng_before: String = str(simulation.rng.state)
	_check(simulation.weak_subjects(0) == ["chinese", "math", "english"], "三科同量学习的末位机器差仍按并列处理")
	_check(str(simulation.rng.state) == rng_before, "机器精度并列查询不消耗随机数")
	# 这一额外时长真实产生约1e-12知识，远小于显示精度，但大于机器舍入误差。
	if not _result(simulation.advance(3e-10), "真实继续极短数学学习", simulation.error_message):
		return false
	var actual_gain: float = simulation.students[0].knowledge.math - math
	_check(actual_gain > 1e-13 and actual_gain < 1e-10, "极短学习实际产生可表示的微小正知识")
	_check(simulation.students[0].knowledge.math > chinese, "新增知识确实使数学高于另外两科")
	_check(simulation.weak_subjects(0) == ["chinese", "english"], "真实微小知识差仍区分强弱，不按界面精度合并")
	_release(simulation)
	return true


## 修改独占配置的合法八点预设，新局采用新值，已有局仍以真实养成和存档为准。
func _test_npc_preset_reload() -> bool:
	var simulation := _at(31521, 1, 61200.0, "res://config/game_config.json", "res://config/phase_scope.json", false)
	if simulation == null:
		return false
	if not _result(simulation.allocate_attribute("attention", 3), "真实分配本人三点专注", simulation.error_message) or not _result(simulation.allocate_attribute("discipline", 5), "真实分配本人五点自律", simulation.error_message) or not _result(simulation.advance(17.0), "真实推进在途宿舍活动十七秒", simulation.error_message):
		return false
	var before: Array[Dictionary] = simulation.students.duplicate(true)
	var old_save: String = _path("before_npc_preset_reload.json")
	if not _result(simulation.save_file(old_save), "生产保存原预设下的真实进度", simulation.error_message):
		return false
	fixture_files.append(old_save)
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://config/game_config.json"))
	for row: Dictionary in data.tables.npc_attributes:
		for attribute: String in ClassroomSimulation.ATTRIBUTE_KEYS:
			row[attribute] = 8 if attribute == "attention" else 0
	var changed_path: String = _path("changed_npc_presets.json")
	if not _write_json(changed_path, data):
		return false
	var changed := GameConfig.new()
	if not _result(changed.load_file(changed_path), "新占位预设仍恰好消耗八点", changed.error_message):
		return false
	for index: int in range(1, 4):
		_check(changed.indexes.npc_attributes[before[index].id].attention != before[index].attributes.attention, "夹具中的占位预设确实发生改变")
	var rng_before: String = str(simulation.rng.state)
	if not _result(simulation.apply_config(changed), "生产入口热改占位预设", simulation.error_message):
		return false
	_check(_same(simulation.students, before), "占位预设热改不重写四人属性、待分配点或在途动作")
	_check(str(simulation.rng.state) == rng_before, "占位预设热改不消耗随机数")
	var restored := _empty(31522, changed_path)
	if restored == null:
		return false
	for index: int in range(1, 4):
		_check(restored.students[index].attributes.attention == 8.0 and restored.students[index].unspent_points == 0, "新局确实采用新配置的八点专注预设")
	if not _result(restored.load_file(old_save, false), "用新配置读取原预设下的真实存档", restored.error_message):
		return false
	for index in 4:
		_check(_same(restored.students[index].attributes, before[index].attributes), "跨配置读档保留角色实际已分配属性")
		_check(restored.students[index].unspent_points == before[index].unspent_points, "跨配置读档不重置或额外发放待分配点")
	_check(_same(restored.students, before) and str(restored.rng.state) == rng_before, "跨配置恢复保留完整真实角色及随机流")
	var new_save: String = _path("after_npc_preset_reload.json")
	if not _result(simulation.save_file(new_save), "热改后再次生产保存原角色进度", simulation.error_message):
		return false
	fixture_files.append(new_save)
	if not _result(restored.load_file(new_save, false), "重新读取热改后的真实进度", restored.error_message):
		return false
	_check(_same(restored.students, before), "热改后保存往返仍不套用新局预设")
	_release(simulation)
	_release(restored)
	return true


## 用真实学习形成领先者，再观察目标分布与已批准的属性发起率。
func _test_competitive_weights() -> bool:
	var path: String = _config("probability_quiet.json", {"social_auto_base": 0.0})
	var simulation := _at(12819, 1, 28800.0, path)
	if simulation == null:
		return false
	for index: int in [0, 2, 3]:
		if not _result(simulation.start_action(index, "rest", false), "其他角色真实休息", simulation.error_message):
			return false
	if not _result(simulation.start_action(1, "study"), "目标真实学习", simulation.error_message) or not _result(simulation.advance(300.0), "目标真实形成领先知识", simulation.error_message):
		return false
	_check(simulation.students[1].knowledge.chinese > 0.0 and simulation.students[2].knowledge.chinese == 0.0, "领先差异来自真实课堂学习")
	var targets: Dictionary = {1: 0, 2: 0, 3: 0}
	for sample in 12000:
		var option: Dictionary = simulation.select_social_action(0)
		if option.is_empty():
			return _check(false, "真实社交候选必须非空")
		targets[int(option.target_index)] += 1
	_check(absf(float(targets[1]) / 12000.0 - 0.5) < 0.025, "相同动作资格下领先目标得到双倍权重")
	_check(absf(float(targets[2] - targets[3])) / 12000.0 < 0.025, "同知识落后目标保持对称")
	var production := GameConfig.new()
	if not _result(production.load_file(), "恢复正式发起概率", production.error_message) or not _result(simulation.apply_config(production), "真实热改发起概率", simulation.error_message):
		return false
	var initiations: Array[int] = [0, 0]
	for sample in 12000:
		for slot in 2:
			if simulation.should_initiate_social(slot):
				initiations[slot] += 1
	_check(initiations[0] > initiations[1], "低自律的自主竞争发起率更高")
	_check(absf(float(initiations[0]) / 12000.0 - 0.12) < 0.015, "无自律正式发起率为百分之十二")
	_check(absf(float(initiations[1]) / 12000.0 - 0.10) < 0.015, "自律四点正式发起率为百分之十")
	_release(simulation)
	return true
