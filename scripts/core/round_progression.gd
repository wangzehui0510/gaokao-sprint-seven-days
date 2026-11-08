class_name RoundProgression
extends RefCounted
## 七天局的纯事件账本；知识只接收真实执行器增量，考试只在课表边界取值。

const SCORING = preload("res://scripts/core/exam_scoring.gd")
# 账本保存独立来源与已发生结果，热更新不能回写历史。
var data: Dictionary = {}
var configuration: RefCounted
var error_message: String = ""
var events: Array[Dictionary] = []
var scoring: RefCounted = SCORING.new()


## 新局仅建立待处理事件，不在setup电脑时刻伪造已经发生的榜单。
func setup(config: RefCounted, participants: Array, at_day: int, seconds: float, legacy: bool = false) -> Error:
	configuration = config
	data = {
		"schema_version": 1, "session_days": int(config.global_value("session_days")),
		"subject_ids": [], "daily_days": {}, "exams": {},
		"final": {"status": "pending", "reason": "", "rows": [], "missing_subjects": []},
		"finished": false, "observed": false, "last_position": {"day": at_day, "clock_seconds": seconds},
		"recorded_through": {"day": 0, "clock_seconds": 0.0},
		"frozen": {},
	}
	for subject_id: String in config.subjects:
		if config.subjects[subject_id].kind == "knowledge":
			data.subject_ids.append(subject_id)
	var plan: Dictionary = _plan(config)
	for round_day: int in range(1, data.session_days + 1):
		data.daily_days[str(round_day)] = _new_daily(round_day, plan.cutoffs[str(round_day)], participants)
	for subject_id: String in plan.exams:
		data.exams[subject_id] = _new_exam(subject_id, plan.exams[subject_id])
	data.final_day = data.session_days
	data.final_seconds = plan.cutoffs[str(data.session_days)]
	if legacy:
		return relocate(at_day, seconds, participants, true)
	return OK


## 课表变化只更新尚未发生事件的时刻，已快照与已公布记录保持原参数和原结果。
func apply_config(config: RefCounted, participants: Array) -> Error:
	var plan: Dictionary = _plan(config)
	var new_subjects: Array = []
	for subject_id: String in config.subjects:
		if config.subjects[subject_id].kind == "knowledge":
			new_subjects.append(subject_id)
	if new_subjects != data.subject_ids:
		return _fail("新配置改变了本局已建立的知识科目，无法保持榜单账本一致")
	if int(config.global_value("session_days")) != data.session_days:
		return _fail("新配置改变了本局天数，无法保持已建立的课程事件身份")
	for subject_id: String in data.exams:
		if not plan.exams.has(subject_id):
			return _fail("新配置删除了本局考试科目：%s" % subject_id)
	# 所有新边界先整体校验，失败不得部分改写账本或切换其配置引用。
	var observed_day: int = int(data.last_position.day)
	var observed_seconds: float = data.last_position.clock_seconds
	if _before(observed_day, observed_seconds, int(data.recorded_through.day), data.recorded_through.clock_seconds):
		observed_day = int(data.recorded_through.day)
		observed_seconds = data.recorded_through.clock_seconds
	for key: String in data.daily_days:
		var daily: Dictionary = data.daily_days[key]
		if daily.status == "pending" and daily.end_seconds != plan.cutoffs[key] and _before(int(daily.day), plan.cutoffs[key], observed_day, observed_seconds):
			return _fail("新配置将第%s天尚待日榜移到已观察时刻之前，无法追溯统计" % key)
	for subject_id: String in data.exams:
		var exam: Dictionary = data.exams[subject_id]
		var timing: Dictionary = plan.exams[subject_id]
		if exam.status == "pending" and (exam.day != timing.day or exam.start_seconds != timing.start_seconds or exam.end_seconds != timing.end_seconds) and _before(int(timing.day), timing.start_seconds, observed_day, observed_seconds):
			return _fail("新配置将尚待考试%s移到已观察时刻之前，无法补造开考快照" % subject_id)
	var final_seconds: float = plan.cutoffs[str(int(data.session_days))]
	if not data.finished and final_seconds != data.final_seconds and _before(int(data.final_day), final_seconds, observed_day, observed_seconds):
		return _fail("新配置将本局终局移到已观察时刻之前，无法追溯结算")
	configuration = config
	for key: String in data.daily_days:
		if data.daily_days[key].status == "pending":
			data.daily_days[key].end_seconds = plan.cutoffs[key]
	for subject_id: String in data.exams:
		if data.exams[subject_id].status == "pending":
			data.exams[subject_id].merge(plan.exams[subject_id], true)
	if not data.finished:
		data.final_seconds = final_seconds
	return OK


## 真实积分完成后累计当前日新增知识；查看榜单和离线补事件均不会调用此入口。
func add_knowledge(at_day: int, subject_id: String, student_id: String, amount: float) -> void:
	if data.finished or not data.daily_days.has(str(at_day)):
		return
	var daily: Dictionary = data.daily_days[str(at_day)]
	if daily.status == "pending":
		daily.gains[student_id][subject_id] += amount


## 返回下一尚未处理的纯事件边界，供唯一模拟器与动作、课表和状态共同分段。
func next_boundary(at_day: int, seconds: float) -> float:
	var next_seconds: float = 86400.0
	if data.finished:
		return seconds
	if data.daily_days.has(str(at_day)):
		var daily: Dictionary = data.daily_days[str(at_day)]
		if daily.status == "pending" and daily.end_seconds > seconds:
			next_seconds = minf(next_seconds, daily.end_seconds)
	for exam: Dictionary in data.exams.values():
		if exam.day != at_day:
			continue
		if exam.status == "pending" and exam.start_seconds > seconds:
			next_seconds = minf(next_seconds, exam.start_seconds)
		if exam.status == "snapshot" and exam.end_seconds > seconds:
			next_seconds = minf(next_seconds, exam.end_seconds)
	if data.final_day == at_day and data.final_seconds > seconds:
		next_seconds = minf(next_seconds, data.final_seconds)
	return next_seconds


## 开发跳时只标记没有观察到的历史，不补造过去快照；首次定位可调整尚未真实执行的起点。
func relocate(at_day: int, seconds: float, participants: Array, legacy: bool = false) -> Error:
	events.clear()
	if data.finished:
		return OK
	var first_position: bool = not data.observed
	for daily: Dictionary in data.daily_days.values():
		if daily.status != "pending":
			continue
		if _before(daily.day, daily.end_seconds, at_day, seconds):
			_mark_daily_unrecorded(daily, "旧档缺少当日日初记录" if legacy else "开发时钟跳过出榜时刻")
		elif daily.day == at_day:
			if legacy:
				daily.start_seconds = seconds
				daily.source = "partial"
				daily.reason = "旧档迁移当天仅统计接入后的真实新增知识"
			elif first_position:
				daily.start_seconds = seconds if at_day > 1 else 0.0
				if at_day > 1 and seconds > 0.0:
					daily.source = "partial"
					daily.reason = "开发局跳过前序时段，仅统计接入后的真实新增知识"
			else:
				daily.source = "partial"
				daily.reason = "开发时钟跳过部分时段，仅统计真实执行的知识"
	for exam: Dictionary in data.exams.values():
		if exam.status == "pending" and _before(exam.day, exam.start_seconds, at_day, seconds):
			exam.status = "unrecorded"
			exam.source = "legacy_unrecorded" if legacy else "debug_unrecorded"
			exam.reason = "缺少真实开考快照，不能用当前状态补造历史成绩"
	data.last_position = {"day": at_day, "clock_seconds": seconds}
	if legacy:
		data.observed = true
	if _before(data.final_day, data.final_seconds, at_day, seconds):
		data.observed = true
		_record_position(at_day, seconds)
		return _publish_final()
	return OK


## 先处理快照和公布，再出日榜与最终榜；offline_frozen只使用保存时显式冻结的输入。
func process_position(at_day: int, seconds: float, participants: Array, source: String = "online", frozen: Dictionary = {}) -> Error:
	events.clear()
	if data.finished:
		return OK
	data.observed = true
	_record_position(at_day, seconds)
	var offline: bool = source == "offline_frozen"
	for exam: Dictionary in data.exams.values():
		if exam.status == "pending" and _at_or_before(exam.day, exam.start_seconds, at_day, seconds):
			var missing_before_freeze: bool = offline and _before(exam.day, exam.start_seconds, int(frozen.day), frozen.clock_seconds)
			if missing_before_freeze or (not offline and _before(exam.day, exam.start_seconds, at_day, seconds)):
				exam.status = "unrecorded"
				exam.source = "unrecorded"
				exam.reason = "没有记录开考时刻，不能补造知识和智力快照"
			else:
				var result: Error = _snapshot_exam(exam, frozen.students if offline else participants, source, frozen.parameters if offline else {})
				if result != OK:
					return result
		if exam.status == "snapshot" and _at_or_before(exam.day, exam.end_seconds, at_day, seconds):
			exam.status = "published"
			events.append({"type": "exam_published", "subject_id": exam.subject_id, "source": exam.source})
	for daily: Dictionary in data.daily_days.values():
		if daily.status != "pending" or not _at_or_before(daily.day, daily.end_seconds, at_day, seconds):
			continue
		var missing_before_freeze: bool = offline and _before(daily.day, daily.end_seconds, int(frozen.day), frozen.clock_seconds)
		if missing_before_freeze or (not offline and _before(daily.day, daily.end_seconds, at_day, seconds)):
			_mark_daily_unrecorded(daily, "没有观察到出榜时刻，保留缺失记录")
		else:
			daily.status = "published"
			if offline:
				var previous_reason: String = daily.reason
				daily.source = "offline_frozen"
				daily.reason = (previous_reason + "；" if not previous_reason.is_empty() else "") + "关闭期间知识未增加，依据保存的真实新增知识补发榜单"
			_publish_daily_rows(daily, participants)
			events.append({"type": "daily_board", "day": daily.day, "source": daily.source})
	data.last_position = {"day": at_day, "clock_seconds": seconds}
	if _at_or_before(data.final_day, data.final_seconds, at_day, seconds):
		return _publish_final()
	return OK


## 查询返回深拷贝，缺历史有明确状态和原因，不修改随机流或事件日志。
func daily_board(at_day: int, subject_id: String) -> Dictionary:
	if not data.daily_days.has(str(at_day)) or subject_id not in data.subject_ids:
		return {"status": "unrecorded", "day": at_day, "subject_id": subject_id, "start_seconds": 0.0, "end_seconds": 0.0, "source": "unrecorded", "reason": "请求的日期或知识科目不属于本局", "rows": []}
	var daily: Dictionary = data.daily_days[str(at_day)]
	return {
		"status": daily.status, "day": daily.day, "subject_id": subject_id,
		"start_seconds": daily.start_seconds, "end_seconds": daily.end_seconds,
		"source": daily.source, "reason": daily.reason,
		"rows": daily.boards[subject_id].duplicate(true) if daily.boards.has(subject_id) else [],
	}


## 考试按知识科目查询，也接收配置中的exam课程别名，不在查询时计算或公布成绩。
func exam_board(subject_id: String) -> Dictionary:
	var key: String = subject_id
	if configuration.subjects.has(key) and configuration.subjects[key].kind == "exam":
		key = configuration.subjects[key].knowledge_subject_id
	if not data.exams.has(key):
		return {"status": "unrecorded", "day": data.session_days, "subject_id": key, "start_seconds": 0.0, "end_seconds": 0.0, "source": "unrecorded", "reason": "本局没有该考试科目", "rows": []}
	return data.exams[key].duplicate(true)


## 最终榜始终返回真实完整状态；缺科时不以零分补成完整总榜。
func final_board() -> Dictionary:
	return data.final.duplicate(true)


## 冻结发生在保存边界，包含独立知识、当时有效智力和各科完整计分参数。
func freeze(at_day: int, seconds: float, participants: Array) -> void:
	var parameters: Dictionary = {}
	for subject_id: String in data.subject_ids:
		parameters[subject_id] = _parameters(subject_id)
	data.frozen = {
		"day": at_day, "clock_seconds": seconds,
		"students": participants.duplicate(true), "parameters": parameters,
		"config_fingerprint": configuration.fingerprint, "config_version": configuration.version,
	}


## 磁盘成绩刻度使用十进制字符串，避免JSON数字经浮点解析损坏大整数。
func encoded() -> Dictionary:
	return _encode(data)


## 新版账本在替换有效局前完整校验；失败不采用缓存、默认成绩或部分有效记录。
func restore(encoded_data: Variant, config: RefCounted, participants: Array, at_day: int, seconds: float, fingerprint: String) -> Error:
	configuration = config
	error_message = ""
	if not encoded_data is Dictionary:
		return _fail("v4存档缺少七天结算账本")
	var decoded: Variant = _decode(encoded_data)
	if not error_message.is_empty():
		return ERR_INVALID_DATA
	if not decoded is Dictionary:
		return _fail("七天结算账本格式错误")
	data = decoded
	return _validate(participants, at_day, seconds, fingerprint)


## 从真实课表生成出榜与考试边界，体育与第一场考试共同取值并立即公布。
func _plan(config: RefCounted) -> Dictionary:
	var cutoffs: Dictionary = {}
	var exams: Dictionary = {}
	var last_day: int = int(config.global_value("session_days"))
	var first_exam: float = 86400.0
	for row: Dictionary in config.tables.schedule:
		var period: Dictionary = config.indexes.periods[row.period_id]
		var start: float = roundf(period.start_time * 86400.0)
		var finish: float = roundf(period.end_time * 86400.0)
		var key: String = str(int(row.day))
		cutoffs[key] = maxf(cutoffs[key] if cutoffs.has(key) else 0.0, finish)
		var subject: Dictionary = config.subjects[row.subject_id]
		if subject.kind == "exam":
			exams[subject.knowledge_subject_id] = {"day": int(row.day), "start_seconds": start, "end_seconds": finish}
			first_exam = minf(first_exam, start)
	exams["physical"] = {"day": last_day, "start_seconds": first_exam, "end_seconds": first_exam}
	return {"cutoffs": cutoffs, "exams": exams}


## 每天的增量从零开始，旧局基线由迁移入口显式标注，不从累计知识推测。
func _new_daily(at_day: int, cutoff: float, participants: Array) -> Dictionary:
	var gains: Dictionary = {}
	for student: Dictionary in participants:
		gains[student.id] = {}
		for subject_id: String in data.subject_ids:
			gains[student.id][subject_id] = 0.0
	return {"day": at_day, "status": "pending", "start_seconds": 0.0, "end_seconds": cutoff, "source": "online", "reason": "", "gains": gains, "boards": {}}


## 每门考试初始没有成绩，避免把待开考展示成默认零分。
func _new_exam(subject_id: String, timing: Dictionary) -> Dictionary:
	return {"day": timing.day, "subject_id": subject_id, "start_seconds": timing.start_seconds, "end_seconds": timing.end_seconds, "status": "pending", "source": "online", "reason": "", "rows": []}


## 当次参数保留配置指纹，之后热改只能作用于尚未取值的考试。
func _parameters(subject_id: String) -> Dictionary:
	var subject: Dictionary = configuration.subjects[subject_id]
	return {
		"max_score": subject.max_score, "score_scale": subject.score_scale,
		"exam_intelligence_coefficient": configuration.global_value("exam_intelligence_coefficient"),
		"score_decimal_places": configuration.global_value("score_decimal_places"),
		"config_fingerprint": configuration.fingerprint, "config_version": configuration.version,
	}


## 开考取值与角色当前exam动作无关，反复专注或互动回课不会重取值。
func _snapshot_exam(exam: Dictionary, participants: Array, source: String, frozen_parameters: Dictionary) -> Error:
	var rows: Array[Dictionary] = []
	var parameters: Dictionary = frozen_parameters[exam.subject_id] if source == "offline_frozen" else _parameters(exam.subject_id)
	for student: Dictionary in participants:
		var snapshot: Dictionary = parameters.duplicate(true)
		snapshot.subject_id = exam.subject_id
		snapshot.knowledge = student.knowledge[exam.subject_id]
		snapshot.effective_intelligence = student.effective_intelligence
		var calculated: Dictionary = scoring.calculate_subject(snapshot)
		if calculated.error != OK:
			return _fail("考试快照计算失败：%s" % scoring.error_message)
		var row: Dictionary = calculated.result
		row.student_id = student.id
		row.name = student.name
		row.config_fingerprint = parameters.config_fingerprint
		row.config_version = parameters.config_version
		rows.append(row)
	exam.rows = _rank(rows, "score_units")
	exam.status = "snapshot"
	exam.source = source
	exam.reason = "按保存时冻结的知识、有效智力和计分参数补齐纯事件；没有离线学习" if source == "offline_frozen" else ""
	events.append({"type": "exam_snapshot", "subject_id": exam.subject_id, "source": source})
	return OK


## 已公布日榜保存真实增量与并列名次，后续学习或查看不改写旧结果。
func _publish_daily_rows(daily: Dictionary, participants: Array) -> void:
	for subject_id: String in data.subject_ids:
		var rows: Array[Dictionary] = []
		for student: Dictionary in participants:
			rows.append({"student_id": student.id, "name": student.name, "knowledge": daily.gains[student.id][subject_id]})
		daily.boards[subject_id] = _rank(rows, "knowledge")


## 缺少历史明确保留unrecorded，不清空已经真实累计的知识。
func _mark_daily_unrecorded(daily: Dictionary, reason: String) -> void:
	daily.status = "unrecorded"
	daily.source = "unrecorded"
	daily.reason = reason


## 各科缺一就只发布incomplete，完整时逐人的历史单科整数成绩相加并冻结终局。
func _publish_final() -> Error:
	var result: Dictionary = _calculate_final()
	if result.has("error"):
		return _fail(result.error)
	data.final = result
	data.finished = true
	data.last_position = {"day": data.final_day, "clock_seconds": data.final_seconds}
	events.append({"type": "round_finished", "status": result.status})
	return OK


## 总榜只读取已公布快照；不同历史小数位先精确换算到共同刻度，单科不重新取整。
func _calculate_final() -> Dictionary:
	var missing: Array[String] = []
	for subject_id: String in data.subject_ids:
		if not data.exams.has(subject_id) or data.exams[subject_id].status != "published":
			missing.append(subject_id)
	if not missing.is_empty():
		return {"status": "incomplete", "reason": "缺少真实开考记录或已公布科目，未生成完整总榜", "missing_subjects": missing, "rows": []}
	var decimals: int = 0
	for exam: Dictionary in data.exams.values():
		decimals = maxi(decimals, int(exam.rows[0].score_decimal_places))
	var total_rows: Array[Dictionary] = []
	var first_exam: Dictionary = data.exams[data.subject_ids[0]]
	for first_row: Dictionary in first_exam.rows:
		var units: Array[int] = []
		var subject_scores: Dictionary = {}
		for subject_id: String in data.subject_ids:
			var matched: Dictionary = {}
			for row: Dictionary in data.exams[subject_id].rows:
				if row.student_id == first_row.student_id:
					matched = row
					break
			var scaled_units: int = int(matched.score_units)
			for step: int in range(decimals - int(matched.score_decimal_places)):
				if scaled_units > SCORING.MAX_INTEGER / 10 or scaled_units < SCORING.MIN_INTEGER / 10:
					return {"error": "历史单科换算到总分刻度时超出int64表示范围"}
				scaled_units *= 10
			units.append(scaled_units)
			subject_scores[subject_id] = matched.score
		var summed: Dictionary = _sum_signed(units)
		if summed.error != OK:
			return {"error": "历史单科相加超出总分int64表示范围"}
		total_rows.append({
			"student_id": first_row.student_id, "name": first_row.name,
			"score_units": summed.result, "score_decimal_places": decimals,
			"score": float(summed.result) / pow(10.0, decimals), "subject_scores": subject_scores,
		})
	return {"status": "published", "reason": "", "missing_subjects": [], "rows": _rank(total_rows, "score_units")}


## 采用异号抵消顺序，避免数学最终和可表示却因输入顺序产生中间溢出。
func _sum_signed(values: Array[int]) -> Dictionary:
	var positive: Array[int] = []
	var negative: Array[int] = []
	for value: int in values:
		if value > 0:
			positive.append(value)
		elif value < 0:
			negative.append(value)
	var p: int = 0
	var n: int = 0
	var total: int = 0
	while p < positive.size() or n < negative.size():
		var incoming: int
		if n < negative.size() and (total >= 0 or p >= positive.size()):
			incoming = negative[n]
			n += 1
		else:
			incoming = positive[p]
			p += 1
		if (incoming > 0 and total > SCORING.MAX_INTEGER - incoming) or (incoming < 0 and total < SCORING.MIN_INTEGER - incoming):
			return {"error": ERR_INVALID_DATA}
		total += incoming
	return {"error": OK, "result": total}


## 竞争排名为1、1、3，同值不以随机数或角色ID拆名次。
func _rank(rows: Array[Dictionary], field: String) -> Array[Dictionary]:
	rows.sort_custom(func(left: Dictionary, right: Dictionary) -> bool: return left[field] > right[field])
	var rank_value: int = 0
	for index: int in rows.size():
		if index == 0 or rows[index][field] != rows[index - 1][field]:
			rank_value = index + 1
		rows[index].rank = rank_value
	return rows


## 账本格式与交叉关联统一在不可信文件边界校验。
func _validate(participants: Array, at_day: int, seconds: float, fingerprint: String) -> Error:
	if not data.has_all(["schema_version", "session_days", "subject_ids", "daily_days", "exams", "final", "finished", "observed", "last_position", "recorded_through", "frozen", "final_day", "final_seconds"]):
		return _fail("七天结算账本字段缺失")
	if not _integer(data.schema_version) or data.schema_version != 1 or not data.finished is bool or not data.observed is bool or not _integer(data.session_days) or data.session_days < 1:
		return _fail("七天结算账本版本、状态或天数无效")
	if not data.subject_ids is Array or not data.daily_days is Dictionary or not data.exams is Dictionary or not data.final is Dictionary or not data.last_position is Dictionary:
		return _fail("七天结算账本容器类型无效")
	var expected_subjects: Array = []
	for subject_id: String in configuration.subjects:
		if configuration.subjects[subject_id].kind == "knowledge":
			expected_subjects.append(subject_id)
	if data.subject_ids != expected_subjects or data.session_days != int(configuration.global_value("session_days")):
		return _fail("七天账本科目或天数与当前配置不兼容")
	if not data.last_position.has_all(["day", "clock_seconds"]) or data.last_position.day != at_day or data.last_position.clock_seconds != seconds:
		return _fail("七天账本时刻与主存档不一致")
	if not data.recorded_through is Dictionary or not data.recorded_through.has_all(["day", "clock_seconds"]) or not _integer(data.recorded_through.day) or data.recorded_through.day < 0 or not _number(data.recorded_through.clock_seconds) or data.recorded_through.clock_seconds < 0.0 or data.recorded_through.clock_seconds >= 86400.0:
		return _fail("七天账本已观察边界无效")
	if not _integer(data.final_day) or data.final_day != data.session_days or not _number(data.final_seconds) or data.final_seconds <= 0.0 or data.final_seconds >= 86400.0:
		return _fail("七天账本终局边界无效")
	if data.daily_days.size() != data.session_days:
		return _fail("七天账本缺少日期或包含重复日期")
	var current_plan: Dictionary = _plan(configuration)
	for round_day: int in range(1, data.session_days + 1):
		if not data.daily_days.has(str(round_day)):
			return _fail("七天账本缺少第%s天" % round_day)
		var daily: Variant = data.daily_days[str(round_day)]
		if not daily is Dictionary or not daily.has_all(["day", "status", "start_seconds", "end_seconds", "source", "reason", "gains", "boards"]):
			return _fail("每日知识账本字段缺失")
		if daily.day != round_day or daily.status not in ["pending", "published", "unrecorded"] or not daily.source is String or not daily.reason is String or not daily.gains is Dictionary or not daily.boards is Dictionary:
			return _fail("每日知识账本状态或类型无效")
		if daily.source not in ["online", "offline_frozen", "partial", "unrecorded"] or (daily.status == "published" and (daily.source == "unrecorded" or not data.observed)):
			return _fail("每日知识账本来源与状态矛盾")
		if not _number(daily.start_seconds) or not _number(daily.end_seconds) or daily.start_seconds < 0.0 or daily.start_seconds >= 86400.0 or daily.end_seconds <= 0.0 or daily.end_seconds >= 86400.0:
			return _fail("每日知识账本时间无效")
		if daily.gains.size() != participants.size():
			return _fail("每日知识账本角色记录缺失")
		for student: Dictionary in participants:
			if not daily.gains.has(student.id) or not daily.gains[student.id] is Dictionary or daily.gains[student.id].size() != data.subject_ids.size():
				return _fail("每日知识账本角色或科目增量缺失")
			for subject_id: String in data.subject_ids:
				if not daily.gains[student.id].has(subject_id) or not _number(daily.gains[student.id][subject_id]) or daily.gains[student.id][subject_id] < 0.0 or daily.gains[student.id][subject_id] > student.knowledge[subject_id]:
					return _fail("每日知识增量无效或超出真实累计知识")
		if daily.status == "published":
			if not _at_or_before(round_day, daily.end_seconds, int(data.recorded_through.day), data.recorded_through.clock_seconds):
				return _fail("已公布日榜晚于真实记录边界")
			if daily.boards.size() != data.subject_ids.size():
				return _fail("已公布日榜缺少科目")
			for subject_id: String in data.subject_ids:
				if not daily.boards.has(subject_id) or not _valid_daily_rows(daily.boards[subject_id], daily, subject_id, participants):
					return _fail("已公布日榜与真实知识增量或并列名次不一致")
		elif not daily.boards.is_empty():
			return _fail("未公布日榜包含伪造结果")
		if daily.status == "unrecorded" and daily.reason.is_empty():
			return _fail("缺失日榜必须明确说明原因")
		if data.observed and daily.status == "pending" and _before(round_day, daily.end_seconds, at_day, seconds):
			return _fail("已过出榜时刻的新版日榜不能仍为pending")
		if fingerprint == configuration.fingerprint and daily.status == "pending" and daily.end_seconds != current_plan.cutoffs[str(round_day)]:
			return _fail("待处理日榜边界与存档原课表矛盾")
	if data.exams.size() != data.subject_ids.size():
		return _fail("考试账本科目缺失或重复")
	for subject_id: String in data.subject_ids:
		if not data.exams.has(subject_id) or not data.exams[subject_id] is Dictionary:
			return _fail("考试账本缺少科目")
		var exam: Dictionary = data.exams[subject_id]
		if not exam.has_all(["day", "subject_id", "start_seconds", "end_seconds", "status", "source", "reason", "rows"]) or exam.subject_id != subject_id or exam.status not in ["pending", "snapshot", "published", "unrecorded"] or not exam.rows is Array or not exam.source is String or not exam.reason is String:
			return _fail("考试账本字段或状态无效")
		if not _integer(exam.day) or exam.day < 1 or exam.day > data.session_days or not _number(exam.start_seconds) or not _number(exam.end_seconds) or exam.start_seconds < 0.0 or exam.end_seconds < exam.start_seconds or exam.end_seconds >= 86400.0:
			return _fail("考试账本时间无效")
		if exam.source not in ["online", "offline_frozen", "unrecorded", "legacy_unrecorded", "debug_unrecorded"] or (exam.status in ["snapshot", "published"] and (exam.source not in ["online", "offline_frozen"] or not data.observed)):
			return _fail("考试账本来源与状态矛盾")
		if exam.status in ["snapshot", "published"]:
			var required_seconds: float = exam.end_seconds if exam.status == "published" else exam.start_seconds
			if not _at_or_before(int(exam.day), required_seconds, int(data.recorded_through.day), data.recorded_through.clock_seconds):
				return _fail("考试快照或已公布成绩晚于真实记录边界")
			if exam.rows.size() != participants.size() or not _valid_exam_rows(exam.rows, subject_id, participants):
				return _fail("考试快照来源、成绩或名次不一致：%s" % subject_id)
		elif not exam.rows.is_empty():
			return _fail("未开考或缺失考试不得包含默认成绩")
		if exam.status == "unrecorded" and exam.reason.is_empty():
			return _fail("缺失考试必须明确说明原因")
		if data.observed and exam.status == "pending" and _before(int(exam.day), exam.start_seconds, at_day, seconds):
			return _fail("已过开考时刻的新版考试不能仍为pending")
		if data.observed and exam.status == "snapshot" and _before(int(exam.day), exam.end_seconds, at_day, seconds):
			return _fail("已过公布时刻的新版考试不能仍为snapshot")
		var uses_current_timing: bool = exam.status == "pending" or (not exam.rows.is_empty() and exam.rows[0].config_fingerprint == configuration.fingerprint)
		if fingerprint == configuration.fingerprint and uses_current_timing:
			var timing: Dictionary = current_plan.exams[subject_id]
			if exam.day != timing.day or exam.start_seconds != timing.start_seconds or exam.end_seconds != timing.end_seconds:
				return _fail("考试快照时刻与其来源课表矛盾")
	if not data.final.has_all(["status", "reason", "rows", "missing_subjects"]) or data.final.status not in ["pending", "published", "incomplete"] or not data.final.reason is String or not data.final.rows is Array or not data.final.missing_subjects is Array:
		return _fail("最终榜字段或状态无效")
	if data.finished:
		if not data.observed:
			return _fail("未观察到事件的账本不能标为已结束")
		var calculated: Dictionary = _calculate_final()
		if calculated.has("error") or not _same(data.final, calculated) or at_day != data.final_day or seconds != data.final_seconds:
			return _fail("最终榜与已公布单科或终局时刻不一致")
	elif data.final.status != "pending" or not data.final.rows.is_empty() or not data.final.missing_subjects.is_empty():
		return _fail("未结束局含有伪造的最终榜")
	elif data.observed and _before(int(data.final_day), data.final_seconds, at_day, seconds):
		return _fail("已过终局边界的新版账本不能仍为进行中")
	return _validate_frozen(participants, at_day, seconds, fingerprint)


## 单独保留已处理事件的最远边界，开发回退时钟不会使真实历史变成未来伪造记录。
func _record_position(at_day: int, seconds: float) -> void:
	if _before(int(data.recorded_through.day), data.recorded_through.clock_seconds, at_day, seconds):
		data.recorded_through = {"day": at_day, "clock_seconds": seconds}


## 日榜必须恰好包含四名真实角色，并与已保存增量及竞争排名完全对应。
func _valid_daily_rows(value: Variant, daily: Dictionary, subject_id: String, participants: Array) -> bool:
	if not value is Array or value.size() != participants.size():
		return false
	for row: Variant in value:
		if not row is Dictionary or not row.has("rank") or not _integer(row.rank):
			return false
	var expected: Array[Dictionary] = []
	for student: Dictionary in participants:
		expected.append({"student_id": student.id, "name": student.name, "knowledge": daily.gains[student.id][subject_id]})
	return _same(value, _rank(expected, "knowledge"))


## 逐行按快照自身参数复算，不用当前热更新参数覆盖历史公式。
func _valid_exam_rows(rows: Array, subject_id: String, participants: Array) -> bool:
	var names: Dictionary = {}
	for student: Dictionary in participants:
		names[student.id] = student.name
	var found: Array = []
	var previous_units: int = 0
	var rank_value: int = 0
	for index: int in rows.size():
		var row: Variant = rows[index]
		if not row is Dictionary or not row.has_all(["student_id", "name", "rank", "config_fingerprint", "config_version"]) or not names.has(row.student_id) or row.student_id in found or not row.name is String or row.name != names[row.student_id] or not row.config_fingerprint is String or row.config_fingerprint.is_empty() or not row.config_version is String:
			return false
		found.append(row.student_id)
		var result: Dictionary = scoring.calculate_subject(row)
		if result.error != OK or result.result.subject_id != subject_id:
			return false
		for key: String in result.result:
			if not row.has(key) or (row[key] != result.result[key] if key == "score_units" else not _same(row[key], result.result[key])):
				return false
		if index > 0:
			for key: String in ["max_score", "score_scale", "exam_intelligence_coefficient", "score_decimal_places", "config_fingerprint", "config_version"]:
				if not _same(row[key], rows[0][key]):
					return false
		if index > 0 and row.score_units > previous_units:
			return false
		if index == 0 or row.score_units != previous_units:
			rank_value = index + 1
		if not _integer(row.rank) or row.rank != rank_value:
			return false
		previous_units = int(row.score_units)
	return true


## 冻结知识必须对应主存档；有效智力和参数在原配置未变时进一步交叉检查。
func _validate_frozen(participants: Array, at_day: int, seconds: float, fingerprint: String) -> Error:
	var frozen: Variant = data.frozen
	if not frozen is Dictionary or not frozen.has_all(["day", "clock_seconds", "students", "parameters", "config_fingerprint", "config_version"]) or frozen.day != at_day or frozen.clock_seconds != seconds or frozen.config_fingerprint != fingerprint or not frozen.config_version is String or not frozen.students is Array or not frozen.parameters is Dictionary:
		return _fail("v4存档冻结快照缺失或时刻、指纹不一致")
	if frozen.students.size() != participants.size() or frozen.parameters.size() != data.subject_ids.size():
		return _fail("v4存档冻结角色或计分参数不完整")
	for index: int in participants.size():
		var saved: Variant = frozen.students[index]
		var student: Dictionary = participants[index]
		if not saved is Dictionary or not saved.has_all(["id", "name", "knowledge", "effective_intelligence"]) or saved.id != student.id or saved.name != student.name or not saved.knowledge is Dictionary or not _same(saved.knowledge, student.knowledge) or not _number(saved.effective_intelligence):
			return _fail("v4存档冻结知识、角色或有效智力无效")
		if fingerprint == configuration.fingerprint and not _same(saved.effective_intelligence, student.effective_intelligence):
			return _fail("v4存档冻结有效智力与原配置角色状态不一致")
	for subject_id: String in data.subject_ids:
		if not frozen.parameters.has(subject_id) or not frozen.parameters[subject_id] is Dictionary:
			return _fail("v4存档冻结计分参数缺少科目")
		var parameters: Dictionary = frozen.parameters[subject_id]
		if not parameters.has_all(["max_score", "score_scale", "exam_intelligence_coefficient", "score_decimal_places", "config_fingerprint", "config_version"]) or parameters.config_fingerprint != fingerprint or parameters.config_version != frozen.config_version:
			return _fail("v4存档冻结计分参数指纹或版本无效")
		var snapshot: Dictionary = parameters.duplicate(true)
		snapshot.merge({"subject_id": subject_id, "knowledge": 0.0, "effective_intelligence": 0.0}, true)
		var result: Dictionary = scoring.calculate_subject(snapshot)
		if result.error != OK:
			return _fail("v4存档冻结计分参数无效：%s" % scoring.error_message)
		if fingerprint == configuration.fingerprint and not _same(parameters, _parameters(subject_id)):
			return _fail("v4存档冻结计分参数与原配置不一致")
	return OK


## JSON数字解析可能产生数个机器精度的误差，浮点仅容许表示误差，成绩整数始终精确比较。
func _same(left: Variant, right: Variant) -> bool:
	if _number(left) and _number(right):
		if left is int and right is int:
			return left == right
		return absf(float(left) - float(right)) <= maxf(absf(float(left)), absf(float(right))) * 8.881784197001252e-16
	if left is Dictionary and right is Dictionary:
		if left.size() != right.size():
			return false
		for key: Variant in left:
			if not right.has(key) or (left[key] != right[key] if key == "score_units" else not _same(left[key], right[key])):
				return false
		return true
	if left is Array and right is Array:
		if left.size() != right.size():
			return false
		for index: int in left.size():
			if not _same(left[index], right[index]):
				return false
		return true
	return typeof(left) == typeof(right) and left == right


## 递归编码只转换明确命名的成绩整数，不改知识、资源或其他权威数值。
func _encode(value: Variant) -> Variant:
	if value is Dictionary:
		var result: Dictionary = {}
		for key: Variant in value:
			result[key] = str(value[key]) if key == "score_units" else _encode(value[key])
		return result
	if value is Array:
		var result: Array = []
		for entry: Variant in value:
			result.append(_encode(entry))
		return result
	return value


## 精确整数必须使用规范十进制字符串，错误表示明确拒绝而非强制截断。
func _decode(value: Variant) -> Variant:
	if value is Dictionary:
		var result: Dictionary = {}
		for key: Variant in value:
			if key == "score_units":
				var encoded_value: Variant = value[key]
				if not encoded_value is String or not encoded_value.is_valid_int() or str(int(encoded_value)) != encoded_value:
					_fail("v4存档成绩整数必须为可精确解析的int64十进制文本")
					return {}
				result[key] = int(encoded_value)
			else:
				result[key] = _decode(value[key])
		return result
	if value is Array:
		var result: Array = []
		for entry: Variant in value:
			result.append(_decode(entry))
		return result
	return value


## 时间比较始终使用局内日和当日秒，不把离线秒数加入在线累计时间。
func _before(left_day: int, left_seconds: float, right_day: int, right_seconds: float) -> bool:
	return left_day < right_day or (left_day == right_day and left_seconds < right_seconds)


## 边界恰好命中时也必须处理，不因advance(0)漏掉开考和终局。
func _at_or_before(left_day: int, left_seconds: float, right_day: int, right_seconds: float) -> bool:
	return left_day < right_day or (left_day == right_day and left_seconds <= right_seconds)


## 文件数字只接受有限数值，拒绝字符串和布尔值。
func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


## 局内日和计数必须原样为整数，不以截断修复损坏数据。
func _integer(value: Variant) -> bool:
	return _number(value) and value == int(value)


## 失败消息交回模拟器的统一恢复链，不替换已经有效的账本。
func _fail(message: String) -> Error:
	error_message = message
	return ERR_INVALID_DATA
