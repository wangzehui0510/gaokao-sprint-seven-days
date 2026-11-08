class_name ExamScoring
extends RefCounted
## 考试公式的纯计算入口；只读取显式快照，不依赖当前配置、时钟、随机流或存档。

# 成绩整数只受int64表示范围约束，十进制换算因子使用浮点表示且不设置业务上限。
const MAX_INTEGER: int = 9223372036854775807
const MIN_INTEGER: int = -9223372036854775808
const INTEGER_START: float = -9223372036854775808.0
const INTEGER_EXCLUSIVE_END: float = 9223372036854775808.0
const SOURCE_FIELDS: Array[String] = [
	"subject_id", "knowledge", "effective_intelligence", "max_score", "score_scale",
	"exam_intelligence_coefficient", "score_decimal_places",
]
# 失败消息供调用方展示；所有失败同时返回非OK错误码，不返回默认成绩。
var error_message: String = ""


## 用同一份开考快照计算单科，并保留当次知识、智力及公式参数供历史解释和复算。
func calculate_subject(snapshot: Dictionary) -> Dictionary:
	error_message = ""
	if not snapshot.has_all(SOURCE_FIELDS):
		return _failure("考试快照缺少科目、知识、智力或计分参数")
	if not snapshot.subject_id is String or snapshot.subject_id.is_empty() or snapshot.subject_id != snapshot.subject_id.strip_edges():
		return _failure("考试科目标识必须为非空且无首尾空白的文本")
	for key: String in ["knowledge", "effective_intelligence", "max_score", "score_scale", "exam_intelligence_coefficient"]:
		if not _is_number(snapshot[key]):
			return _failure("考试快照%s必须为有限数字" % key)
	if snapshot.knowledge < 0.0:
		return _failure("考试知识不能为负数")
	if snapshot.max_score <= 0.0 or snapshot.score_scale <= 0.0:
		return _failure("考试满分和曲线参数必须大于零")
	if snapshot.exam_intelligence_coefficient < 0.0:
		return _failure("智力考试系数不能为负数")
	var unit_scale: float = _decimal_scale(snapshot.score_decimal_places)
	if unit_scale == 0.0:
		return _failure(error_message)
	var multiplier: float = 1.0 + float(snapshot.exam_intelligence_coefficient) * float(snapshot.effective_intelligence)
	var effective_knowledge: float = float(snapshot.knowledge) * multiplier
	# 策划未设成绩下限；有效智力导致的有限负有效知识仍忠实代入原公式。
	if not is_finite(multiplier) or not is_finite(effective_knowledge):
		return _failure("考试有效知识必须为有限数字")
	var curve_input: float = effective_knowledge / float(snapshot.score_scale)
	if not is_finite(curve_input):
		return _failure("考试曲线输入超出浮点数表示范围")
	var unrounded_score: float = float(snapshot.max_score) * _score_fraction(curve_input)
	var scaled_score: float = unrounded_score * float(unit_scale)
	if not is_finite(unrounded_score) or not is_finite(scaled_score):
		return _failure("单科成绩超出浮点数表示范围")
	var rounded_units: float = roundf(scaled_score)
	if rounded_units < INTEGER_START or rounded_units >= INTEGER_EXCLUSIVE_END:
		return _failure("单科成绩的整数刻度超出int64表示范围")
	var score_units: int = int(rounded_units)
	var record: Dictionary = {}
	for key: String in SOURCE_FIELDS:
		record[key] = snapshot[key]
	record.score_decimal_places = int(snapshot.score_decimal_places)
	record.units_per_point = unit_scale
	record.effective_knowledge = effective_knowledge
	record.unrounded_score = unrounded_score
	record.score_units = score_units
	record.score = float(score_units) / float(unit_scale)
	return {"error": OK, "result": record}


## 每科先独立取整，再用整数刻度精确求和；缺科由上层明确指定，空集合或损坏记录不能按零分成功。
func sum_subjects(subject_records: Array) -> Dictionary:
	error_message = ""
	if subject_records.is_empty():
		return _failure("总分至少需要一份真实单科成绩")
	var total_units: int = 0
	var unit_scale: float = 0.0
	var decimal_places: int = -1
	var subject_ids: Dictionary = {}
	var records: Array[Dictionary] = []
	var positive_units: Array[int] = []
	var negative_units: Array[int] = []
	for record: Variant in subject_records:
		if not record is Dictionary or not record.has_all(["score_units", "units_per_point", "score_decimal_places", "effective_knowledge", "unrounded_score", "score"]):
			return _failure("总分中的单科成绩记录不完整")
		var recalculated: Dictionary = calculate_subject(record)
		if recalculated.error != OK:
			return recalculated
		var expected: Dictionary = recalculated.result
		if not _is_signed_integer(record.score_units) or record.score_units != expected.score_units:
			return _failure("单科成绩整数刻度与保存的开考参数不一致")
		for key: String in ["units_per_point", "effective_knowledge", "unrounded_score", "score"]:
			if not _is_number(record[key]) or record[key] != expected[key]:
				return _failure("单科成绩%s与保存的开考参数不一致" % key)
		if subject_ids.has(expected.subject_id):
			return _failure("总分包含重复科目：%s" % expected.subject_id)
		subject_ids[expected.subject_id] = true
		if unit_scale == 0.0:
			unit_scale = expected.units_per_point
			decimal_places = expected.score_decimal_places
		elif unit_scale != expected.units_per_point:
			return _failure("总分中的单科成绩必须使用相同小数位")
		var incoming_units: int = int(record.score_units)
		if incoming_units > 0:
			positive_units.append(incoming_units)
		elif incoming_units < 0:
			negative_units.append(incoming_units)
		records.append(expected)
	# 优先累加与当前和异号的项，避免输入顺序制造本可抵消的中间溢出；科目返回顺序保持不变。
	var positive_index: int = 0
	var negative_index: int = 0
	while positive_index < positive_units.size() or negative_index < negative_units.size():
		var incoming_units: int
		if negative_index < negative_units.size() and (total_units >= 0 or positive_index >= positive_units.size()):
			incoming_units = negative_units[negative_index]
			negative_index += 1
		else:
			incoming_units = positive_units[positive_index]
			positive_index += 1
		if (incoming_units > 0 and total_units > MAX_INTEGER - incoming_units) or (incoming_units < 0 and total_units < MIN_INTEGER - incoming_units):
			return _failure("总分的整数刻度超出int64表示范围")
		total_units += incoming_units
	return {"error": OK, "result": {
		"subject_records": records, "score_decimal_places": decimal_places,
		"units_per_point": unit_scale, "score_units": total_units,
		"score": float(total_units) / float(unit_scale),
	}}


## 按整数分数降序分组，同分保留为同一组；具体名次编号和展示样式留待榜单规则确认。
func group_ties(entries: Array) -> Dictionary:
	error_message = ""
	if entries.is_empty():
		return _failure("排行榜至少需要一名有真实成绩的角色")
	var ordered: Array[Dictionary] = []
	var identities: Dictionary = {}
	var unit_scale: float = 0.0
	for entry: Variant in entries:
		if not entry is Dictionary or not entry.has_all(["student_id", "score_units", "score_decimal_places"]):
			return _failure("排行榜成绩缺少角色、整数分数或小数位")
		if not entry.student_id is String or entry.student_id.is_empty() or entry.student_id != entry.student_id.strip_edges() or identities.has(entry.student_id):
			return _failure("排行榜角色标识必须为非空且唯一的文本")
		if not _is_signed_integer(entry.score_units):
			return _failure("排行榜分数必须为int64可表示的有符号整数刻度")
		var entry_scale: float = _decimal_scale(entry.score_decimal_places)
		if entry_scale == 0.0:
			return _failure(error_message)
		if unit_scale == 0.0:
			unit_scale = entry_scale
		elif unit_scale != entry_scale:
			return _failure("排行榜成绩必须使用相同小数位")
		identities[entry.student_id] = true
		var copied: Dictionary = entry.duplicate(true)
		copied.score_units = int(entry.score_units)
		copied.score_decimal_places = int(entry.score_decimal_places)
		ordered.append(copied)
	# 只按分数比较；同分组没有随机拆名次，也不读取当前可变角色状态。
	ordered.sort_custom(func(left: Dictionary, right: Dictionary) -> bool: return left.score_units > right.score_units)
	var groups: Array[Dictionary] = []
	for entry: Dictionary in ordered:
		if groups.is_empty() or groups[-1].score_units != entry.score_units:
			groups.append({
				"score_units": int(entry.score_units), "score": float(entry.score_units) / float(unit_scale),
				"units_per_point": unit_scale, "entries": [],
			})
		groups[-1].entries.append(entry)
	return {"error": OK, "result": groups}


## 小输入使用收敛级数避免1-exp(-x)的相消误差，不以固定迭代次数裁掉真实精度。
func _score_fraction(curve_input: float) -> float:
	if absf(curve_input) >= 0.5:
		return 1.0 - exp(-curve_input)
	var term: float = curve_input
	var total: float = term
	var divisor: float = 2.0
	while term != 0.0:
		term *= -curve_input / divisor
		var next_total: float = total + term
		if next_total == total:
			return total
		total = next_total
		divisor += 1.0
	return total


## 十进制换算因子只检查浮点表示范围，最终成绩整数另行检查int64范围。
func _decimal_scale(places: Variant) -> float:
	if not _is_number(places) or places < 0.0 or float(places) != floorf(float(places)):
		error_message = "成绩小数位必须为非负整数"
		return 0.0
	var scale: float = pow(10.0, float(places))
	if not is_finite(scale):
		error_message = "成绩十进制刻度超出浮点数表示范围"
		return 0.0
	return scale


## 数值边界拒绝布尔值、字符串以及非有限数字，不做隐式转换。
func _is_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


## 整数输入保留int64两端，JSON浮点输入必须落在可安全转为整型的半开区间。
func _is_signed_integer(value: Variant) -> bool:
	if value is int:
		return true
	return value is float and is_finite(value) and value >= INTEGER_START and value < INTEGER_EXCLUSIVE_END and value == floorf(value)


## 返回明确错误且不携带成绩结果，调用方不能把失败记录当作零分。
func _failure(message: String) -> Dictionary:
	error_message = message
	return {"error": ERR_INVALID_DATA, "message": message}
