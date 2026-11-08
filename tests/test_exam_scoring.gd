extends SceneTree
## 无存档的真实计分专项，只读取正式配置并调用生产公式，不启动正式主场景。

const SCORING = preload("res://scripts/core/exam_scoring.gd")
const CONFIG = preload("res://scripts/core/game_config.gd")
# 测试只统计实际断言，所有预期拒绝都必须具有错误码和可见原因。
var checks: int = 0
var failures: Array[String] = []
var configuration: RefCounted
var scoring: RefCounted = SCORING.new()


## 延后运行以保持SceneTree测试入口与其他专项一致。
func _initialize() -> void:
	call_deferred("_run")


## 使用权威JSON参数复核算例、取整求和、同分和显式失败边界。
func _run() -> void:
	configuration = CONFIG.new()
	if not _check(configuration.load_file() == OK, "正式配置可读取：%s" % configuration.error_message):
		_finish()
		return
	_test_design_example()
	_test_zero_and_intelligence()
	_test_negative_formula_result()
	_test_rounding_order_and_ties()
	_test_invalid_snapshots()
	_test_invalid_totals_and_groups()
	_test_historical_independence()
	_test_representation_boundaries()
	_test_signed_total_cancellation()
	_finish()


## 参数仅从真实当前配置制作输入快照，计算器本身没有配置依赖。
func _snapshot(subject_id: String, knowledge: float, intelligence: float) -> Dictionary:
	var subject: Dictionary = configuration.subjects[subject_id]
	return {
		"subject_id": subject_id, "knowledge": knowledge, "effective_intelligence": intelligence,
		"max_score": subject.max_score, "score_scale": subject.score_scale,
		"exam_intelligence_coefficient": configuration.global_value("exam_intelligence_coefficient"),
		"score_decimal_places": configuration.global_value("score_decimal_places"),
	}


## 策划中的理想学习算例必须逐科取整为139.1、46.6并合计463.9。
func _test_design_example() -> void:
	var records: Array[Dictionary] = []
	for subject_id: String in ["chinese", "math", "english", "physical"]:
		var snapshot: Dictionary = _snapshot(subject_id, 356.4 if subject_id == "physical" else 445.5, 2.0)
		var before: Dictionary = snapshot.duplicate(true)
		var result: Dictionary = scoring.calculate_subject(snapshot)
		if not _accepted(result, "策划算例%s可计算" % subject_id):
			continue
		var expected: float = 46.6 if subject_id == "physical" else 139.1
		_close(result.result.score, expected, "策划算例%s四舍五入结果" % subject_id)
		_check(result.result.score_units == int(roundf(expected * 10.0)), "策划算例%s使用整数刻度" % subject_id)
		_check(snapshot == before, "计分不修改%s输入快照" % subject_id)
		records.append(result.result)
	var total: Dictionary = scoring.sum_subjects(records)
	if _accepted(total, "策划算例四科求和"):
		_check(total.result.score_units == 4639, "总分整数刻度精确为4639")
		_close(total.result.score, 463.9, "总分显示463.9")


## 零知识不伪造分数；正智力提升成绩，负智力在有效知识仍合法时真实生效。
func _test_zero_and_intelligence() -> void:
	var zero: Dictionary = scoring.calculate_subject(_snapshot("chinese", 0.0, 2.0))
	if _accepted(zero, "零知识有效"):
		_check(zero.result.score_units == 0 and zero.result.score == 0.0, "零知识对应真实零分")
	var lower: Dictionary = scoring.calculate_subject(_snapshot("chinese", 150.0, 0.0))
	var higher: Dictionary = scoring.calculate_subject(_snapshot("chinese", 150.0, 5.0))
	var negative: Dictionary = scoring.calculate_subject(_snapshot("chinese", 150.0, -1.0))
	if _accepted(lower, "基础智力有效") and _accepted(higher, "较高智力有效") and _accepted(negative, "合法负智力有效"):
		_check(higher.result.score_units > lower.result.score_units, "同知识更高智力取得更高成绩")
		_check(negative.result.score_units < lower.result.score_units, "负智力惩罚不静默钳为零智力")
	var no_intelligence: Dictionary = _snapshot("chinese", 150.0, 100.0)
	no_intelligence.exam_intelligence_coefficient = 0.0
	var independent: Dictionary = scoring.calculate_subject(no_intelligence)
	if _accepted(independent, "零系数明确表示不计智力"):
		_check(independent.result.score_units == lower.result.score_units, "零智力系数按输入真实计算")
	var tiny: Dictionary = _snapshot("chinese", 1.0e-20, 0.0)
	tiny.max_score = 1.0e20
	tiny.score_scale = 1.0
	var tiny_result: Dictionary = scoring.calculate_subject(tiny)
	if _accepted(tiny_result, "微小曲线输入不因相消丢失分数"):
		_close(tiny_result.result.score, 1.0, "相消边界仍得到正确1分")


## 策划未设分数下限，极端负智力产生的有限负结果按原公式保留并参与求和与排序。
func _test_negative_formula_result() -> void:
	var snapshot: Dictionary = _snapshot("chinese", 100.0, -100.0)
	var negative: Dictionary = scoring.calculate_subject(snapshot)
	if not _accepted(negative, "有限负有效知识按原公式计算"):
		return
	_check(negative.result.effective_knowledge == -200.0, "负有效知识不钳为零")
	var expected_units: int = int(roundf(150.0 * (1.0 - exp(200.0 / 180.0)) * 10.0))
	_check(negative.result.score_units == expected_units and expected_units < 0, "负成绩仍按既定指数公式取整")
	var total: Dictionary = scoring.sum_subjects([negative.result])
	if _accepted(total, "有限负分可参与总分"):
		_check(total.result.score_units == expected_units, "总分不把负分当缺分或零分")
	var grouped: Dictionary = scoring.group_ties([
		{"student_id": "negative", "score_units": expected_units, "score_decimal_places": 1},
		{"student_id": "zero", "score_units": 0, "score_decimal_places": 1},
	])
	if _accepted(grouped, "负分可参与同分分组"):
		_check(grouped.result[0].entries[0].student_id == "zero" and grouped.result[1].score_units == expected_units, "负分按真实分数排在零分之后")


## 区分逐科取整与总和后取整，同分按整数刻度合组且不随机拆名次。
func _test_rounding_order_and_ties() -> void:
	var records: Array[Dictionary] = []
	for subject_id: String in ["chinese", "math", "english"]:
		var snapshot: Dictionary = _snapshot(subject_id, -log(1.0 - 1.04 / 150.0) * 180.0, 0.0)
		var result: Dictionary = scoring.calculate_subject(snapshot)
		if _accepted(result, "逐科1.04取整场景"):
			_check(result.result.score_units == 10, "每科1.04先四舍五入为1.0")
			records.append(result.result)
	var before: Array = records.duplicate(true)
	var total: Dictionary = scoring.sum_subjects(records)
	if _accepted(total, "逐科取整后求和"):
		_check(total.result.score_units == 30, "三科1.04总分为3.0而非3.1")
		_check(records == before, "求和不修改输入单科")
	var halfway: Dictionary = _snapshot("chinese", 1.0, 0.0)
	halfway.max_score = 1.25
	halfway.score_scale = 0.001
	var rounded_half: Dictionary = scoring.calculate_subject(halfway)
	if _accepted(rounded_half, "正分数半刻度可取整"):
		_check(rounded_half.result.score_units == 13, "1.25按半入方式得到1.3")
	var entries: Array[Dictionary] = [
		{"student_id": "student_0", "score_units": 300, "score_decimal_places": 1},
		{"student_id": "student_1", "score_units": 400, "score_decimal_places": 1},
		{"student_id": "student_2", "score_units": 400, "score_decimal_places": 1},
		{"student_id": "student_3", "score_units": 0, "score_decimal_places": 1},
	]
	var entries_before: Array = entries.duplicate(true)
	var grouped: Dictionary = scoring.group_ties(entries)
	if _accepted(grouped, "真实分数同分分组"):
		_check(grouped.result.size() == 3, "同分形成一组")
		_check(grouped.result[0].score_units == 400 and grouped.result[1].score_units == 300 and grouped.result[2].score_units == 0, "分组按分数降序")
		var tied_ids: Array = grouped.result[0].entries.map(func(entry: Dictionary): return entry.student_id)
		_check(tied_ids.size() == 2 and "student_1" in tied_ids and "student_2" in tied_ids, "两位同分角色均保留在首组")
		_check(not grouped.result[0].has("rank"), "纯工具不擅自决定名次编号")
		_check(entries == entries_before, "排序不修改输入顺序或角色记录")


## 每个必要字段的缺失、错误类型与非法数值都通过生产入口明确拒绝。
func _test_invalid_snapshots() -> void:
	var baseline: Dictionary = _snapshot("chinese", 100.0, 0.0)
	for key: String in SCORING.SOURCE_FIELDS:
		var missing: Dictionary = baseline.duplicate(true)
		missing.erase(key)
		_rejected(scoring.calculate_subject(missing), "缺少快照字段%s" % key)
	for subject_id: Variant in ["", " chinese", 1, null]:
		var invalid_id: Dictionary = baseline.duplicate(true)
		invalid_id.subject_id = subject_id
		_rejected(scoring.calculate_subject(invalid_id), "非法科目标识%s" % str(subject_id))
	for key: String in ["knowledge", "effective_intelligence", "max_score", "score_scale", "exam_intelligence_coefficient", "score_decimal_places"]:
		for invalid: Variant in [true, "1", null, INF, NAN]:
			var changed: Dictionary = baseline.duplicate(true)
			changed[key] = invalid
			_rejected(scoring.calculate_subject(changed), "%s非法类型或非有限数%s" % [key, str(invalid)])
	for scenario: Dictionary in [
		{"key": "knowledge", "value": -1.0},
		{"key": "max_score", "value": 0.0},
		{"key": "max_score", "value": -1.0},
		{"key": "score_scale", "value": 0.0},
		{"key": "score_scale", "value": -1.0},
		{"key": "exam_intelligence_coefficient", "value": -0.01},
		{"key": "score_decimal_places", "value": -1},
		{"key": "score_decimal_places", "value": 1.5},
	]:
		var changed: Dictionary = baseline.duplicate(true)
		changed[scenario.key] = scenario.value
		_rejected(scoring.calculate_subject(changed), "非法业务参数%s=%s" % [scenario.key, scenario.value])
	var valid: Dictionary = scoring.calculate_subject(baseline)
	_accepted(valid, "失败后合法输入重新计算")


## 总分和同分工具拒绝缺分、重复身份、不一致刻度及被改写的历史成绩。
func _test_invalid_totals_and_groups() -> void:
	var valid: Dictionary = scoring.calculate_subject(_snapshot("chinese", 100.0, 2.0)).result
	_rejected(scoring.sum_subjects([]), "空总分不能默认为零")
	_rejected(scoring.sum_subjects([{}]), "缺失单科不能默认为零")
	_rejected(scoring.sum_subjects([valid, valid]), "重复科目拒绝")
	var changed: Dictionary = valid.duplicate(true)
	changed.score_units += 1
	_rejected(scoring.sum_subjects([changed]), "伪造整数成绩拒绝")
	changed = valid.duplicate(true)
	changed.units_per_point = 100
	_rejected(scoring.sum_subjects([changed]), "伪造刻度拒绝")
	for key: String in ["effective_knowledge", "unrounded_score", "score"]:
		var tampered: Dictionary = valid.duplicate(true)
		tampered[key] += 1.0
		_rejected(scoring.sum_subjects([tampered]), "篡改历史派生字段%s拒绝" % key)
		var missing: Dictionary = valid.duplicate(true)
		missing.erase(key)
		_rejected(scoring.sum_subjects([missing]), "缺少历史派生字段%s拒绝" % key)
	var other_input: Dictionary = _snapshot("math", 100.0, 2.0)
	other_input.score_decimal_places = 2
	var other: Dictionary = scoring.calculate_subject(other_input).result
	_rejected(scoring.sum_subjects([valid, other]), "混合成绩小数位拒绝")
	_rejected(scoring.group_ties([]), "空排行榜拒绝")
	_rejected(scoring.group_ties([{}]), "缺成绩排行榜拒绝")
	var entry: Dictionary = {"student_id": "student_0", "score_units": 10, "score_decimal_places": 1}
	_rejected(scoring.group_ties([entry, entry]), "重复角色拒绝")
	for bad: Variant in [1.5, true, "10", null, INF]:
		var changed_entry: Dictionary = entry.duplicate(true)
		changed_entry.score_units = bad
		_rejected(scoring.group_ties([changed_entry]), "非法排行分数%s" % str(bad))
	var mixed: Dictionary = entry.duplicate(true)
	mixed.student_id = "student_1"
	mixed.score_decimal_places = 2
	_rejected(scoring.group_ties([entry, mixed]), "排行榜混合小数位拒绝")
	var copied: Dictionary = scoring.group_ties([entry])
	if _accepted(copied, "合法单人分组"):
		copied.result[0].entries[0].student_id = "changed"
		_check(entry.student_id == "student_0", "返回的分组不共享输入字典")


## 持久记录包含公式来源参数，原输入与当前配置后续改变都不能改写历史成绩。
func _test_historical_independence() -> void:
	var snapshot: Dictionary = _snapshot("chinese", 445.5, 2.0)
	var result: Dictionary = scoring.calculate_subject(snapshot)
	if not _accepted(result, "历史成绩建立"):
		return
	var history: Dictionary = result.result
	snapshot.knowledge = 0.0
	snapshot.max_score = 1.0
	_check(history.knowledge == 445.5 and history.max_score == 150.0, "历史来源值不共享可变输入")
	var saved_parameters: Dictionary = history.duplicate(true)
	# 仅改内存中的读取结果，不写正式JSON；真实计分入口没有任何配置读取路径。
	var original_maximum: Variant = configuration.subjects.chinese.max_score
	configuration.subjects.chinese.max_score = 10.0
	var repeated: Dictionary = scoring.calculate_subject(history)
	if _accepted(repeated, "当前配置改变后复算历史"):
		_check(repeated.result == saved_parameters, "历史复算仍使用原满分和原智力系数")
	configuration.subjects.chinese.max_score = original_maximum
	var restored: Variant = JSON.parse_string(JSON.stringify(history, "", true, true))
	_check(restored is Dictionary, "历史来源与结果可完整序列化")
	var restored_total: Dictionary = scoring.sum_subjects([restored])
	if _accepted(restored_total, "序列化往返后的历史成绩仍可验证"):
		_check(restored_total.result.score_units == history.score_units, "历史序列化不重取配置或修改分数")


## 只拒绝数值表示溢出，不人为裁定分数或知识的业务容量。
func _test_representation_boundaries() -> void:
	var baseline: Dictionary = _snapshot("chinese", 100.0, 0.0)
	for places: Variant in [309, 1000000000000, 1.0e300]:
		var changed: Dictionary = baseline.duplicate(true)
		changed.score_decimal_places = places
		_rejected(scoring.calculate_subject(changed), "十进制整数刻度不可表示%s" % places)
	var high_precision: Dictionary = baseline.duplicate(true)
	high_precision.knowledge = 1.0e300
	high_precision.max_score = 0.01
	high_precision.score_decimal_places = 19
	var high_result: Dictionary = scoring.calculate_subject(high_precision)
	if _accepted(high_result, "19位小满分的最终整数成绩仍可表示"):
		_check(high_result.result.score_units == 100000000000000000, "19位不被十进制因子的int64范围额外阻断")
		var high_total: Dictionary = scoring.sum_subjects([high_result.result])
		if _accepted(high_total, "19位成绩可进入总分"):
			_check(high_total.result.score_units == high_result.result.score_units, "高精度总分整数不变")
		var high_groups: Dictionary = scoring.group_ties([{"student_id": "precise", "score_units": high_result.result.score_units, "score_decimal_places": 19}])
		_accepted(high_groups, "19位成绩可进入同分组")
	var multiplication: Dictionary = baseline.duplicate(true)
	multiplication.knowledge = 1.0e308
	multiplication.effective_intelligence = 1.0e308
	_rejected(scoring.calculate_subject(multiplication), "有效知识乘法溢出明确拒绝")
	var curve_overflow: Dictionary = baseline.duplicate(true)
	curve_overflow.knowledge = 1.0e308
	curve_overflow.score_scale = 1.0e-300
	_rejected(scoring.calculate_subject(curve_overflow), "曲线除法溢出明确拒绝")
	var score_overflow: Dictionary = baseline.duplicate(true)
	score_overflow.knowledge = 1.0e10
	score_overflow.max_score = 1.0e308
	_rejected(scoring.calculate_subject(score_overflow), "分数整数刻度溢出明确拒绝")
	var negative_exponential: Dictionary = baseline.duplicate(true)
	negative_exponential.knowledge = 1.0e6
	negative_exponential.effective_intelligence = -100.0
	_rejected(scoring.calculate_subject(negative_exponential), "负有效知识的指数溢出明确拒绝")
	var integer_overflow: Dictionary = baseline.duplicate(true)
	integer_overflow.knowledge = 1.0e300
	integer_overflow.max_score = 1.0e18
	_rejected(scoring.calculate_subject(integer_overflow), "有限浮点成绩超过int64刻度明确拒绝")
	var large: Dictionary = baseline.duplicate(true)
	large.knowledge = 1.0e300
	large.max_score = 1.0e17
	var large_result: Dictionary = scoring.calculate_subject(large)
	if _accepted(large_result, "可表示大知识和大分数不设业务上限"):
		_check(large_result.result.score_units == 1000000000000000000, "大分数原样保留整数刻度")
	var summands: Array[Dictionary] = []
	for index: int in 2:
		var subject: Dictionary = baseline.duplicate(true)
		subject.subject_id = "large_%s" % index
		subject.knowledge = 1.0e300
		subject.max_score = 5.0e17
		var item: Dictionary = scoring.calculate_subject(subject)
		if _accepted(item, "总分溢出前每科均可表示"):
			summands.append(item.result)
	_rejected(scoring.sum_subjects(summands), "总分整数相加溢出不得返回负分")
	var maximum_entry: Dictionary = {"student_id": "max", "score_units": SCORING.MAX_INTEGER, "score_decimal_places": 0}
	var maximum_group: Dictionary = scoring.group_ties([maximum_entry])
	if _accepted(maximum_group, "排序可保留int64最大合法整数分数"):
		_check(maximum_group.result[0].score_units == SCORING.MAX_INTEGER, "排序不经浮点数损坏整数分数")
	var minimum_entry: Dictionary = {"student_id": "min", "score_units": SCORING.MIN_INTEGER, "score_decimal_places": 0}
	var minimum_group: Dictionary = scoring.group_ties([minimum_entry])
	if _accepted(minimum_group, "排序可保留int64最小合法整数分数"):
		_check(minimum_group.result[0].score_units == SCORING.MIN_INTEGER, "排序保留负整数刻度表示边界")


## 正负成绩先相互抵消，数学最终和可表示时不因输入顺序出现额外溢出拒绝。
func _test_signed_total_cancellation() -> void:
	var positive_source: Dictionary = _snapshot("chinese", 1.0e300, 0.0)
	positive_source.subject_id = "positive_a"
	positive_source.max_score = 8.0e17
	positive_source.score_scale = 1.0
	positive_source.exam_intelligence_coefficient = 1.0
	var first: Dictionary = scoring.calculate_subject(positive_source)
	if not _accepted(first, "正抵消项可单独表示"):
		return
	var second_source: Dictionary = positive_source.duplicate(true)
	second_source.subject_id = "positive_b"
	var second: Dictionary = scoring.calculate_subject(second_source)
	if not _accepted(second, "第二个正抵消项可单独表示"):
		return
	var negative_source: Dictionary = positive_source.duplicate(true)
	negative_source.subject_id = "negative_a"
	negative_source.knowledge = 1.0
	negative_source.effective_intelligence = -1.0 - log(2.0)
	var third: Dictionary = scoring.calculate_subject(negative_source)
	if not _accepted(third, "负抵消项可单独表示"):
		return
	_check(first.result.score_units == 8000000000000000000 and third.result.score_units == -8000000000000000000, "构造实际公式产生的有符号大成绩")
	var positive_total: Dictionary = scoring.sum_subjects([first.result, second.result, third.result])
	if _accepted(positive_total, "8e18加8e18减8e18仍能求和"):
		_check(positive_total.result.score_units == 8000000000000000000, "抵消后正总分精确可表示")
		_check(positive_total.result.subject_records.map(func(record: Dictionary): return record.subject_id) == ["positive_a", "positive_b", "negative_a"], "内部求和顺序不改变返回科目顺序")
	var fourth_source: Dictionary = negative_source.duplicate(true)
	fourth_source.subject_id = "negative_b"
	var fourth: Dictionary = scoring.calculate_subject(fourth_source)
	if not _accepted(fourth, "第二个负抵消项可单独表示"):
		return
	var negative_total: Dictionary = scoring.sum_subjects([third.result, fourth.result, first.result])
	if _accepted(negative_total, "负8e18减8e18加8e18仍能求和"):
		_check(negative_total.result.score_units == -8000000000000000000, "抵消后负总分精确可表示")
	_rejected(scoring.sum_subjects([third.result, fourth.result]), "不可抵消的负总分溢出明确失败")


## 成功必须有真实结果且不残留之前的错误。
func _accepted(result: Dictionary, label: String) -> bool:
	if not _check(result.has("error") and result.error == OK and result.has("result"), "%s：%s" % [label, scoring.error_message]):
		return false
	_check(scoring.error_message.is_empty(), "%s成功不残留错误" % label)
	return true


## 失败必须有非OK错误及可见原因，且不能携带默认成绩。
func _rejected(result: Dictionary, label: String) -> void:
	_check(result.has("error") and result.error != OK, "%s必须失败" % label)
	_check(result.has("message") and not result.message.is_empty() and not scoring.error_message.is_empty(), "%s失败原因可见" % label)
	_check(not result.has("result"), "%s不携带成功或零分结果" % label)


## 浮点显示只使用合理误差，权威取整与总分由整数断言精确复核。
func _close(actual: float, expected: float, label: String) -> void:
	_check(absf(actual - expected) < 0.000000001, "%s：实际%s，预期%s" % [label, actual, expected])


## 只累计实际执行的检查，所有失败最终影响退出码。
func _check(condition: bool, message: String) -> bool:
	checks += 1
	if not condition:
		failures.append(message)
	return condition


## 输出唯一专项结论，不创建或清理任何正式用户数据。
func _finish() -> void:
	if failures.is_empty():
		print("EXAM_SCORING_TEST_PASS checks=%s" % checks)
		quit(0)
	else:
		for message: String in failures:
			push_error(message)
		print("EXAM_SCORING_TEST_FAIL checks=%s failures=%s" % [checks, failures.size()])
		quit(1)
