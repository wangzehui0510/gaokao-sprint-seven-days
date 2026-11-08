extends SceneTree
## 用真实配置、共享行为树与权威存档验收每日物品，不模拟领取成功或开放延期玩法。

# 测试文件只进入本进程独占的系统缓存目录，不访问正式玩家存档。
var fixture_root: String = ""
var fixture_files: Array[String] = []
var configuration: GameConfig
var owned_controllers: Array[ClassroomBehaviorController] = []
var checks: int = 0
var failures: Array[String] = []


## 等待场景树建立后再创建真实四人局。
func _initialize() -> void:
	call_deferred("_run")


## 场景必须执行到返回点，运行时错误不能跳过断言并伪装成通过。
func _run() -> void:
	for dependency in ["res://scripts/core/classroom_simulation.gd", "res://scripts/ai/classroom_behavior_controller.gd"]:
		var script: Script = load(dependency)
		if script == null or not script.can_instantiate():
			_check(false, "每日物品依赖无法实例化：" + dependency)
			_finish()
			return
	configuration = GameConfig.new()
	if not _result(configuration.load_file(), "正式配置加载", configuration.error_message):
		_finish()
		return
	fixture_root = OS.get_cache_dir().path_join("ClassroomDailyRewardsTest_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	if not _result(DirAccess.make_dir_recursive_absolute(fixture_root), "创建本次独占测试目录"):
		_finish()
		return
	_check(_test_course_types(), "全部实际课程触发场景完整执行")
	_check(_test_non_courses_and_failures(), "非课程与失败动作场景完整执行")
	_check(_test_sleep_and_distraction(), "先睡觉或发呆后上课场景完整执行")
	_check(_test_same_day_and_rewind(), "同日幂等与回退日期场景完整执行")
	_check(_test_replacement_and_quantities(), "有放回掉落与库存累计场景完整执行")
	_check(_test_without_replacement(), "无放回掉落场景完整执行")
	_check(_test_weight_influence(), "不同正权重真实影响抽取场景完整执行")
	_check(_test_tiny_positive_weight(), "极小正权重仍能完整真实发奖场景完整执行")
	_check(_test_overflow_rejection(), "奖励数量溢出保持整份奖励未提交场景完整执行")
	_check(_test_deterministic_roundtrip(), "随机确定性及当前版本存档场景完整执行")
	_check(_test_hot_reload(), "热改不重领场景完整执行")
	_check(_test_no_offline_rewards(), "关闭跳日不补奖场景完整执行")
	_check(_test_legacy_migration(), "v1和v2迁移场景完整执行")
	_check(_test_legacy_pair_migration(), "v2在途互动迁移场景完整执行")
	_check(_test_snapshot_rejection(), "损坏领取记录与旧版本冒充场景完整执行")
	_finish()


## 只创建新局与真实行为树；不推进时间、不提前启动课程。
func _empty_simulation(game_config: GameConfig = null, seed_value: int = 261107) -> ClassroomSimulation:
	var simulation := ClassroomSimulation.new()
	var loaded: GameConfig = configuration if game_config == null else game_config
	if not _result(simulation.setup(loaded, seed_value), "创建真实四人新局", simulation.error_message):
		return null
	for student in simulation.students:
		if not student.has("daily_item_claim_days") or not student.daily_item_claim_days is Array:
			_check(false, "新局必须显式建立每日领取日数组")
			return null
		_check(student.daily_item_claim_days.is_empty() and student.inventory.is_empty(), "新局角色尚未领取物品")
	var controller := ClassroomBehaviorController.new()
	root.add_child(controller)
	controller.setup(simulation)
	owned_controllers.append(controller)
	simulation.decision_handler = controller.decide
	return simulation


## 开发时钟只定位真实课表，领取必须等生产动作入口成功。
func _start_at(simulation: ClassroomSimulation, test_day: int, seconds: float) -> bool:
	return _result(simulation.set_debug_time(test_day, seconds), "定位真实课程时刻", simulation.error_message) and _result(simulation.advance(0.0), "真实行为树开始当前动作", simulation.error_message)


## 语数英、体育、恢复课及第七天三场考试分别以当天第一次真实课程触发。
func _test_course_types() -> bool:
	var cases: Array[Dictionary] = [
		{"day": 1, "seconds": 28800.0, "subject": "chinese", "action": "study"},
		{"day": 1, "seconds": 32100.0, "subject": "math", "action": "study"},
		{"day": 1, "seconds": 39300.0, "subject": "english", "action": "study"},
		{"day": 1, "seconds": 50400.0, "subject": "physical", "action": "physical_study"},
		{"day": 1, "seconds": 36000.0, "subject": "music", "action": "music_class"},
		{"day": 1, "seconds": 53700.0, "subject": "art", "action": "art_class"},
		{"day": 7, "seconds": 50400.0, "subject": "exam_chinese", "action": "exam"},
		{"day": 7, "seconds": 53700.0, "subject": "exam_math", "action": "exam"},
		{"day": 7, "seconds": 57300.0, "subject": "exam_english", "action": "exam"},
	]
	for scenario in cases:
		var simulation := _empty_simulation()
		if simulation == null or not _start_at(simulation, scenario.day, scenario.seconds):
			return false
		_check(simulation.course_context().subject_id == scenario.subject, "使用真实课表中的%s课程" % scenario.subject)
		_check(_daily_logs(simulation).size() == 4, "四人分别获得一份课程领取记录：" + scenario.subject)
		for index in simulation.students.size():
			_check(simulation.students[index].current_action.action_id == scenario.action, "角色%d实际开始%s" % [index, scenario.action])
			_check(simulation.students[index].daily_item_claim_days == [scenario.day], "角色%d按局内日登记一次领取" % index)
			_check(_inventory_total(simulation.students[index]) == 3, "角色%d真实库存增加三件" % index)
			if not _verify_log(simulation, index, scenario.day, scenario.action, 3):
				return false
	return true


## 课间和恢复动作不发奖；资源不足的课程启动失败时保留旧动作、库存与随机流。
func _test_non_courses_and_failures() -> bool:
	for seconds in [31500.0, 34800.0, 42000.0, 42600.0, 56400.0, 72000.0]:
		var simulation := _empty_simulation()
		if simulation == null or not _start_at(simulation, 1, seconds):
			return false
		_check(_daily_logs(simulation).is_empty() and simulation.students.all(func(student: Dictionary): return student.daily_item_claim_days.is_empty() and student.inventory.is_empty()), "课间操饭休等非课程时段不领取物品：%s" % seconds)
	var mismatched := _empty_simulation()
	if mismatched == null or not _result(mismatched.set_debug_time(1, 28800.0), "课程动作匹配夹具定位语文课", mismatched.error_message):
		return false
	# 即使其他课程动作被既有执行器接受，也必须匹配当前课表默认动作才有领取资格。
	mismatched.start_action(0, "physical_study")
	_check(mismatched.students[0].daily_item_claim_days.is_empty() and mismatched.students[0].inventory.is_empty() and _daily_logs(mismatched).is_empty(), "语文上下文不能用其他课程动作冒领物品")
	var failed := _empty_simulation()
	if failed == null or not _result(failed.set_debug_time(1, 28800.0), "失败动作定位课堂", failed.error_message):
		return false
	failed.students[0].focus = 0.0
	if not _result(failed.start_action(0, "sleep"), "先建立免费真实睡觉动作", failed.error_message):
		return false
	var before: Array = failed.students.duplicate(true)
	var before_rng: int = failed.rng.state
	_check(failed.start_action(0, "study") != OK, "缺少启动专注的课程明确拒绝")
	_check(failed.students == before and failed.rng.state == before_rng and _daily_logs(failed).is_empty(), "课程拒绝不打断旧动作、不抽奖或改变库存")
	failed.students[0].focus = 80.0
	if not _result(failed.start_action(0, "daydream"), "课堂真实发呆仍不是课程开始", failed.error_message):
		return false
	_check(failed.students[0].daily_item_claim_days.is_empty() and failed.students[0].inventory.is_empty(), "课堂上下文本身不会让发呆领取")
	if not _result(failed.start_interaction(0, 1, "send_note", "互动不能替代实际课程"), "课堂开始真实纸条", failed.error_message):
		return false
	_check(failed.students[0].daily_item_claim_days.is_empty() and failed.students[1].daily_item_claim_days.is_empty(), "纸条双方尚未实际开始课程时不领取")
	_check(_daily_logs(failed, 0).is_empty() and _daily_logs(failed, 1).is_empty(), "纸条不生成伪造的课程领取日志")
	return true


## 同一节课先睡觉或发呆的同学要等各自真实进入课程，不能被别人的领取带上。
func _test_sleep_and_distraction() -> bool:
	var simulation := _empty_simulation()
	if simulation == null or not _result(simulation.set_debug_time(1, 28800.0), "低资源夹具定位第一节", simulation.error_message):
		return false
	simulation.students[0].focus = 80.0
	simulation.students[0].stamina = 5.0
	simulation.students[1].focus = 40.0
	simulation.students[2].focus = 50.0
	if not _result(simulation.advance(0.0), "四人按各自资源正常决策", simulation.error_message):
		return false
	_check(simulation.students[0].current_action.action_id == "sleep" and simulation.students[0].daily_item_claim_days.is_empty(), "低体力先睡觉的玩家没有领取")
	_check(simulation.students[1].current_action.action_id == "daydream" and simulation.students[1].daily_item_claim_days.is_empty(), "低专注先发呆的同学没有领取")
	_check(simulation.students[2].focus == 49.0 and simulation.students[2].daily_item_claim_days == [1], "成功支付启动费后专注低于阈值仍属于真实课程领取")
	_check(simulation.students[3].daily_item_claim_days == [1] and _daily_logs(simulation).size() == 2, "只有实际开始课程的两人先领取")
	if not _result(simulation.focus_command(), "玩家从睡觉真实切回课程", simulation.error_message):
		return false
	_check(simulation.students[0].daily_item_claim_days == [1] and _inventory_total(simulation.students[0]) == 3, "玩家首次实际回课后领取当天物品")
	simulation.students[1].focus = 60.0
	if not _result(simulation.start_action(1, "study"), "同学从发呆真实切回课程", simulation.error_message):
		return false
	_check(simulation.students[1].daily_item_claim_days == [1] and _daily_logs(simulation).size() == 4, "各自回课后四人恰有四条领取记录")
	return true


## 同日专注、换课与日期回退都不能重复领取，已领未来日也必须能够合法保存。
func _test_same_day_and_rewind() -> bool:
	var simulation := _empty_simulation()
	if simulation == null or not _start_at(simulation, 1, 28800.0):
		return false
	var inventories: Array = simulation.students.map(func(student: Dictionary): return student.inventory.duplicate(true))
	for repeat in 3:
		if not _result(simulation.focus_command(), "同日重复专注仍正常生效%d" % repeat, simulation.error_message):
			return false
	if not _start_at(simulation, 1, 36000.0):
		return false
	_check(_daily_logs(simulation).size() == 4, "重复专注和同日音乐课不增加领取记录")
	for index in simulation.students.size():
		_check(simulation.students[index].inventory == inventories[index], "同日重复上课保留角色%d原库存" % index)
	if not _start_at(simulation, 2, 28800.0):
		return false
	_check(simulation.students.all(func(student: Dictionary): return student.daily_item_claim_days == [1, 2] and _inventory_total(student) == 6), "第二天各自再领取一次并累积库存")
	if not _start_at(simulation, 1, 28800.0):
		return false
	_check(_daily_logs(simulation).size() == 8, "退回第一天不会重复领取")
	var snapshot: Dictionary = _snapshot(simulation, "rewound_day.json")
	if snapshot.is_empty():
		return false
	var restored := _empty_simulation()
	if restored == null or not _result(restored.load_file(_path("rewound_day.json"), false), "读入回退日期但保留已领第二天的合法v3存档", restored.error_message):
		return false
	_check(restored.students.all(func(student: Dictionary): return student.daily_item_claim_days == [1, 2]), "读档不丢失比当前日期更晚的历史领取日")
	if not _start_at(restored, 2, 28800.0):
		return false
	_check(_daily_logs(restored).size() == 8 and restored.students.all(func(student: Dictionary): return _inventory_total(student) == 6), "重新回到已领第二天仍不重领")
	var reverse := _empty_simulation()
	if reverse == null or not _start_at(reverse, 2, 28800.0) or not _start_at(reverse, 1, 28800.0):
		return false
	_check(reverse.students.all(func(student: Dictionary): return student.daily_item_claim_days == [1, 2] and _inventory_total(student) == 6), "先领第二天再首次领第一天仍保存排序唯一领取日")
	if _snapshot(reverse, "reverse_claim_days.json").is_empty():
		return false
	var reverse_restored := _empty_simulation()
	if reverse_restored == null or not _result(reverse_restored.load_file(_path("reverse_claim_days.json"), false), "读入先后倒序领取后生成的合法v3存档", reverse_restored.error_message):
		return false
	_check(reverse_restored.students.all(func(student: Dictionary): return student.daily_item_claim_days == [1, 2] and _inventory_total(student) == 6), "倒序首次领取产生的排序日和真实库存可完整恢复")
	return true


## 用正式配置副本的单一有效奖项验证有放回、数量字段和跨日累计，不伪造发放结果。
func _test_replacement_and_quantities() -> bool:
	var pool: Array[Dictionary] = [
		_pool_row("repeat_eraser", "eraser", 1.0, 2, true),
		_pool_row("disabled_snack", "snack", 10000.0, 9, false),
		_pool_row("zero_candy", "candy", 0.0, 9, true),
	]
	var replacement := _pool_config(pool, 3, true, "repeat_config.json")
	if replacement == null:
		return false
	var simulation := _empty_simulation(replacement)
	if simulation == null:
		return false
	for student in simulation.students:
		student.inventory = {"eraser": 5, "snack": 2}
	if not _start_at(simulation, 1, 28800.0):
		return false
	for index in simulation.students.size():
		_check(simulation.students[index].inventory == {"eraser": 11, "snack": 2}, "三次重复抽取按每次两件累加角色%d库存" % index)
		if not _verify_log(simulation, index, 1, "study", 3):
			return false
		var entry: Dictionary = _daily_logs(simulation, index)[0]
		_check(entry.details.draws.all(func(draw: Dictionary): return draw.pool_id == "repeat_eraser" and draw.quantity == 2), "禁用和零权重奖项不参与角色%d抽取" % index)
	if not _start_at(simulation, 2, 28800.0):
		return false
	_check(simulation.students.all(func(student: Dictionary): return student.inventory == {"eraser": 17, "snack": 2} and student.daily_item_claim_days == [1, 2]), "物品跨日保留并叠加新一天六件")
	for index in simulation.students.size():
		if not _verify_log(simulation, index, 1, "study", 3):
			return false
		_check(_daily_logs(simulation, index)[0].details.items == {"eraser": 6}, "角色%d后续库存增加不会改写第一天真实发放日志" % index)
	return true


## 无放回按有效奖池项移除候选，抽满三项时每项真实数量均进入库存。
func _test_without_replacement() -> bool:
	var pool: Array[Dictionary] = [
		_pool_row("once_eraser", "eraser", 100.0, 2, true),
		_pool_row("once_snack", "snack", 3.0, 3, true),
		_pool_row("once_candy", "candy", 1.0, 4, true),
		_pool_row("disabled_comic", "comic", 10000.0, 9, false),
		_pool_row("zero_cover", "book_cover", 0.0, 9, true),
	]
	var replacement := _pool_config(pool, 3, false, "without_replacement_config.json")
	if replacement == null:
		return false
	var simulation := _empty_simulation(replacement)
	if simulation == null or not _start_at(simulation, 1, 28800.0):
		return false
	for index in simulation.students.size():
		_check(simulation.students[index].inventory == {"eraser": 2, "snack": 3, "candy": 4}, "角色%d无放回抽满三个有效奖项" % index)
		if not _verify_log(simulation, index, 1, "study", 3):
			return false
		var selected: Dictionary = {}
		for draw in _daily_logs(simulation, index)[0].details.draws:
			selected[draw.pool_id] = true
		_check(selected.size() == 3, "角色%d无放回日志不重复奖池项" % index)
	return true


## 固定种子与两种行顺序验证九倍权重的实际倾向，同时排除均匀抽或固定选项。
func _test_weight_influence() -> bool:
	for with_replacement in [true, false]:
		for reverse_order in [false, true]:
			var pool: Array[Dictionary] = [
				_pool_row("rare_eraser", "eraser", 1.0, 1, true),
				_pool_row("common_snack", "snack", 9.0, 1, true),
			]
			if reverse_order:
				pool.reverse()
			var filename: String = "weighted_%s_%s_config.json" % [with_replacement, reverse_order]
			var weighted := _pool_config(pool, 1, with_replacement, filename)
			if weighted == null:
				return false
			var common_count: int = 0
			var rare_count: int = 0
			# 跨固定种子的真实结果只检验宽松比例，不复刻生产随机算法或规定逐次结果。
			for seed_offset in 128:
				var simulation := _empty_simulation(weighted, 261200 + seed_offset)
				if simulation == null or not _start_at(simulation, 1, 28800.0):
					return false
				for index in simulation.students.size():
					if not _verify_log(simulation, index, 1, "study", 1):
						return false
					_check(_inventory_total(simulation.students[index]) == 1, "权重专项角色%d确实领取一件" % index)
					common_count += int(simulation.students[index].inventory.get("snack", 0))
					rare_count += int(simulation.students[index].inventory.get("eraser", 0))
				# 本次独立抽样不再继续执行，及时释放四人的真实行为树而不累积整批节点。
				var finished_controller: ClassroomBehaviorController = owned_controllers.pop_back()
				finished_controller.free()
			_check(rare_count > 0 and common_count > rare_count * 4, "有放回=%s 反向行=%s的九倍权重真实生效：高权重%d、低权重%d" % [with_replacement, reverse_order, common_count, rare_count])
	return true


## 使用独占配置中可被JSON入口保留的极小有限正数，通过生产配置与真实课程发奖。
func _test_tiny_positive_weight() -> bool:
	var source: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://config/game_config.json"))
	var pool: Array[Dictionary] = [_pool_row("tiny_eraser", "eraser", 1.0, 2, true)]
	# 引擎JSON入口无法保留5e-324和1e-320的有效正权重；本例固定使用1e-300，不冒充次正规数验收。
	# 权重以显式科学计数法写入，避免stringify先把极小数值写成零。
	pool[0].weight = "__DAILY_TINY_WEIGHT__"
	source.tables.drop_pool = pool
	for row in source.tables.globals:
		if row.key == "daily_item_draw_count":
			row.value = 3
		elif row.key == "daily_item_with_replacement":
			row.value = true
	var serialized: String = JSON.stringify(source, "\t")
	var marker: String = "\"__DAILY_TINY_WEIGHT__\""
	if not _check(serialized.count(marker) == 1, "极小权重副本只含一个明确的数值占位符"):
		return false
	serialized = serialized.replace(marker, "1e-300")
	var path: String = _path("tiny_weight_config.json")
	_track_file(path)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not _check(file != null, "写入保留1e-300科学计数法的独占配置"):
		return false
	file.store_string(serialized)
	file.close()
	var tiny_config := GameConfig.new()
	if not _result(tiny_config.load_file(path), "1e-300单项奖池通过完整生产配置入口", tiny_config.error_message):
		return false
	_check(tiny_config.indexes.drop_pool.tiny_eraser.weight > 0.0 and tiny_config.indexes.drop_pool.tiny_eraser.weight <= 1e-300, "生产入口实际保留极小正权重而非零或普通权重")
	var simulation := _empty_simulation(tiny_config, 261314)
	if simulation == null or not _start_at(simulation, 1, 28800.0):
		return false
	_check(_daily_logs(simulation).size() == 4, "极小正权重奖池为四名实际上课者完整发奖")
	for index in simulation.students.size():
		_check(simulation.students[index].inventory == {"eraser": 6} and simulation.students[index].daily_item_claim_days == [1], "极小正权重仍让角色%d获得三次两件实物并登记领取" % index)
		if not _verify_log(simulation, index, 1, "study", 3):
			return false
	return true


## 合法单项数量相加或入库溢出时明确失败，课程已付启动费但整份奖励保持未提交。
func _test_overflow_rejection() -> bool:
	var huge_pool: Array[Dictionary] = [_pool_row("huge_eraser", "eraser", 1.0, 4000000000000000000, true)]
	var huge_config := _pool_config(huge_pool, 3, true, "overflow_sum_config.json")
	if huge_config == null:
		return false
	var huge := _empty_simulation(huge_config, 261311)
	if huge == null or not _result(huge.set_debug_time(1, 28800.0), "汇总溢出定位真实语文课", huge.error_message):
		return false
	huge.students[0].inventory = {"snack": 2}
	var huge_before: Array = huge.students.map(func(student: Dictionary): return student.inventory.duplicate(true))
	var huge_action_rng := _rng_after_study_duration(huge)
	_check(huge.start_action(0, "study") != OK and huge.error_message.contains("抽取总量"), "三次合法四百亿亿件汇总溢出明确拒绝奖励")
	_check(huge.students[0].current_action.action_id == "study" and huge.students[0].focus == 99.0, "汇总溢出发生在真实课程已启动并支付费用之后")
	_check(huge.rng.state == huge_action_rng.state, "汇总溢出仅保留课程时长随机消耗，不提交抽奖随机流")
	_check(_daily_logs(huge).is_empty() and huge.students.all(func(student: Dictionary): return student.daily_item_claim_days.is_empty()), "汇总溢出不写领取日或发奖日志")
	for index in huge.students.size():
		_check(huge.students[index].inventory == huge_before[index], "汇总溢出保留角色%d原库存" % index)
	var pair_pool: Array[Dictionary] = [
		_pool_row("atomic_eraser", "eraser", 1.0, 2, true),
		_pool_row("atomic_snack", "snack", 1.0, 3, true),
	]
	var pair_config := _pool_config(pair_pool, 2, false, "overflow_inventory_config.json")
	if pair_config == null:
		return false
	# 同种子正常局提供真实抽取顺序，保证溢出发生在第二项而不是跳过部分入库的风险。
	var baseline := _empty_simulation(pair_config, 261312)
	if baseline == null or not _result(baseline.set_debug_time(1, 28800.0), "入库溢出对照局定位语文课", baseline.error_message) or not _result(baseline.start_action(0, "study"), "正常对照局通过真实入口抽取两项", baseline.error_message):
		return false
	if not _verify_log(baseline, 0, 1, "study", 2):
		return false
	var actual_draws: Array = _daily_logs(baseline, 0)[0].details.draws
	var safe_item: String = actual_draws[0].item_id
	var overflow_item: String = actual_draws[1].item_id
	if not _check(safe_item != overflow_item, "无放回对照局真实抽出两个不同物品"):
		return false
	var overflowing := _empty_simulation(pair_config, 261312)
	if overflowing == null or not _result(overflowing.set_debug_time(1, 28800.0), "入库溢出定位同一真实语文课", overflowing.error_message):
		return false
	var inventory: Dictionary = {}
	inventory[safe_item] = 7
	inventory[overflow_item] = 9223372036854775806
	overflowing.students[0].inventory = inventory.duplicate(true)
	var inventories_before: Array = overflowing.students.map(func(student: Dictionary): return student.inventory.duplicate(true))
	var inventory_action_rng := _rng_after_study_duration(overflowing)
	_check(overflowing.start_action(0, "study") != OK and overflowing.error_message.contains("入库"), "第二项接近整数上界的现有库存明确拒绝入库")
	_check(overflowing.students[0].current_action.action_id == "study" and overflowing.students[0].focus == 99.0, "入库溢出保留已经真实开始的课程与启动费用")
	_check(overflowing.rng.state == inventory_action_rng.state, "第二项入库溢出不提交任何抽奖随机消耗")
	_check(_daily_logs(overflowing).is_empty() and overflowing.students.all(func(student: Dictionary): return student.daily_item_claim_days.is_empty()), "第二项入库溢出不写领取日或成功发奖日志")
	for index in overflowing.students.size():
		_check(overflowing.students[index].inventory == inventories_before[index], "第二项溢出时角色%d第一项也不能部分入库" % index)
	return true


## 只预计算课程入口必然发生的一次时长抽取，奖励失败应保留这一动作随机结果。
func _rng_after_study_duration(simulation: ClassroomSimulation) -> RandomNumberGenerator:
	var action_rng := RandomNumberGenerator.new()
	action_rng.seed = simulation.rng.seed
	action_rng.state = simulation.rng.state
	action_rng.randf_range(simulation.config.actions.study.duration_min_s, simulation.config.actions.study.duration_max_s)
	return action_rng


## 相同随机种子给出相同真实抽奖；保存恢复后只在下一实际领取日继续同一随机流。
func _test_deterministic_roundtrip() -> bool:
	var first := _empty_simulation(configuration, 6174)
	var second := _empty_simulation(configuration, 6174)
	if first == null or second == null or not _start_at(first, 1, 28800.0) or not _start_at(second, 1, 28800.0):
		return false
	_check(_daily_logs(first) == _daily_logs(second) and first.rng.state == second.rng.state, "同一随机种子的课程与抽取结果可重现")
	var random_before: int = first.rng.state
	for index in first.students.size():
		first.can_start_action(index, "study")
		first.get_auto_candidates(index)
	first.course_context()
	_check(first.rng.state == random_before, "资格查询和课表读取不会消耗抽奖随机流")
	var snapshot: Dictionary = _snapshot(first, "deterministic_v3.json")
	if snapshot.is_empty():
		return false
	_check(snapshot.save_version == ClassroomSimulation.SAVE_VERSION and snapshot.students.all(func(student: Dictionary): return _same_numeric_days(student.daily_item_claim_days, [1])), "当前版本显式持久化四人领取记录")
	var restored := _empty_simulation(configuration, 999)
	if restored == null or not _result(restored.load_file(_path("deterministic_v3.json"), false), "恢复v3原领取记录和随机流", restored.error_message):
		return false
	_check(restored.rng.state == first.rng.state and _daily_logs(restored).size() == 4, "v3读档不重新抽奖或增加领取日志")
	for index in restored.students.size():
		_check(_same_inventory(restored.students[index].inventory, first.students[index].inventory) and restored.students[index].daily_item_claim_days == [1], "v3恢复角色%d实际库存与领取日" % index)
	if not _start_at(first, 3, 28800.0) or not _start_at(restored, 3, 28800.0):
		return false
	_check(first.rng.state == restored.rng.state, "读档和连续执行在下一领取日保持相同随机状态")
	for index in first.students.size():
		_check(_same_inventory(first.students[index].inventory, restored.students[index].inventory) and restored.students[index].daily_item_claim_days == [1, 3], "角色%d跳过第二天后只领取第三天且结果一致" % index)
		_check(_daily_logs(first, index)[1].details.draws == _daily_logs(restored, index)[1].details.draws, "角色%d保存后继续抽取与未关闭局完全一致" % index)
		_close(first.students[index].current_action.duration_s, restored.students[index].current_action.duration_s, "角色%d恢复不改变后续动作随机时长" % index)
	return true


## 热改奖池不补发当天奖励，新奖池只用于下一次符合条件的日领取。
func _test_hot_reload() -> bool:
	var simulation := _empty_simulation()
	if simulation == null or not _start_at(simulation, 1, 28800.0):
		return false
	var before: Array = simulation.students.duplicate(true)
	var before_rng: int = simulation.rng.state
	var replacement := _pool_config([_pool_row("reload_candy", "candy", 1.0, 3, true)], 5, true, "reload_config.json")
	if replacement == null or not _result(simulation.apply_config(replacement), "应用真实新奖池配置", simulation.error_message):
		return false
	_check(simulation.students == before and simulation.rng.state == before_rng and _daily_logs(simulation).size() == 4, "奖池热改保留在途动作、库存、领取记录和随机流")
	if not _result(simulation.advance(0.0), "热改后零秒刷新", simulation.error_message):
		return false
	_check(_daily_logs(simulation).size() == 4, "热改刷新不补领当天物品")
	if not _start_at(simulation, 2, 28800.0):
		return false
	for index in simulation.students.size():
		_check(simulation.students[index].inventory.get("candy", 0) == before[index].inventory.get("candy", 0) + 15, "角色%d下一天使用新奖池五次每次三件" % index)
		if not _verify_log(simulation, index, 2, "study", 5):
			return false
	return true


## 保存关闭期间错过的日子不发奖，恢复本身不触发，下一次实际课程只领当前日。
func _test_no_offline_rewards() -> bool:
	var source := _empty_simulation()
	if source == null or not _start_at(source, 1, 72000.0):
		return false
	var created_midnight: int = int(Time.get_unix_time_from_datetime_string(source.created_date + "T00:00:00"))
	source.created_date = Time.get_date_string_from_unix_time(created_midnight - 3 * 86400)
	var snapshot: Dictionary = _snapshot(source, "offline_jump.json")
	if snapshot.is_empty():
		return false
	var restored := _empty_simulation()
	if restored == null or not _result(restored.load_file(_path("offline_jump.json"), true), "关闭三天后按电脑日期恢复", restored.error_message):
		return false
	_check(restored.day == 4 and restored.elapsed_s == source.elapsed_s, "跨日读档只对齐局内日、不推进在线执行秒数")
	_check(restored.rng.state == source.rng.state and _daily_logs(restored).is_empty(), "恢复本身不抽奖或记录离线领取")
	_check(restored.students.all(func(student: Dictionary): return student.daily_item_claim_days.is_empty() and student.inventory.is_empty()), "错过的三天没有补发库存或伪造领取日")
	if not _start_at(restored, 4, 28800.0):
		return false
	_check(restored.students.all(func(student: Dictionary): return student.daily_item_claim_days == [4] and _inventory_total(student) == 3), "当前第四天实际回课后只领取第四天物品")
	return true


## 旧档没有领取字段；迁移保留原动作，零秒推进不补奖，下一次成功开始课程才领取。
func _test_legacy_migration() -> bool:
	var source := _empty_simulation()
	if source == null or not _start_at(source, 1, 28800.0) or not _result(source.advance(12.0), "旧版夹具真实执行十二秒课程", source.error_message):
		return false
	var snapshot: Dictionary = _snapshot(source, "legacy_source.json")
	if snapshot.is_empty():
		return false
	for version in [1, 2]:
		var legacy: Dictionary = _legacy_snapshot(snapshot, version)
		var filename: String = "legacy_v%d.json" % version
		if not _write_json(filename, legacy):
			return false
		var restored := _empty_simulation()
		if restored == null or not _result(restored.load_file(_path(filename), false), "明确迁移真实v%d字段集合" % version, restored.error_message):
			return false
		_check(restored.rng.state == source.rng.state and restored.elapsed_s == source.elapsed_s, "v%d迁移保留原随机流和在线时长" % version)
		_check(restored.students.all(func(student: Dictionary): return student.daily_item_claim_days.is_empty() and student.inventory.is_empty()), "v%d迁移显式建立空领取日且不补物品" % version)
		for index in restored.students.size():
			_check(restored.students[index].current_action.instance_id == source.students[index].current_action.instance_id, "v%d保留角色%d原在途动作身份" % [version, index])
			_close(restored.students[index].current_action.duration_s, source.students[index].current_action.duration_s, "v%d保留角色%d原抽样时长" % [version, index])
			_close(restored.students[index].focus, source.students[index].focus, "v%d保留角色%d启动费与已发生资源" % [version, index])
		if not _result(restored.advance(0.0), "v%d迁移后零秒推进旧动作" % version, restored.error_message):
			return false
		_check(_daily_logs(restored).is_empty(), "v%d当前动作继续执行不立即补奖" % version)
		if not _result(restored.focus_command(), "v%d下一次专注真实开始新课程" % version, restored.error_message):
			return false
		_check(restored.students[0].daily_item_claim_days == [1] and _daily_logs(restored).size() == 1, "v%d迁移后首次新课程仅实际启动者领取" % version)
		_check(restored.students.slice(1).all(func(student: Dictionary): return student.daily_item_claim_days.is_empty()), "v%d不因玩家回课为其他未重启同学补奖" % version)
		var upgraded: Dictionary = _snapshot(restored, "upgraded_v%d.json" % version)
		if upgraded.is_empty():
			return false
		_check(upgraded.save_version == ClassroomSimulation.SAVE_VERSION and _same_numeric_days(upgraded.students[0].daily_item_claim_days, [1]), "v%d后续保存显式升级为当前版本" % version)
	return true


## v2双人纸条迁移也不提前领取，真实送达后重新回课的参与者才获得当天物品。
func _test_legacy_pair_migration() -> bool:
	var source := _empty_simulation()
	if source == null or not _start_at(source, 1, 28800.0):
		return false
	if not _result(source.start_interaction(0, 1, "send_note", "旧v2真实在途纸条"), "v2夹具发起真实纸条", source.error_message) or not _result(source.advance(7.0), "旧纸条真实推进七秒", source.error_message):
		return false
	var snapshot: Dictionary = _snapshot(source, "legacy_pair_source.json")
	if snapshot.is_empty() or not _write_json("legacy_pair_v2.json", _legacy_snapshot(snapshot, 2)):
		return false
	var restored := _empty_simulation()
	if restored == null or not _result(restored.load_file(_path("legacy_pair_v2.json"), false), "迁移v2在途双人关联", restored.error_message):
		return false
	_check(_daily_logs(restored).is_empty() and restored.notes.is_empty(), "迁移旧互动不补奖或提前送达")
	_check(restored.students[0].current_action.interaction_id == source.students[0].current_action.interaction_id, "旧双人动作保持原共同身份")
	if not _result(restored.advance(13.0), "旧纸条按原剩余时间真实完成", restored.error_message):
		return false
	_check(restored.notes.size() == 1 and restored.notes[0].text == "旧v2真实在途纸条", "迁移后的旧纸条只实际送达一次")
	_check(restored.students[0].daily_item_claim_days == [1] and restored.students[1].daily_item_claim_days == [1] and _daily_logs(restored).size() == 2, "纸条完成后两位实际回课者分别领取")
	_check(restored.students[2].daily_item_claim_days.is_empty() and restored.students[3].daily_item_claim_days.is_empty(), "其他旧课程未重新开始的同学仍不补奖")
	return true


## 损坏v3与携带新权威字段的旧版本必须在覆盖有效局之前明确拒绝。
func _test_snapshot_rejection() -> bool:
	var target := _empty_simulation()
	if target == null or not _start_at(target, 1, 28800.0):
		return false
	var snapshot: Dictionary = _snapshot(target, "valid_v3.json")
	if snapshot.is_empty():
		return false
	var cases: Array[Dictionary] = []
	var missing: Dictionary = snapshot.duplicate(true)
	missing.students[0].erase("daily_item_claim_days")
	cases.append(missing)
	for invalid_value in [{}, [0], [-1], [1.5], [1, 1], [2, 1], ["1"], [true], [null]]:
		var invalid: Dictionary = snapshot.duplicate(true)
		invalid.students[0].daily_item_claim_days = invalid_value
		cases.append(invalid)
	for version in [1, 2]:
		for claimed_days in [[], [1]]:
			var spoofed: Dictionary = _legacy_snapshot(snapshot, version)
			spoofed.students[0].daily_item_claim_days = claimed_days
			cases.append(spoofed)
	var before: Array = target.students.duplicate(true)
	var before_rng: int = target.rng.state
	var before_logs: int = target.logs.size()
	var before_elapsed: float = target.elapsed_s
	for index in cases.size():
		if not _write_json("invalid_claims.json", cases[index]):
			return false
		_check(target.load_file(_path("invalid_claims.json"), false) != OK and not target.error_message.is_empty(), "损坏或旧版本冒充领取记录明确拒绝：案例%d" % index)
		_check(target.students == before and target.rng.state == before_rng and target.logs.size() == before_logs and target.elapsed_s == before_elapsed, "拒绝案例%d不覆盖有效库存、动作、领取记录或随机流" % index)
	return true


## 读取真实领取日志核对奖池资格、逐次数量和汇总；不从期望结果制造业务记录。
func _verify_log(simulation: ClassroomSimulation, index: int, claim_day: int, action_id: String, draw_count: int) -> bool:
	var entries: Array = _daily_logs(simulation, index).filter(func(entry: Dictionary): return entry.details.claim_day == claim_day)
	if not _check(entries.size() == 1, "角色%d第%d天只有一条领取日志" % [index, claim_day]):
		return false
	var details: Dictionary = entries[0].details
	if not _check(details.has_all(["claim_day", "action_id", "draws", "items"]) and details.draws is Array and details.items is Dictionary, "领取日志保留可复核的触发与逐次结果"):
		return false
	_check(details.action_id == action_id and details.draws.size() == draw_count, "领取日志对应真实课程和配置抽取次数")
	var aggregate: Dictionary = {}
	for draw in details.draws:
		if not _check(draw is Dictionary and draw.has_all(["pool_id", "item_id", "quantity"]) and simulation.config.indexes.drop_pool.has(draw.pool_id), "逐次抽取引用真实奖池项"):
			return false
		var definition: Dictionary = simulation.config.indexes.drop_pool[draw.pool_id]
		_check(definition.enabled and definition.weight > 0.0 and draw.item_id == definition.item_id and draw.quantity == definition.quantity, "日志只包含有效正权重奖项及实际数量")
		aggregate[draw.item_id] = aggregate.get(draw.item_id, 0) + draw.quantity
	_check(details.items == aggregate, "领取日志汇总与逐次抽取完全一致")
	return true


## 按真实角色过滤已发生的领取记录，其他日志不会被当成奖励结果。
func _daily_logs(simulation: ClassroomSimulation, index: int = -1) -> Array:
	return simulation.logs.filter(func(entry: Dictionary): return entry.type == "daily_items" and (index < 0 or entry.student_index == index))


## 背包总数用于核对真实新增件数，不假定具体随机物品。
func _inventory_total(student: Dictionary) -> int:
	var total: int = 0
	for quantity in student.inventory.values():
		total += int(quantity)
	return total


## JSON将数字读成浮点；按每项真实数值比较原始快照，同时拒绝字符串或布尔冒充日期。
func _same_numeric_days(actual: Array, expected: Array) -> bool:
	if actual.size() != expected.size():
		return false
	for index in actual.size():
		if typeof(actual[index]) not in [TYPE_INT, TYPE_FLOAT] or actual[index] != expected[index]:
			return false
	return true


## 存读往返允许JSON数字类型变化，但物品键和每项实际数量必须完全相同。
func _same_inventory(actual: Dictionary, expected: Dictionary) -> bool:
	if actual.size() != expected.size():
		return false
	for item_id in expected:
		if not actual.has(item_id) or typeof(actual[item_id]) not in [TYPE_INT, TYPE_FLOAT] or actual[item_id] != expected[item_id]:
			return false
	return true


## 构造配置副本中的真实奖池行，仍通过生产配置加载和核心抽取执行。
func _pool_row(row_id: String, item_id: String, weight: float, quantity: int, enabled: bool) -> Dictionary:
	return {"id": row_id, "item_id": item_id, "weight": weight, "quantity": quantity, "enabled": enabled, "description": "每日物品专项测试的正式结构配置副本"}


## 只修改独立JSON副本的奖池和抽取参数，不改正式表或阶段开放范围。
func _pool_config(pool: Array[Dictionary], count: int, with_replacement: bool, filename: String) -> GameConfig:
	var source: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://config/game_config.json"))
	source.tables.drop_pool = pool
	for row in source.tables.globals:
		if row.key == "daily_item_draw_count":
			row.value = count
		elif row.key == "daily_item_with_replacement":
			row.value = with_replacement
	if not _write_json(filename, source):
		return null
	var loaded := GameConfig.new()
	if not _result(loaded.load_file(_path(filename)), "奖池副本通过完整真实配置入口", loaded.error_message):
		return null
	return loaded


## 旧格式夹具显式剔除当时不存在的七天结算、领取字段、发奖日志与物品，不伪装新状态为旧档。
func _legacy_snapshot(source: Dictionary, version: int) -> Dictionary:
	var legacy: Dictionary = source.duplicate(true)
	legacy.save_version = version
	legacy.erase("round_progression")
	for student in legacy.students:
		student.erase("daily_item_claim_days")
		student.inventory = {}
	legacy.logs = legacy.logs.filter(func(entry: Dictionary): return entry.type != "daily_items")
	if version == 1:
		for key in ["interactions", "notes", "violations", "next_interaction_number", "next_violation_number"]:
			legacy.erase(key)
	return legacy


## 生产保存器写入独占目录，随后只解析本次写出的文件作为迁移或损坏夹具。
func _snapshot(simulation: ClassroomSimulation, filename: String) -> Dictionary:
	var path: String = _path(filename)
	_track_file(path)
	_track_file(path + ".tmp")
	if not _result(simulation.save_file(path), "保存本次独立真实局", simulation.error_message):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not _check(parsed is Dictionary, "独占测试存档可解析为完整对象"):
		return {}
	return parsed


## 所有自建配置和坏档仅写本次独占目录，失败明确返回而不沿用旧文件。
func _write_json(filename: String, data: Dictionary) -> bool:
	var path: String = _path(filename)
	_track_file(path)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not _check(file != null, "写入独占测试文件：" + filename):
		return false
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	return true


## 文件名均为本测试内固定常量，路径只从唯一缓存根目录派生。
func _path(filename: String) -> String:
	return fixture_root.path_join(filename)


## 清理名单只登记本测试实际准备写入的文件，重复保存不重复删除。
func _track_file(path: String) -> void:
	if path not in fixture_files:
		fixture_files.append(path)


## 生产入口失败保留明确错误，调用方立即停止当前场景。
func _result(result: Error, message: String, detail: String = "") -> bool:
	_check(result == OK, "%s：错误码%d %s" % [message, result, detail])
	return result == OK


## 时间与资源只接受固定容差内的真实数值。
func _close(actual: float, expected: float, message: String) -> void:
	_check(absf(actual - expected) < 0.000001, "%s：实际%s，预期%s" % [message, actual, expected])


## 记录实际断言并返回结果，便于结构错误时停止访问无效数据。
func _check(condition: bool, message: String) -> bool:
	checks += 1
	if not condition:
		failures.append(message)
	return condition


## 释放行为树；成功只删除本进程登记的文件，失败保留缓存证据并非零退出。
func _finish() -> void:
	for controller in owned_controllers:
		controller.free()
	if failures.is_empty():
		for path in fixture_files:
			if FileAccess.file_exists(path):
				_result(DirAccess.remove_absolute(path), "清理本次独占测试文件")
		if not fixture_root.is_empty():
			_result(DirAccess.remove_absolute(fixture_root), "清理本次独占测试目录")
	if failures.is_empty():
		print("DAILY_REWARDS_TEST_PASS checks=%d" % checks)
		quit(0)
	else:
		for message in failures:
			push_error(message)
		print("DAILY_REWARDS_TEST_FAIL checks=%d failures=%d fixtures=%s" % [checks, failures.size(), fixture_root])
		quit(1)
