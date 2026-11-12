class_name ClassroomSimulation
extends RefCounted
## 本地班级的权威规则入口；行为树和界面都只能通过这里改变动作。

const ConfigScript = preload("res://scripts/core/game_config.gd")
const ROUND = preload("res://scripts/core/round_progression.gd")
const ATTRIBUTE_KEYS: Array[String] = ["attention", "discipline", "health", "intelligence"]
# NPC日志用的属性中文名，与界面ATTRIBUTE_NAMES保持一致。
const ATTRIBUTE_DISPLAY_NAMES: Dictionary = {"attention": "专注力", "discipline": "自律性", "health": "健康", "intelligence": "智力"}
# v6新增每日属性点发放记录与NPC轮换游标，v5的教师与抽查状态继续原样迁移。
const SAVE_VERSION: int = 6
const DAILY_COURSE_ACTIONS: Array[String] = ["study", "physical_study", "music_class", "art_class", "exam"]
# 持续互动的实现范围独立于自主候选，开放玩家入口不会让同学自动发起。
const PAIR_ACTIONS: Array[String] = [
	"send_note", "eraser_prank", "remind_friend", "solve_together",
	"invite_playground", "invite_canteen", "borrow_notes", "encourage",
	"pillow_fight", "feed_snack", "use_eraser", "give_comic_item",
	"give_candy_item", "swap_book", "swap_book_boost", "arm_wrestle",
	"answer_challenge", "study_together", "roommate_game",
	"take_comic", "prank_together",
]
# Godot整型的表示边界，仅用于防止数量溢出为负数，不限制背包格数或业务容量。
const MAX_ITEM_INTEGER: int = 9223372036854775807

# 四人的状态分别创建，不能共享当前动作、资源或知识字典。
var students: Array[Dictionary] = []
var config: RefCounted
var phase_scope: Dictionary = {}
var rng := RandomNumberGenerator.new()
var decision_handler: Callable
# 接管过程中只登记旧搭档；统一填充时按原策略回课表，不递归发起新一轮竞争。
var schedule_returns: Array[int] = []
# 填充期间提交新互动只登记后续空位，防止再次递归进入同一棵行为树。
var filling_actions: bool = false
var logs: Array[Dictionary] = []
var error_message: String = ""
var day: int = 1
var clock_seconds: float = 0.0
var elapsed_s: float = 0.0
var created_date: String = ""
var is_debug_time: bool = false
var next_action_number: int = 1
# 互动历史、已送达聊天及连续违纪由同一执行器持有，画面不能制造完成结果。
var interactions: Array[Dictionary] = []
var notes: Array[Dictionary] = []
var violations: Array[Dictionary] = []
var next_interaction_number: int = 1
var next_violation_number: int = 1
# 七天账本不拥有第二套角色状态，所有知识增量只来自本执行器的真实积分。
var round_progression: RefCounted
# 教师/主任花名册来自阶段范围，运行期只读；不出现在学生状态里。
var teachers: Array[Dictionary] = []
# 抽查状态：独立随机流、下次检查点、冷却、主任可见截止时刻与最近一次结果。
var inspection: Dictionary = {}
# 抽查独立随机流，避免消耗四人共用随机流而改变动作抽取结果。
var inspection_rng := RandomNumberGenerator.new()
# 抢答自主检查点独立随机流与扫描状态：课内上课无行为树决策点，由检查点驱动NPC尝试抢答。
var challenge_rng := RandomNumberGenerator.new()
var challenge_auto: Dictionary = {}
# 课间磨蹭独立随机流与已处理课间标记：每个课间时段只判定一次，读档后沿同一随机流继续。
var linger_rng := RandomNumberGenerator.new()
var linger_auto: Dictionary = {}
# 特殊事件独立随机流：触发概率、事件/学生/同学抽取与NPC选择全部走ambient流；每日至多1个事件。
var event_rng := RandomNumberGenerator.new()
var event_auto: Dictionary = {}
# 事件历史：事件名、选项、归属者与实际结算摘要，入存档并在日志页展示。
var events_log: Array[Dictionary] = []
# 每日属性点：已发放日集合（升序）保证幂等；NPC轮换游标；08:00换算后的当日秒数。
var daily_points: Dictionary = {}
var npc_growth: Dictionary = {}
var daily_point_clock: float = 0.0
# NPC每日加点轮换顺序：不抽随机，保证同种子结果可复现。
const NPC_GROWTH_CYCLE: Array[String] = ["attention", "discipline", "health", "intelligence"]


## 建立新局的真实状态；行为树接入后由advance(0)开始首次自主决策。
func setup(game_config: RefCounted, random_seed: int = 0, scope_path: String = "res://config/phase_scope.json") -> Error:
	config = game_config
	error_message = ""
	var file := FileAccess.open(scope_path, FileAccess.READ)
	if file == null:
		return _fail("无法读取阶段范围：%s" % scope_path)
	var parser := JSON.new()
	if parser.parse(file.get_as_text()) != OK or not parser.data is Dictionary:
		return _fail("阶段范围JSON格式错误")
	phase_scope = parser.data
	if not phase_scope.get("enabled_actions") is Array or not phase_scope.get("auto_actions") is Array:
		return _fail("阶段范围必须声明enabled_actions和auto_actions数组")
	var result: Error = _validate_scope()
	if result != OK:
		return result
	config.phase_scope = phase_scope
	if random_seed == 0:
		rng.randomize()
	else:
		rng.seed = random_seed
	# 教师花名册与抽查参数在setup内一次性落到运行态，之后只读。
	result = _apply_scope_characters()
	if result != OK:
		return result
	var now: Dictionary = Time.get_datetime_dict_from_system()
	created_date = "%04d-%02d-%02d" % [now.year, now.month, now.day]
	day = 1
	clock_seconds = now.hour * 3600.0 + now.minute * 60.0 + now.second
	elapsed_s = 0.0
	is_debug_time = false
	next_action_number = 1
	next_interaction_number = 1
	next_violation_number = 1
	students.clear()
	schedule_returns.clear()
	filling_actions = false
	logs.clear()
	interactions.clear()
	notes.clear()
	violations.clear()
	var names: Array[String] = ["我", "小林", "小陈", "小周"]
	for index in 4:
		var knowledge: Dictionary = {}
		for subject_id in config.subjects:
			if config.subjects[subject_id].kind == "knowledge":
				knowledge[subject_id] = 0.0
		students.append({
			"id": "student_%s" % index, "name": names[index],
			"focus": float(config.global_value("initial_focus")), "stamina": float(config.global_value("initial_stamina")),
			"attributes": {"attention": 0.0, "discipline": 0.0, "health": 0.0, "intelligence": 0.0},
			"unspent_points": int(config.global_value("initial_attribute_points")),
			"knowledge": knowledge, "inventory": {}, "buffs": [], "current_action": {},
			# 当日纪律分：每天从基准值重置，教导主任抽查抓到不在教室时扣减。
			"daily_discipline": float(_inspection_setting("daily_base")), "daily_discipline_day": 1,
			# 保存全部已领日期，开发时钟回退后仍能识别曾领过的日子。
			"daily_item_claim_days": [],
			# 特殊事件：待玩家选择的事件与下一课间强制动作（课间补作业语义）。
			"pending_event": {}, "pending_forced_action": "",
		})
	# AI升级：本地占位假人用预设加点模拟未来真人，联机后由真人自己加点。玩家“我”保留待分配点。
	result = _apply_npc_builds()
	if result != OK:
		return result
	_log(-1, "session", "新班级开始，四名同学自主活动", {"config_version": config.version})
	round_progression = ROUND.new()
	result = round_progression.setup(config, _round_participants(), day, clock_seconds)
	if result != OK:
		return _fail(round_progression.error_message)
	return OK


## AI升级：把占位假人的预设加点写入属性并清零其待分配点；已在边界校验过合法性。
func _apply_npc_builds() -> Error:
	for index: int in range(1, students.size()):
		var build: Dictionary = config.indexes.npc_attributes[students[index].id]
		for attribute_id: String in ATTRIBUTE_KEYS:
			students[index].attributes[attribute_id] = float(build[attribute_id])
		students[index].unspent_points = 0
	return OK


## 从阶段范围装载教师花名册与抽查参数；参数已在_validate_scope校验，这里只建立运行态。
func _apply_scope_characters() -> Error:
	teachers.clear()
	for row: Variant in phase_scope.teachers:
		teachers.append((row as Dictionary).duplicate(true))
	# 抽查使用独立随机流，种子由主随机流种子派生，不消耗也不改变四人共用随机流。
	inspection_rng.seed = int(rng.seed) ^ 0x5DEECE66D
	inspection = {
		"rng_state": str(inspection_rng.state),
		"next_check_elapsed": float(_inspection_setting("check_interval_seconds")),
		"cooldown_until_elapsed": 0.0,
		"visible_until_elapsed": -1.0,
		"last": {},
	}
	# 抢答自主检查点同样走独立随机流：课内上课动作没有行为树决策点，只能由检查点窗口驱动。
	challenge_rng.seed = int(rng.seed) ^ 0x2FCB4C67
	challenge_auto = {
		"rng_state": str(challenge_rng.state),
		"next_check_elapsed": float(config.global_value("answer_challenge_check_seconds")),
	}
	# 课间磨蹭独立随机流：课间开始统一判定一次，handled_key防止同一课间重复触发。
	linger_rng.seed = int(rng.seed) ^ 0x1D872B41
	linger_auto = {
		"rng_state": str(linger_rng.state),
		"handled_key": "",
	}
	# 特殊事件独立随机流：handled_key防止同一时刻重复判定，fired_day实现每日至多1个。
	event_rng.seed = int(rng.seed) ^ 0x6E774B57
	event_auto = {
		"rng_state": str(event_rng.state),
		"handled_key": "",
		"fired_day": 0,
	}
	events_log.clear()
	# 每日属性点在setup时解析一次发放时刻，格式非法直接失败，不在推进中反复猜测。
	var time_text: String = String(config.global_value("daily_attribute_time"))
	var parts: PackedStringArray = time_text.split(":")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return _fail("每日发点时间必须是HH:MM格式：%s" % time_text)
	var hour: int = int(parts[0])
	var minute: int = int(parts[1])
	if hour < 0 or hour > 23 or minute < 0 or minute > 59:
		return _fail("每日发点时间超出当日范围：%s" % time_text)
	daily_point_clock = float(hour * 3600 + minute * 60)
	daily_points = {"granted_days": []}
	npc_growth = {"cursor": 0}
	return OK


## 抽查参数的唯一读取入口，禁止在各处复制默认值。
func _inspection_setting(key: String) -> Variant:
	return phase_scope.inspection[key]


## 当前文化课的任课老师；非文化课或未匹配时返回空字典。
func teacher_on_duty() -> Dictionary:
	var context: Dictionary = course_context()
	if context.kind != "lesson" or not _is_cultural_subject(context.subject_id):
		return {}
	for teacher: Dictionary in teachers:
		if teacher.subject_id == context.subject_id:
			return teacher.duplicate(true)
	return {}


## 教导主任是否仍在教室内（抽查后按配置的可见时长短暂停留）。
func dean_is_visible() -> bool:
	return elapsed_s < float(inspection.visible_until_elapsed)


## 主任在场景中的显现比例：1为刚出现，0为即将消失，供UI做起止淡入淡出。
func dean_visibility_ratio() -> float:
	var span: float = float(_inspection_setting("visible_seconds"))
	return clampf((float(inspection.visible_until_elapsed) - elapsed_s) / span, 0.0, 1.0)


## 逐段扫描抽查检查点；只有文化课、冷却结束且独立随机流命中时才真正抽查。
func _run_inspection_window(start_day: int, start_clock: float, start_elapsed: float, end_elapsed: float, context: Dictionary) -> Error:
	var interval: float = float(_inspection_setting("check_interval_seconds"))
	while float(inspection.next_check_elapsed) < end_elapsed:
		var checkpoint: float = float(inspection.next_check_elapsed)
		inspection.next_check_elapsed = checkpoint + interval
		if checkpoint < start_elapsed:
			continue
		if context.kind != "lesson" or not _is_cultural_subject(context.subject_id):
			continue
		if checkpoint < float(inspection.cooldown_until_elapsed):
			continue
		if inspection_rng.randf() >= float(_inspection_setting("chance")):
			continue
		var when: Dictionary = _window_time(start_day, start_clock, start_elapsed, checkpoint)
		_run_inspection(int(when.day), float(when.clock_seconds), end_elapsed)
	# 抽查状态随分段同步，保证读档后继续沿同一随机流推进。
	inspection.rng_state = str(inspection_rng.state)
	return OK


## 逐段扫描抢答自主检查点；只查文化课，命中的NPC等权抽取可抢答的同学真实发起。
## 段开始处处理到期的抢答检查点；发起时刻固定为段起点，保证大步与小步推进产生同一时间账。
func _run_challenge_checkpoints(context: Dictionary) -> Error:
	var chance: float = float(config.global_value("answer_challenge_auto_chance"))
	# 大步推进可能一次补处理多个到期检查点；检查点网格必须始终推进，否则段边界截断会失配。
	while float(challenge_auto.next_check_elapsed) <= elapsed_s:
		challenge_auto.next_check_elapsed = float(challenge_auto.next_check_elapsed) + float(config.global_value("answer_challenge_check_seconds"))
		# 抢答属于竞争自主社交：总开关关闭、自主池清空或非文化课时检查点空转，不消耗随机数。
		if float(config.global_value("social_auto_base")) <= 0.0 or "answer_challenge" not in phase_scope.social_auto_actions:
			continue
		if context.kind != "lesson" or not _is_cultural_subject(context.subject_id):
			continue
		for index in range(1, students.size()):
			# 正在互动中的NPC不再发起，避免自己打断自己的抢答。
			if not students[index].current_action.is_empty() and students[index].current_action.has("interaction_id"):
				continue
			# 每个空闲NPC固定消耗一次判定随机数，保证存档回放与在线推进消耗一致。
			if challenge_rng.randf() >= chance:
				continue
			var candidates: Array[int] = []
			for other in students.size():
				if other == index:
					continue
				if interaction_unavailable_reason(index, other, "answer_challenge", "").is_empty():
					candidates.append(other)
			if candidates.is_empty():
				continue
			# 命中后固定消耗一次目标抽取随机数；无候选也保持消耗次数稳定。
			var target: int = candidates[challenge_rng.randi() % candidates.size()]
			var when: Dictionary = {"day": day, "clock_seconds": clock_seconds}
			if start_interaction(index, target, "answer_challenge", "") != OK:
				# 候选校验与真实发动之间的并发冲突是显式边界：留放弃日志后继续推进。
				_log(index, "answer_challenge", "想发起抢答但对方状态已变化，本次放弃", {"day": when.day, "clock_seconds": when.clock_seconds, "target_index": target})
				error_message = ""
				continue
			_log(index, "answer_challenge", "主动发起了抢答", {"day": when.day, "clock_seconds": when.clock_seconds, "target_index": target})
	# 检查点随机流状态随段同步，保证读档后继续沿同一随机流推进。
	challenge_auto.rng_state = str(challenge_rng.state)
	return OK


## 课间磨蹭地点与动作映射：地点抽取命中后按现有动作执行，宿舍地点用课间专用的同效果动作。
const LINGER_BREAK_PLACES: Array[String] = ["linger_break", "playground_play", "eat_meal", "linger_dorm_rest"]
const LINGER_BREAK_PLACE_NAMES: Array[String] = ["教室", "操场", "食堂", "宿舍"]


## 课间开始时统一判定磨蹭：专注低于阈值乘上限后按概率触发，四地点等权抽取。
## 判定先标记已处理课间再消耗随机数，保证大步与小步推进消耗同一随机流序列。
func _run_linger_checkpoints(context: Dictionary) -> Error:
	var context_key: String = String(context.context_key)
	if context.kind != "break" or String(linger_auto.handled_key) == context_key:
		return OK
	linger_auto.handled_key = context_key
	var threshold: float = float(config.global_value("linger_break_focus_threshold"))
	var chance: float = float(config.global_value("linger_break_chance"))
	for index in students.size():
		var student: Dictionary = students[index]
		# 每个角色固定消耗一次判定随机数；命中后再消耗一次地点抽取，次数与结果无关保持一致。
		if linger_rng.randf() >= chance:
			continue
		if float(student.focus) >= get_resource_max(index, "focus") * threshold:
			continue
		var place: int = linger_rng.randi() % LINGER_BREAK_PLACES.size()
		var action_id: String = LINGER_BREAK_PLACES[place]
		if start_action(index, action_id, true, -1, "课间磨蹭") != OK:
			# 地点动作前置不满足（如资源耗尽）是显式边界：留放弃日志后继续课间。
			_log(index, "linger_break", "课间想去%s磨蹭但未能成行" % LINGER_BREAK_PLACE_NAMES[place], {"context_key": context_key, "action_id": action_id, "reason": error_message})
			error_message = ""
			continue
		_log(index, "linger_break", "课间去%s磨蹭" % LINGER_BREAK_PLACE_NAMES[place], {"context_key": context_key, "action_id": action_id})
	# 磨蹭随机流状态随段同步，保证读档后继续沿同一随机流推进。
	linger_auto.rng_state = str(linger_rng.state)
	return OK


## 事件触发点由段起点上下文决定：早晨挂第一节课起点（第2-7天），其余按课表时段。
func _event_trigger_for_context(context: Dictionary) -> String:
	match String(context.kind):
		"lesson":
			if String(context.period_id) == "lesson_1":
				if day >= 2:
					return "morning"
				return ""
			if String(context.subject_kind) == "knowledge":
				return "lesson_start"
		"break":
			return "break_start"
		"lunch":
			return "lunch"
		"outside":
			if clock_seconds >= 60000.0 and day <= int(config.global_value("session_days")) - 1:
				return "after_school"
	return ""


## 特殊事件检查点：每个段起点判定一次；概率命中后抽事件、归属者与同学目标。
func _run_event_checkpoints(context: Dictionary) -> Error:
	if not bool(config.global_value("events_enabled")):
		return OK
	var trigger_point := _event_trigger_for_context(context)
	var context_key := String(context.context_key)
	if trigger_point == "after_school":
		# 放学没有独立时段，用日键防重；第7天16:40为局末收束，不再触发。
		context_key = "%s/after_school" % day
	if trigger_point.is_empty() or String(event_auto.handled_key) == context_key:
		return OK
	event_auto.handled_key = context_key
	# 每日至多1个事件：当日已触发过则静默结束，不消耗抽取随机数。
	if int(event_auto.fired_day) == day:
		return OK
	# 概率判定、事件池、归属者与同学目标都走ambient流，顺序固定保证读档可复盘。
	if event_rng.randf() >= float(config.global_value("event_chance")):
		event_auto.rng_state = str(event_rng.state)
		return OK
	var pool: Array = config.events_by_trigger[trigger_point]
	var event_row: Dictionary = pool[event_rng.randi() % pool.size()]
	var owner_index: int = event_rng.randi() % students.size()
	var target_index: int = (owner_index + 1 + event_rng.randi() % (students.size() - 1)) % students.size()
	event_auto.fired_day = day
	event_auto.rng_state = str(event_rng.state)
	if owner_index == 0:
		# 玩家事件进入待选择状态：弹窗不暂停模拟，选择后由UI经resolve入口结算。
		students[0].pending_event = {"event_id": String(event_row.id), "target_index": target_index}
		_log(0, "event", "特殊事件待选择：%s" % String(event_row.name), {"event_id": String(event_row.id), "trigger_point": trigger_point})
		return OK
	# NPC事件：等权随机选一个选项并立即结算。
	var option_rows: Array = []
	for row in config.tables.event_options:
		if String(row.event_id) == String(event_row.id):
			option_rows.append(row)
	return _resolve_event_option(owner_index, event_row, option_rows[event_rng.randi() % option_rows.size()], target_index, "npc")


## 结算事件选项：效果只影响之后的结算；写入事件历史供日志页展示。
func _resolve_event_option(owner_index: int, event_row: Dictionary, option_row: Dictionary, target_index: int, resolver: String) -> Error:
	var effects: Array = config.effects_by_option[String(option_row.id)]
	for effect in effects:
		var recipients: Array[int] = []
		match String(effect.recipient):
			"self":
				recipients = [owner_index]
			"target":
				recipients = [target_index]
			"both":
				recipients = [owner_index, target_index]
		for index in recipients:
			match String(effect.type):
				"resource":
					if String(effect.resource) == "knowledge":
						var subject_id := String(course_context().get("subject_id"))
						if subject_id.is_empty():
							return _fail("事件知识效果缺少当前知识课程：%s" % String(effect.id))
						students[index].knowledge[subject_id] = float(students[index].knowledge[subject_id]) + float(effect.value)
					else:
						_change_resource(index, String(effect.resource), float(effect.value), true)
				"apply_buff":
					_apply_buff(index, String(effect.buff_id))
				"attribute_point":
					students[index].unspent_points = int(students[index].unspent_points) + int(effect.value)
				"give_item":
					students[index].inventory[String(effect.item_id)] = int(students[index].inventory.get(String(effect.item_id), 0)) + int(effect.value)
				"force_action":
					students[index].pending_forced_action = String(effect.action_id)
	var summary: String = ""
	for effect in effects:
		summary = summary + String(effect.description)
	events_log.append({
		"day": day, "clock_seconds": clock_seconds,
		"event_id": String(event_row.id), "event_name": String(event_row.name),
		"option_id": String(option_row.id), "option_name": String(option_row.name),
		"student_index": owner_index, "student_name": String(students[owner_index].name),
		"resolver": resolver, "summary": summary,
	})
	_log(owner_index, "event", "特殊事件[%s]：%s" % [String(event_row.name), String(option_row.name)], {"event_id": String(event_row.id), "option_id": String(option_row.id)})
	return OK


## 玩家待处理事件查询：弹窗不暂停模拟，选择前挂机照常推进。
func pending_event_for_player() -> Dictionary:
	if students.is_empty() or students[0].pending_event.is_empty():
		return {}
	var event_id := String(students[0].pending_event.event_id)
	if not config.indexes.events.has(event_id):
		return {}
	var definition: Dictionary = config.indexes.events[event_id]
	var options: Array = []
	for row in config.tables.event_options:
		if String(row.event_id) == event_id:
			options.append({"id": String(row.id), "name": String(row.name), "description": String(row.description)})
	return {
		"event_id": event_id, "name": String(definition.name), "description": String(definition.description),
		"target_index": int(students[0].pending_event.target_index), "options": options,
	}


## 玩家选择事件选项：一次结算后清除待处理状态；重复结算或外部选项被拒绝。
func resolve_pending_event(option_id: String) -> Error:
	if students[0].pending_event.is_empty():
		return _reject("当前没有待处理事件", ERR_UNAVAILABLE)
	var event_id := String(students[0].pending_event.event_id)
	var option_row: Dictionary = {}
	for row in config.tables.event_options:
		if String(row.id) == option_id and String(row.event_id) == event_id:
			option_row = row
			break
	if option_row.is_empty():
		return _reject("选项不属于当前待处理事件：%s" % option_id, ERR_UNAVAILABLE)
	var target_index := int(students[0].pending_event.target_index)
	students[0].pending_event = {}
	return _resolve_event_option(0, config.indexes.events[event_id], option_row, target_index, "player")


## 课间开始执行事件挂起的强制动作（课间补写笔记），沿用统一执行器；失败留放弃日志继续课间。
func _apply_pending_forced_actions(context: Dictionary) -> Error:
	if String(context.kind) != "break":
		return OK
	for index in students.size():
		var action_id := String(students[index].pending_forced_action)
		if action_id.is_empty():
			continue
		students[index].pending_forced_action = ""
		if not students[index].current_action.is_empty():
			var ended: Error = _end_action(index, false, "课间强制任务切换", -1, [])
			if ended != OK:
				return ended
		if start_action(index, action_id, false, -1, "事件安排的课间任务") != OK:
			_log(index, "event", "课间任务未能成行：%s" % String(config.actions[action_id].name), {"action_id": action_id, "reason": error_message})
			error_message = ""
			continue
		_log(index, "event", "课间开始%s" % String(config.actions[action_id].name), {"action_id": action_id})
	return OK


## 把窗口内的绝对经过秒换算成当日的天与时钟，避免跨段时间误差。
func _window_time(start_day: int, start_clock: float, start_elapsed: float, at_elapsed: float) -> Dictionary:
	var total: float = float(start_day - 1) * 86400.0 + start_clock + (at_elapsed - start_elapsed)
	var day_index: int = int(floor(total / 86400.0))
	return {"day": day_index + 1, "clock_seconds": total - float(day_index) * 86400.0}


## 执行一次真实抽查：不在教室的学生扣当日纪律分，并记录主任到访事件。
func _run_inspection(at_day: int, at_clock: float, end_elapsed: float) -> void:
	var deduction: float = float(_inspection_setting("deduction"))
	var found: Array[Dictionary] = []
	for index in students.size():
		var location: String = student_location(index)
		if location == "classroom":
			continue
		found.append({"student_id": students[index].id, "name": students[index].name, "location": location})
		students[index].daily_discipline = maxf(0.0, float(students[index].daily_discipline) - deduction)
		students[index].daily_discipline_day = at_day
	inspection.cooldown_until_elapsed = end_elapsed + float(_inspection_setting("cooldown_seconds"))
	inspection.visible_until_elapsed = end_elapsed + float(_inspection_setting("visible_seconds"))
	inspection.last = {"day": at_day, "clock_seconds": at_clock, "deduction": deduction, "found": found}
	for entry: Dictionary in found:
		_log(_student_index(entry.student_id), "inspection", "教导主任抽查时你不在教室，纪律分 -%d" % int(deduction), {"day": at_day, "clock_seconds": at_clock, "location": entry.location})
	if found.is_empty():
		_log(-1, "inspection", "教导主任抽查：全员在教室", {"day": at_day, "clock_seconds": at_clock})


## 按学生ID定位下标；调用方保证ID存在，找不到时直接失败暴露数据问题。
func _student_index(student_id: String) -> int:
	for index in students.size():
		if students[index].id == student_id:
			return index
	return -1


## 推进前兜底对齐当日：读档或开发时钟可能让纪律分天落后于当前天，此时按当天重置。
func _ensure_daily_discipline() -> void:
	for student: Dictionary in students:
		if int(student.daily_discipline_day) != day:
			_reset_daily_discipline()
			return


## 跨日把纪律分重置到基准值，避免沿用前一天的扣分。
func _reset_daily_discipline() -> void:
	var base: float = float(_inspection_setting("daily_base"))
	for student: Dictionary in students:
		student.daily_discipline = base
		student.daily_discipline_day = day


## 扫描推进窗口内的每日发点检查点（每天08:00）；幂等由granted_days保证，不抽随机。
func _run_attribute_window(start_day: int, start_clock: float, start_elapsed: float, end_elapsed: float) -> Error:
	var first_day: int = int(config.global_value("first_daily_attribute_day"))
	var start_abs: float = float(start_day - 1) * 86400.0 + start_clock
	# 窗口起点与检查点都以当日时钟直接比较，避免经过秒与跨日换算互相干扰。
	var span: float = end_elapsed - start_elapsed
	var last_day: int = int(floor((start_abs + span) / 86400.0)) + 1
	for grant_day in range(maxi(first_day, start_day), last_day + 1):
		var grant_clock: float = float(grant_day - 1) * 86400.0 + daily_point_clock
		if grant_clock < start_abs or grant_clock >= start_abs + span:
			continue
		if int(grant_day) in daily_points.granted_days:
			continue
		var granted: Error = _grant_daily_points(int(grant_day))
		if granted != OK:
			return granted
	return OK


## 离线补发入口：把当前时刻之前所有已错过且未发放的检查点一次性补上（八点后上线补点）。
func _catch_up_daily_points() -> Error:
	var first_day: int = int(config.global_value("first_daily_attribute_day"))
	var now_abs: float = float(day - 1) * 86400.0 + clock_seconds
	for grant_day in range(first_day, day + 1):
		var grant_clock: float = float(grant_day - 1) * 86400.0 + daily_point_clock
		if grant_clock > now_abs:
			break
		if grant_day in daily_points.granted_days:
			continue
		var granted: Error = _grant_daily_points(grant_day)
		if granted != OK:
			return granted
	return OK


## 每日发点：全员待分配点+1，NPC立即按固定轮换消费；写班级与个人真实日志。
func _grant_daily_points(grant_day: int) -> Error:
	var points: int = int(config.global_value("daily_attribute_points"))
	for student: Dictionary in students:
		student.unspent_points = int(student.unspent_points) + points
	daily_points.granted_days.append(grant_day)
	_log(-1, "attribute_points", "第%d天发放属性点+%d" % [grant_day, points], {"day": grant_day})
	# 学生0是玩家本人，保留待分配点由玩家自己消费；其余NPC按轮换立即分配。
	for index in range(1, students.size()):
		var attribute: String = NPC_GROWTH_CYCLE[int(npc_growth.cursor)]
		npc_growth.cursor = (int(npc_growth.cursor) + 1) % NPC_GROWTH_CYCLE.size()
		var student: Dictionary = students[index]
		var previous_value: float = float(student.attributes[attribute])
		var next_value: float = previous_value + float(points)
		if not is_finite(next_value) or next_value - previous_value != float(points):
			return _fail("NPC属性增长后的数值无效，发放中止于第%d天" % grant_day)
		student.attributes[attribute] = next_value
		student.unspent_points = int(student.unspent_points) - points
		_clamp_resources_after_max_change(index)
		_log(index, "attribute_points", "自动分配%s+%d" % [ATTRIBUTE_DISPLAY_NAMES[attribute], points], {"attribute_id": attribute, "amount": points, "day": grant_day})
	return OK


## 按实际经过秒数推进，并在动作、资源耗尽、课表和状态边界分段结算。
func advance(delta_s: float) -> Error:
	if not is_finite(delta_s) or delta_s < 0.0:
		return _fail("推进时间必须是非负有限秒数")
	if is_round_finished():
		return OK
	# 推进前先把纪律分对齐到当前日：读档/开发时钟可能留下前一天的值。
	_ensure_daily_discipline()
	# 推进前补发已错过的每日发点检查点（读档上线/时钟切换后的离线补点语义）。
	var caught_up: Error = _catch_up_daily_points()
	if caught_up != OK:
		return caught_up
	var result: Error = _process_round_position()
	if result != OK or is_round_finished():
		return result
	# 读档或调表后资源可能已耗尽，先显式结束旧活动，再接续已确认的宿舍休息。
	var initial_recovery: Array[int] = []
	result = _end_exhausted_dorm_actions(initial_recovery)
	if result != OK:
		return result
	result = _start_dorm_recovery(initial_recovery)
	if result != OK:
		return result
	result = _fill_missing_actions()
	if result != OK:
		return result
	var remaining: float = delta_s
	while remaining > 0.0:
		var old_context: Dictionary = course_context()
		# 抢答自主检查点在段开始处理：检查点已作为段边界，发起时刻=段起点，大步小步一致。
		result = _run_challenge_checkpoints(old_context)
		if result != OK:
			return result
		# 课间磨蹭在课间开始的第一个段起点判定一次，触发动作沿用统一执行器。
		result = _run_linger_checkpoints(old_context)
		if result != OK:
			return result
		# 特殊事件在早晨/知识课/课间/午休/放学段起点判定一次：概率抽取后按归属立即或挂起。
		result = _run_event_checkpoints(old_context)
		if result != OK:
			return result
		var interval: float = minf(remaining, old_context.end_seconds - clock_seconds)
		interval = minf(interval, round_progression.next_boundary(day, clock_seconds) - clock_seconds)
		# 抢答自主检查点同样是段边界：段在检查点处截止，下一段起点即检查点时刻。
		interval = minf(interval, float(challenge_auto.next_check_elapsed) - elapsed_s)
		for index in students.size():
			var student: Dictionary = students[index]
			interval = minf(interval, student.current_action.ends_at - elapsed_s)
			interval = minf(interval, _dorm_depletion_seconds(index))
			for buff in student.buffs:
				if buff.expires_at != null:
					interval = minf(interval, buff.expires_at - elapsed_s)
		if interval <= 0.0:
			return _fail("时间边界未被处理，不能继续推进：%s" % interval)
		# 分段内没有动作结束，位置视为常量；用段起点时间换算检查点，避免时钟越过午夜后失真。
		var segment_start_day: int = day
		var segment_start_clock: float = clock_seconds
		var segment_start_elapsed: float = elapsed_s
		for index in students.size():
			_settle_student(index, interval, old_context)
		result = _run_inspection_window(segment_start_day, segment_start_clock, segment_start_elapsed, elapsed_s + interval, old_context)
		if result != OK:
			return result
		# 每日属性点检查点与抽查检查点同窗扫描，发放只依赖真实时钟跨越。
		result = _run_attribute_window(segment_start_day, segment_start_clock, segment_start_elapsed, elapsed_s + interval)
		if result != OK:
			return result
		elapsed_s += interval
		clock_seconds += interval
		remaining -= interval
		if clock_seconds >= 86400.0:
			clock_seconds -= 86400.0
			day += 1
			_reset_daily_discipline()
		# 完成效果先于下一段决策发生，只有完整执行到结束的动作才能获得。
		var completion_routes: Array = []
		var dorm_recovery: Array[int] = []
		for index in students.size():
			# 完成判定带 ulp 容差：段长由ends_at反向截断，浮点累加可能比ends_at小不到百万分之一秒。
			if not students[index].current_action.is_empty() and students[index].current_action.ends_at <= elapsed_s + 1.0e-6:
				var completed_action: Dictionary = students[index].current_action
				# 互动创建的current_action没有恢复标记字段：pair宿舍动作完成走统一互动语义，不强制接续恢复。
				if config.actions[completed_action.action_id].eligible_period == "dorm_free" and not completed_action.get("dorm_recovery", false):
					dorm_recovery.append(index)
				result = _end_action(index, true, "动作完成", -1, completion_routes)
				if result != OK:
					return result
			_expire_buffs(index)
		result = _end_exhausted_dorm_actions(dorm_recovery)
		if result != OK:
			return result
		var new_context: Dictionary = course_context()
		if new_context.context_key != old_context.context_key:
			_log(-1, "course", "时段切换：%s" % _context_label(new_context), {"period_id": new_context.period_id})
			for index in students.size():
				if not students[index].current_action.is_empty():
					# 午夜仍在宿舍时按方案结束旧实例并休息，不把前一日活动暗中续到次日。
					if config.actions[students[index].current_action.action_id].eligible_period == "dorm_free" and new_context.kind in ["outside", "rest"] and index not in dorm_recovery:
						dorm_recovery.append(index)
					result = _end_action(index, false, "课表切换")
					if result != OK:
						return result
		result = _process_round_position()
		if result != OK or is_round_finished():
			return result
		# 后续指令在换课清理和终局判定之后接管，避免同刻刚启动就被清理或终局后消耗随机数。
		for route: Dictionary in completion_routes:
			var effect: Dictionary = route.effect
			var next_id: String = course_context().default_action_id if effect.next_action_id == "current_course" else effect.next_action_id
			result = start_action(route.student_index, next_id, effect.event == "natural_entry", route.student_index, "后续动作")
			if result != OK:
				return result
		result = _start_dorm_recovery(dorm_recovery)
		if result != OK:
			return result
		# 事件挂起的课间强制任务在课间开始、清理与终局判定之后落地，先于行为树补位。
		result = _apply_pending_forced_actions(new_context)
		if result != OK:
			return result
		result = _fill_missing_actions()
		if result != OK:
			return result
	return OK


## 已结束局仍可保存与查询，但不再推进角色或允许新玩法指令。
func is_round_finished() -> bool:
	return round_progression != null and not round_progression.data.is_empty() and round_progression.data.finished


## 日榜查询只返回独立副本，不结算、不发奖也不消耗随机流。
func get_daily_board(at_day: int, subject_id: String) -> Dictionary:
	return round_progression.daily_board(at_day, subject_id)


## 宿舍记录是总知识的来源明细，查询只返回副本，不再次发放收益。
func get_dorm_summary(at_day: int, student_index: int = 0) -> Dictionary:
	return round_progression.dorm_summary(at_day, students[student_index].id)


## 考试查询按知识科目或考试课程别名读取已经存在的权威记录。
func get_exam_board(subject_id: String) -> Dictionary:
	return round_progression.exam_board(subject_id)


## 最终榜明确区分待结算、完整公布和缺少历史，不用零分补科。
func get_final_board() -> Dictionary:
	return round_progression.final_board()


## 界面使用明确的局状态与账本终局边界控制操作和提示。
func get_round_summary() -> Dictionary:
	return {
		"status": "finished" if is_round_finished() else "active",
		"session_days": int(round_progression.data.session_days),
		"final_day": int(round_progression.data.final_day),
		"final_seconds": round_progression.data.final_seconds,
	}


## 有效智力只在开考或保存边界取值，查询历史成绩不会重读当前Buff。
func _round_participants(from_students: Array = []) -> Array:
	var participants: Array = []
	var source: Array = students if from_students.is_empty() else from_students
	for student: Dictionary in source:
		var intelligence: float = student.attributes.intelligence
		for instance: Dictionary in student.buffs:
			intelligence += config.buffs[instance.buff_id].intelligence_delta
		participants.append({"id": student.id, "name": student.name, "knowledge": student.knowledge.duplicate(true), "effective_intelligence": intelligence})
	return participants


## 事件顺序位于动作完成、状态到期和切课清理之后，下一次自主决策之前。
func _process_round_position(source: String = "online", frozen: Dictionary = {}) -> Error:
	var result: Error = round_progression.process_position(day, clock_seconds, _round_participants(), source, frozen)
	if result != OK:
		return _fail(round_progression.error_message)
	return _commit_round_events(round_progression.events)


## 已验证的纯事件统一写入业务日志，终局清理只取消尚未真实完成的动作。
func _commit_round_events(events: Array) -> Error:
	for event: Dictionary in events:
		_log(-1, event.type, {
			"exam_snapshot": "保存开考知识与有效智力快照", "exam_published": "考试成绩已公布",
			"daily_board": "当日知识榜已公布", "round_finished": "本局已结束，成绩与历史已冻结",
		}[event.type], event.duplicate(true))
	if is_round_finished():
		day = int(round_progression.data.final_day)
		clock_seconds = round_progression.data.final_seconds
		for index: int in students.size():
			if not students[index].current_action.is_empty():
				var result: Error = _end_action(index, false, "本局结束，取消尚未完成的效果")
				if result != OK:
					return result
			_sync_violation(index)
	return OK


## 返回当前课表上下文，非课时也有明确的默认休息动作和下一边界。
func course_context() -> Dictionary:
	return _context_at(day, clock_seconds)


## 快照校验与实时推进共用课表解析，不临时覆盖正在运行的班级时间。
func _context_at(at_day: int, at_seconds: float) -> Dictionary:
	var result: Dictionary = {
		"period_id": "outside", "period_name": "课外休息", "kind": "outside",
		"subject_id": "", "subject_name": "", "subject_kind": "", "default_action_id": "dorm_rest",
		"end_seconds": 86400.0, "context_key": "%s/outside" % at_day,
	}
	for period in config.periods:
		var start: float = roundf(period.start_time * 86400.0)
		var finish: float = roundf(period.end_time * 86400.0)
		if at_seconds < start:
			result.end_seconds = start
			return result
		if at_seconds >= finish:
			continue
		result.period_id = period.id
		result.period_name = period.name
		result.kind = period.kind
		result.default_action_id = period.default_action_id
		result.end_seconds = finish
		result.context_key = "%s/%s" % [at_day, period.id]
		if period.kind == "lesson":
			for row in config.tables.schedule:
				if int(row.day) == at_day and row.period_id == period.id:
					var subject: Dictionary = config.subjects[row.subject_id]
					result.subject_id = subject.id
					result.subject_name = subject.name
					result.subject_kind = subject.kind
					result.default_action_id = subject.default_action_id
					return result
			# 七天课程结束后不伪造新课程，仍按明确的课外活动处理。
			result.period_name = "本局课程已结束"
			result.kind = "outside"
			result.default_action_id = "dorm_rest"
		return result
	return result


## 行为树使用当前阶段允许且符合真实条件的开小差候选，权重按属性倾向修正后返回。
func get_auto_candidates(student_index: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var context: Dictionary = course_context()
	if context.subject_kind != "knowledge":
		return result
	# 单科覆盖只替换本阶段候选名单；返回副本并叠加属性倾向权重，不改动权威配表。
	var allowed: Array = phase_scope.subject_auto_actions.get(context.subject_id, phase_scope.auto_actions)
	for row in config.tables.auto_pool:
		if row.enabled and row.eligible_period == "knowledge_course" and row.action_id in allowed and can_start_action(student_index, row.action_id):
			var candidate: Dictionary = row.duplicate()
			candidate["weight"] = float(candidate["weight"]) * persona_factor(student_index, String(candidate["action_id"]))
			result.append(candidate)
	return result


## 自由时段和真实地点同时满足才允许宿舍活动，切镜头不会改变资格。
func is_dorm_free_time(student_index: int) -> bool:
	return not is_round_finished() and course_context().kind in ["outside", "rest"] and student_location(student_index) == "dorm"


## 宿舍六项只过滤真实前置条件；返回副本并叠加属性倾向权重，抽取与保底由选择入口处理。
func get_dorm_candidates(student_index: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not is_dorm_free_time(student_index):
		return result
	for row: Dictionary in config.tables.auto_pool:
		if row.eligible_period != "dorm_free" or not row.enabled or row.action_id not in phase_scope.dorm_auto_actions:
			continue
		var definition: Dictionary = config.actions[row.action_id]
		# 此处仅验证选科动作是否能执行；实际科目在候选抽中后由弱科选科决定。
		var subject_id: String = "chinese" if definition.knowledge_mode == "selected_subject" else ""
		var candidate: Dictionary = row.duplicate()
		candidate["weight"] = float(candidate["weight"]) * persona_factor(student_index, String(candidate["action_id"]))
		if bool(row.get("requires_same_scene_target", false)):
			# 宿舍双人活动按可参与同学逐个枚举候选；无同伴时本次不出候选。
			for target_index: int in students.size():
				if target_index == student_index:
					continue
				if can_start_interaction(student_index, target_index, String(row.action_id), subject_id):
					candidate["target_index"] = target_index
					result.append(candidate)
		elif can_start_action(student_index, row.action_id, true, subject_id):
			candidate["target_index"] = -1
			result.append(candidate)
	return result


## AI升级：返回某动作的属性倾向修正系数，全部取自已保存的权威属性与配表增益。
func persona_factor(student_index: int, action_id: String) -> float:
	var discipline: float = _attr_ratio(student_index, "discipline")
	var health: float = _attr_ratio(student_index, "health")
	var playful: float = 1.0 - discipline  # 贪玩 = 反向自律
	match action_id:
		"dorm_study", "dorm_practice":
			return 1.0 + config.global_value("g_study") * discipline
		"dorm_game":
			return 1.0 + config.global_value("g_game") * playful
		"dorm_workout", "playground_play":
			return 1.0 + config.global_value("g_workout") * health
		"daydream", "read_comic":
			return 1.0 + config.global_value("g_playful") * playful
		_:
			return 1.0


## AI升级：返回归一化到[0,1]的权威属性比例，防止状态加成使倾向系数变负或失控。
func _attr_ratio(student_index: int, attribute: String) -> float:
	var reference: float = config.global_value("personality_ref_attr")
	return clampf(effective_attribute(student_index, attribute) / reference, 0.0, 1.0)


## 并列最低科目全部返回，查询不抽随机数，选科时给予相同倾向。
func weak_subjects(student_index: int) -> Array[String]:
	var weakest: Array[String] = []
	var worst_value: float = INF
	# 先找真实最小值，再统一判断并列，避免遍历顺序放大连续积分末位误差。
	for subject_id: String in ["chinese", "math", "english"]:
		var value: float = float(students[student_index].knowledge[subject_id])
		worst_value = minf(worst_value, value)
	for subject_id: String in ["chinese", "math", "english"]:
		var value: float = float(students[student_index].knowledge[subject_id])
		# 只合并浮点累加的机器舍入误差；真实知识差仍决定弱科，不按显示精度比较。
		var rounding_error: float = 32.0 * 2.220446049250313e-16 * maxf(absf(value), absf(worst_value))
		if absf(value - worst_value) <= rounding_error:
			weakest.append(subject_id)
	return weakest


## AI升级：返回角色的当前累计总知识，用于竞争互动的“领先”度量。
func _total_knowledge(student_index: int) -> float:
	var total: float = 0.0
	for subject_id: Variant in students[student_index].knowledge:
		total += float(students[student_index].knowledge[subject_id])
	return total


## AI升级：自律性对开小差专注阈值的个性化下调；自律越高阈值越低，更晚走神。
func distraction_threshold(student_index: int) -> float:
	var base: float = config.global_value("distraction_focus_threshold")
	return base * (1.0 - config.global_value("k_threshold") * _attr_ratio(student_index, "discipline"))


## AI升级：按正权重做加权随机抽取，返回命中下标；总权重非正返回-1由调用方显式失败。
func _weighted_index(weights: Array[float]) -> int:
	var largest: float = 0.0
	for weight: float in weights:
		largest = maxf(largest, weight)
	if largest <= 0.0:
		return -1
	var total: float = 0.0
	for weight: float in weights:
		total += weight / largest
	var choice: float = float(rng.randi()) / 4294967296.0
	var cursor: float = 0.0
	for index: int in weights.size():
		cursor += weights[index] / largest
		if choice < cursor / total:
			return index
	_fail("加权随机抽取未命中合法候选，请检查权重数值")
	return -1


## 固定低于下限的项，再按原权重分配剩余概率；最终归一后仍满足保底。
func _weighted_with_floor(weights: Array[float], floor_prob: float) -> Array[float]:
	var largest: float = 0.0
	for weight: float in weights:
		largest = maxf(largest, weight)
	var adjusted: Array[float] = []
	var pending: Array[int] = []
	for weight: float in weights:
		adjusted.append(weight / largest)
		pending.append(pending.size())
	var remaining: float = 1.0
	while not pending.is_empty():
		var total: float = 0.0
		for index: int in pending:
			total += weights[index] / largest
		var fixed: Array[int] = []
		for index: int in pending:
			var probability: float = remaining * (weights[index] / largest) / total
			if probability < floor_prob:
				fixed.append(index)
		if fixed.is_empty():
			for index: int in pending:
				adjusted[index] = remaining * (weights[index] / largest) / total
			break
		# 每次固定至少一项，因此迭代由候选数量自然结束，不加人为轮数限制。
		for index: int in fixed:
			adjusted[index] = floor_prob
			remaining -= floor_prob
			pending.erase(index)
	return adjusted


## AI升级：宿舍活动选择——过滤可执行候选后做倾向加权+保底抽取。
## 宿舍活动完整选择：候选含双人动作目标；返回动作与目标，选科仍由决策点处理。
func select_dorm_option(student_index: int) -> Dictionary:
	var candidates: Array[Dictionary] = get_dorm_candidates(student_index)
	if candidates.is_empty():
		return {}
	var weights: Array[float] = []
	for candidate: Dictionary in candidates:
		weights.append(float(candidate["weight"]))
	var adjusted: Array[float] = _weighted_with_floor(weights, float(config.global_value("dorm_weight_floor")))
	var picked: int = _weighted_index(adjusted)
	if picked < 0:
		return {}
	return {"action_id": String(candidates[picked]["action_id"]), "target_index": int(candidates[picked]["target_index"])}


func select_dorm_action(student_index: int) -> String:
	# 兼容入口：只返回动作ID；双人目标由select_dorm_option完整给出且不重复消耗随机流。
	var option: Dictionary = select_dorm_option(student_index)
	return "" if option.is_empty() else String(option["action_id"])


## AI升级：课堂开小差选择——按属性倾向加权后的候选抽取。
func select_auto_action(student_index: int) -> String:
	var candidates: Array[Dictionary] = get_auto_candidates(student_index)
	if candidates.is_empty():
		return ""
	var weights: Array[float] = []
	for candidate: Dictionary in candidates:
		weights.append(float(candidate["weight"]))
	var picked: int = _weighted_index(weights)
	return "" if picked < 0 else String(candidates[picked]["action_id"])


## AI升级：自习/刷题选科——补弱科倾向加权+保底，弱科按当前累计知识量最低判定。
func select_cultural_subject(student_index: int) -> String:
	var subjects: Array[String] = ["chinese", "math", "english"]
	var weakest: Array[String] = weak_subjects(student_index)
	var weights: Array[float] = []
	for subject_id: String in subjects:
		weights.append((1.0 + config.global_value("g_weak")) if subject_id in weakest else 1.0)
	var adjusted: Array[float] = _weighted_with_floor(weights, float(config.global_value("dorm_weight_floor")))
	var picked: int = _weighted_index(adjusted)
	return "" if picked < 0 else subjects[picked]


## AI升级：竞争互动候选——挂机角色在知识课可发起的目标与动作，供领先加权选择。
func get_social_candidates(student_index: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var context: Dictionary = course_context()
	if context.subject_kind != "knowledge":
		return result
	for action_id: Variant in phase_scope.get("social_auto_actions", []):
		for target_index: int in students.size():
			if target_index == student_index:
				continue
			var subjects: Array[String] = [""]
			if action_id == "swap_book":
				subjects = _swap_subjects()
			# 枚举合法选科而不提前抽取；同一个动作/目标仍只占一个候选权重。
			var available_subjects: Array[String] = []
			for subject_id: String in subjects:
				if can_start_interaction(student_index, target_index, String(action_id), subject_id):
					available_subjects.append(subject_id)
			if not available_subjects.is_empty():
				result.append({"action_id": String(action_id), "target_index": target_index, "selected_subject_id": available_subjects[0], "subject_options": available_subjects})
	return result


## AI升级：竞争互动选择——按目标领先程度（总知识）加权随机，领先者更易被干扰。
func select_social_action(student_index: int) -> Dictionary:
	var options: Array[Dictionary] = get_social_candidates(student_index)
	if options.is_empty():
		return {}
	var max_knowledge: float = 0.0
	for option: Dictionary in options:
		max_knowledge = maxf(max_knowledge, _total_knowledge(int(option["target_index"])))
	var weights: Array[float] = []
	for option: Dictionary in options:
		var ratio: float = 0.0
		if max_knowledge > 0.0:
			ratio = _total_knowledge(int(option["target_index"])) / max_knowledge
		weights.append(1.0 + config.global_value("g_lead") * ratio)
	var picked: int = _weighted_index(weights)
	if picked < 0:
		return {}
	var selected: Dictionary = options[picked].duplicate(true)
	if selected.action_id == "swap_book":
		var subjects: Array = selected.subject_options
		selected.selected_subject_id = subjects[rng.randi_range(0, subjects.size() - 1)]
	selected.erase("subject_options")
	return selected


## AI升级：竞争互动发起概率——自律越低越爱干扰；决策点用共享随机流做一次性判定。
func should_initiate_social(student_index: int) -> bool:
	var base: float = config.global_value("social_auto_base")
	var playful: float = 1.0 - _attr_ratio(student_index, "discipline")
	var probability: float = base * (1.0 + config.global_value("g_game") * playful)
	return float(rng.randi()) / 4294967296.0 < probability


## 偷换课本只枚举不同于当前授课科目的文化课，抽取留给最终选择入口。
func _swap_subjects() -> Array[String]:
	var current: String = course_context().subject_id
	var options: Array[String] = []
	for subject_id: String in ["chinese", "math", "english"]:
		if subject_id != current:
			options.append(subject_id)
	return options


## 查询实际发动前置条件，不扣物、不消耗随机流，也不结束角色已有动作。
func action_unavailable_reason(student_index: int, action_id: String, natural_entry: bool = true, selected_subject_id: String = "") -> String:
	if is_round_finished():
		return "本局已结束，不能开始新动作"
	if student_index < 0 or student_index >= students.size():
		return "动作角色不存在"
	if action_id not in phase_scope.enabled_actions:
		return "这个动作尚未开放"
	var definition: Dictionary = config.actions[action_id]
	if not definition.enabled or definition.target != "self":
		return "这个个人动作尚未开放"
	if definition.kind != "duration":
		return "这个动作需要使用对应的瞬时指令入口"
	var context: Dictionary = course_context()
	if definition.eligible_period == "dorm_free" and not is_dorm_free_time(student_index):
		return "需要本人真实位于宿舍，且当前为宿舍自由活动时段"
	if definition.eligible_period == "break" and context.kind != "break":
		return "这个动作只在课间可用"
	if definition.knowledge_mode == "selected_subject":
		if not _is_cultural_subject(selected_subject_id):
			return "请选择语文、数学或英语"
	elif not selected_subject_id.is_empty():
		return "这个动作不需要选择科目"
	if definition.eligible_period == "dorm_free":
		for effect: Dictionary in config.phase_effects(action_id, "tick"):
			if effect.type == "resource" and effect.value < 0.0 and _condition_matches(effect.condition, natural_entry, context) and students[student_index][effect.resource] <= 0.0:
				return "%s耗尽，不能开始%s" % ["专注" if effect.resource == "focus" else "体力", definition.name]
	if action_id in ["study", "physical_study"] and context.subject_kind != "knowledge":
		return "当前时段没有可学习的知识课程"
	if action_id in ["music_class", "art_class", "exam"] and context.default_action_id != action_id:
		return "这个动作需要对应的当前课程"
	var costs: Dictionary = {"focus": 0.0, "stamina": 0.0}
	var items: Dictionary = {}
	for effect in config.phase_effects(action_id, "start"):
		if not _condition_matches(effect.condition, natural_entry, context):
			continue
		if effect.type == "resource":
			var value: float = _resource_effect_value(student_index, effect)
			if value < 0.0:
				costs[effect.resource] += -value
		elif effect.type == "consume_item":
			items[effect.item_id] = int(items.get(effect.item_id, 0)) + int(effect.value)
	for resource: String in costs:
		if students[student_index][resource] < costs[resource]:
			return "%s不足，发动需要%.2f" % ["专注" if resource == "focus" else "体力", costs[resource]]
	for item_id: String in items:
		var count: int = int(students[student_index].inventory.get(item_id, 0))
		if count < items[item_id]:
			return "%s不足，需要%d件，当前%d件" % [config.items[item_id].name, items[item_id], count]
	return ""


## 行为树和界面复用同一无副作用边界，不另建一套可用性规则。
func can_start_action(student_index: int, action_id: String, natural_entry: bool = true, selected_subject_id: String = "") -> bool:
	return action_unavailable_reason(student_index, action_id, natural_entry, selected_subject_id).is_empty()


## 创建持续动作实例；只在这里抽时长，手动指令和行为树都复用这一入口。
func start_action(student_index: int, action_id: String, natural_entry: bool = true, interrupted_by: int = -1, reason: String = "主动切换", selected_subject_id: String = "") -> Error:
	var unavailable: String = action_unavailable_reason(student_index, action_id, natural_entry, selected_subject_id)
	if not unavailable.is_empty():
		return _reject(unavailable, ERR_UNAVAILABLE)
	var definition: Dictionary = config.actions[action_id]
	var leaves_pair: bool = students[student_index].current_action.has("interaction_id")
	if leaves_pair:
		_queue_remaining_participants(student_index, [student_index])
	if not students[student_index].current_action.is_empty():
		var interrupted: Error = _end_action(student_index, false, reason, interrupted_by)
		if interrupted != OK:
			return interrupted
	var context: Dictionary = course_context()
	var duration: float = rng.randf_range(definition.duration_min_s, definition.duration_max_s)
	var instance: Dictionary = {
		"instance_id": next_action_number, "action_id": action_id, "started_at": elapsed_s,
		"ends_at": elapsed_s + duration, "duration_s": duration, "last_settled_at": elapsed_s,
		"subject_id": context.subject_id, "natural_entry": natural_entry, "resource_changes": {}, "knowledge_gain": 0.0,
	}
	# 科目是动作实例的权威选择；读档和后续积分直接使用，不从当前课程或UI猜测。
	if definition.knowledge_mode == "selected_subject":
		instance.subject_id = selected_subject_id
	elif definition.knowledge_mode == "fixed_subject":
		instance.subject_id = definition.knowledge_subject_id
	elif definition.eligible_period == "dorm_free":
		instance.subject_id = ""
	if definition.eligible_period == "dorm_free":
		# 必须休息和随机选中的休息使用同一动作，标记用于避免恢复结束后重复安排恢复。
		instance.dorm_recovery = false
	next_action_number += 1
	students[student_index].current_action = instance
	var result: Error = _apply_phase(student_index, action_id, "start", natural_entry)
	if result != OK:
		return result
	_log(student_index, "start", "开始%s" % definition.name, {"action_id": action_id, "duration_s": duration, "natural_entry": natural_entry, "subject_id": instance.subject_id})
	_sync_violation(student_index)
	result = _grant_daily_items(student_index, action_id, context)
	if result != OK:
		return result
	# 新动作先取得控制权，再让未参与的旧搭档回课表，旧结束不能覆盖新动作。
	if leaves_pair:
		return _fill_missing_actions()
	return OK


## 真实课程启动后按配表抽奖；先规划全部结果，再一并写入库存、领取日和随机流。
func _grant_daily_items(student_index: int, action_id: String, context: Dictionary) -> Error:
	var student: Dictionary = students[student_index]
	if context.kind != "lesson" or action_id != context.default_action_id or action_id not in DAILY_COURSE_ACTIONS or day in student.daily_item_claim_days:
		return OK
	var candidates: Array[Dictionary] = []
	for row in config.tables.drop_pool:
		if row.enabled and row.weight > 0.0:
			candidates.append(row)
	# 使用独立随机器规划，抽取失败不能留下半份物品、领取记录或已消耗的抽奖随机流。
	var draw_rng := RandomNumberGenerator.new()
	draw_rng.seed = rng.seed
	draw_rng.state = rng.state
	var draws: Array[Dictionary] = []
	var items: Dictionary = {}
	for draw_index in int(config.global_value("daily_item_draw_count")):
		var total_weight: float = 0.0
		for candidate in candidates:
			total_weight += candidate.weight
		# 使用左闭右开的单位区间，避免极小正权重乘法下溢或舍入到总权重右端点。
		var choice: float = float(draw_rng.randi()) / 4294967296.0
		var cursor: float = 0.0
		var selected_index: int = -1
		for index in candidates.size():
			cursor += candidates[index].weight
			if choice < cursor / total_weight:
				selected_index = index
				break
		if selected_index < 0:
			return _fail("每日物品第%d次抽取未命中奖池，请检查权重数值" % (draw_index + 1))
		var selected: Dictionary = candidates[selected_index]
		var quantity: int = int(selected.quantity)
		draws.append({"pool_id": selected.id, "item_id": selected.item_id, "quantity": quantity})
		if not items.has(selected.item_id):
			items[selected.item_id] = 0
		if items[selected.item_id] > MAX_ITEM_INTEGER - quantity:
			return _fail("每日物品%s的抽取总量超出整数可表示范围，未发放本次奖励" % selected.item_id)
		items[selected.item_id] += quantity
		if not config.global_value("daily_item_with_replacement"):
			candidates.remove_at(selected_index)
	# 全部物品的入库数量先校验完，再替换权威库存，避免后一个溢出时前一个已入库。
	var inventory_after: Dictionary = student.inventory.duplicate()
	var summary := PackedStringArray()
	for item_id in items:
		var previous_count: int = int(student.inventory[item_id]) if student.inventory.has(item_id) else 0
		if previous_count > MAX_ITEM_INTEGER - items[item_id]:
			return _fail("物品%s入库后超出整数可表示范围，未发放本次奖励" % item_id)
		inventory_after[item_id] = previous_count + items[item_id]
		summary.append("%s × %d" % [config.items[item_id].name, items[item_id]])
	student.inventory = inventory_after
	student.daily_item_claim_days.append(day)
	student.daily_item_claim_days.sort()
	rng.state = draw_rng.state
	_log(student_index, "daily_items", "首次上课获得：" + "、".join(summary), {
		"claim_day": day, "action_id": action_id, "draws": draws, "items": items,
	})
	return OK


## 无副作用地给出互动不可用原因，界面和实际提交共用这一边界。
func interaction_unavailable_reason(initiator_index: int, target_index: int, action_id: String, selected_subject_id: String = "") -> String:
	if is_round_finished():
		return "本局已结束，不能发起新互动"
	if initiator_index < 0 or initiator_index >= students.size() or target_index < 0 or target_index >= students.size():
		return "互动对象不存在"
	if initiator_index == target_index:
		return "请选择另一位同学"
	if action_id not in PAIR_ACTIONS or action_id not in phase_scope.enabled_actions or not config.actions[action_id].enabled:
		return "这个互动尚未开放"
	var definition: Dictionary = config.actions[action_id]
	if definition.scene not in ["any", "course"] and (student_location(initiator_index) != definition.scene or student_location(target_index) != definition.scene):
		return "双方都在%s时才能%s" % [{"classroom": "教室", "playground": "操场", "canteen": "食堂", "dorm": "宿舍"}[definition.scene], definition.name]
	if action_id in ["swap_book", "swap_book_boost"]:
		if not _is_cultural_subject(selected_subject_id):
			return "请选择换入的文化课科目"
		if selected_subject_id == course_context().subject_id:
			return "换入科目必须不同于当前授课科目"
	elif definition.knowledge_mode == "selected_subject":
		# 结伴自习等显式选科互动必须指定真实文化课，双方同按该科学习。
		if not _is_cultural_subject(selected_subject_id):
			return "请为%s选择语文、数学或英语" % definition.name
	elif not selected_subject_id.is_empty():
		return "这个互动不接受换入科目"
	# 抢漫画是竞争互动：目标必须正在看漫画（个人或物品版）才有可抢的漫画。
	if action_id == "take_comic" and String(students[target_index].current_action.get("action_id")) not in ["read_comic", "read_comic_item"]:
		return "对方正在看漫画时才能抢走漫画"
	# 宿舍结伴是合作邀请：只在目标空闲时接受，不打断对方的自习或休息，也阻断反复互相打断链。
	if definition.eligible_period == "dorm_free" and not students[target_index].current_action.is_empty():
		return "对方正忙，不便打扰"
	# 宿舍双人活动与单人活动同一耗尽口径：任一方负tick资源为零即不可开始。
	if definition.eligible_period == "dorm_free":
		for effect: Dictionary in config.phase_effects(action_id, "tick"):
			if effect.type == "resource" and effect.value < 0.0 and _condition_matches(effect.condition, true, course_context()):
				for index in [initiator_index, target_index]:
					if index in _effect_recipients(effect.recipient, initiator_index, target_index) and students[index][effect.resource] <= 0.0:
						return "%s的%s耗尽，不能开始%s" % [students[index].name, "专注" if effect.resource == "focus" else "体力", definition.name]
	if action_id == "answer_challenge" and not (course_context().kind == "lesson" and _is_cultural_subject(course_context().subject_id)):
		return "抢答需要在语文、数学或英语课堂上"
	for index in [initiator_index, target_index]:
		var costs: Dictionary = {"focus": 0.0, "stamina": 0.0}
		var item_costs: Dictionary = {}
		for effect in config.phase_effects(action_id, "start"):
			if index not in _effect_recipients(effect.recipient, initiator_index, target_index) or not _condition_matches(effect.condition, true, course_context()):
				continue
			if effect.type == "resource":
				var amount: float = _resource_effect_value(index, effect)
				if amount < 0.0:
					costs[effect.resource] -= amount
			elif effect.type == "consume_item":
				item_costs[effect.item_id] = int(item_costs.get(effect.item_id, 0)) + int(effect.value)
		for resource in costs:
			if students[index][resource] < costs[resource]:
				return "%s的%s不足，发动需要%.2f" % [students[index].name, "专注" if resource == "focus" else "体力", costs[resource]]
		for item_id: String in item_costs:
			var held: int = int(students[index].inventory.get(item_id, 0))
			if held < item_costs[item_id]:
				return "%s的%s不足，需要%d件，当前%d件" % [students[index].name, config.items[item_id].name, item_costs[item_id], held]
	return ""


## 查询只检查真实前置条件，不扣资源、不抽时长、不打断动作。
func can_start_interaction(initiator_index: int, target_index: int, action_id: String, selected_subject_id: String = "") -> bool:
	return interaction_unavailable_reason(initiator_index, target_index, action_id, selected_subject_id).is_empty()


## 文化课身份来自有效科目表，不把体育或考试别名当作课本选择。
func _is_cultural_subject(subject_id: String) -> bool:
	return config.subjects.has(subject_id) and config.subjects[subject_id].kind == "knowledge" and subject_id != "physical"


## 原子接管新参与者，所有旧互动先整体结束，之后才建立新动作及恢复旧搭档。
func start_interaction(initiator_index: int, target_index: int, action_id: String, note_text: String = "", selected_subject_id: String = "", reason: String = "主动互动") -> Error:
	var unavailable: String = interaction_unavailable_reason(initiator_index, target_index, action_id, selected_subject_id)
	if not unavailable.is_empty():
		return _reject(unavailable, ERR_UNAVAILABLE)
	if action_id == "send_note" and note_text.strip_edges().is_empty():
		return _reject("请输入纸条内容", ERR_INVALID_PARAMETER)
	# 掰手腕只取真实发动时的体力；抢答只取真实发动时的知识与智力快照。
	# 完成时不重新取值，不受期间知识积累、属性点或调表影响，保证结果可复现。
	var stamina_snapshot: Dictionary = {}
	if action_id == "arm_wrestle":
		stamina_snapshot = {"initiator": students[initiator_index].stamina, "target": students[target_index].stamina}
	var subject: String = course_context().subject_id
	var challenge_snapshot: Dictionary = {}
	if action_id == "answer_challenge":
		challenge_snapshot = {
			"subject_id": subject,
			"initiator_knowledge": float(students[initiator_index].knowledge[subject]),
			"target_knowledge": float(students[target_index].knowledge[subject]),
			"initiator_intelligence": effective_attribute(initiator_index, "intelligence"),
			"target_intelligence": effective_attribute(target_index, "intelligence"),
		}
	for index: int in [initiator_index, target_index]:
		_queue_remaining_participants(index, [initiator_index, target_index])
	for index in [initiator_index, target_index]:
		if not students[index].current_action.is_empty():
			var ended: Error = _end_action(index, false, "新互动打断", initiator_index)
			if ended != OK:
				return ended
	var definition: Dictionary = config.actions[action_id]
	var duration: float = rng.randf_range(definition.duration_min_s, definition.duration_max_s)
	var interaction: Dictionary = {
		"interaction_id": next_interaction_number, "action_id": action_id,
		"initiator_index": initiator_index, "target_index": target_index,
		"started_at": elapsed_s, "ends_at": elapsed_s + duration, "duration_s": duration,
		"status": "active", "finished_at": null, "interrupted_by": -1,
		"note_text": note_text if action_id == "send_note" else "",
		"selected_subject_id": selected_subject_id, "stamina_snapshot": stamina_snapshot, "result": {},
		"challenge_snapshot": challenge_snapshot,
	}
	next_interaction_number += 1
	interactions.append(interaction)
	for index in [initiator_index, target_index]:
		var pair_action: Dictionary = {
			"instance_id": next_action_number, "interaction_id": interaction.interaction_id,
			"action_id": action_id, "started_at": elapsed_s, "ends_at": interaction.ends_at,
			"duration_s": duration, "last_settled_at": elapsed_s,
			# 显式选科动作（如结伴自习）保存发起者选科；宿舍无选科互动与单人活动同样不留科目。
			"subject_id": selected_subject_id if definition.knowledge_mode == "selected_subject" else ("" if definition.eligible_period == "dorm_free" else course_context().subject_id),
			"natural_entry": true, "resource_changes": {}, "knowledge_gain": 0.0,
		}
		# 宿舍自由时段的互动与单人活动共享休息接续契约。
		if definition.eligible_period == "dorm_free":
			pair_action["dorm_recovery"] = false
		students[index].current_action = pair_action
		next_action_number += 1
	var result: Error = _apply_targeted_phase(initiator_index, target_index, action_id, "start", interaction)
	if result != OK:
		return result
	var log_details: Dictionary = interaction.duplicate(true)
	log_details["reason"] = reason
	_log(initiator_index, "interaction_start", "%s → %s：%s%s" % [students[initiator_index].name, students[target_index].name, definition.name, "（尚未送达）" if action_id == "send_note" else ""], log_details)
	return _fill_missing_actions()


## 新动作只接管指定参与者，其余旧搭档按既有schedule打断策略接续。
func _queue_remaining_participants(index: int, incoming: Array) -> void:
	var action: Dictionary = students[index].current_action
	if not action.has("interaction_id"):
		return
	var interaction: Dictionary = _interaction_by_id(action.interaction_id)
	for participant: int in [interaction.initiator_index, interaction.target_index]:
		if participant not in incoming and participant not in schedule_returns:
			schedule_returns.append(participant)


## 地点使用动作和当前课表，供场景前置条件与可视化共用。
func student_location(student_index: int) -> String:
	return _action_location(students[student_index].current_action, course_context())


## 实时动作与快照动作共用地点规则，避免存档校验引入另一份场景推测。
func _action_location(action: Dictionary, context: Dictionary) -> String:
	if action.get("action_id") == "invite_playground":
		return "playground"
	if action.get("action_id") == "invite_canteen":
		return "canteen"
	# 去操场玩就是操场活动：体育课与课间磨蹭都真实位于操场。
	if action.get("action_id") == "playground_play":
		return "playground"
	var location: String = "any" if action.is_empty() else config.actions[action.action_id].scene
	if location == "course":
		return "playground" if context.subject_id == "physical" else "classroom"
	if location == "any":
		if context.kind == "outside" or context.kind == "rest":
			return "dorm"
		if context.kind == "lunch":
			return "canteen"
		return "playground" if context.subject_id == "physical" else "classroom"
	return location


## 返回可举报的当前连续违纪副本，调用者不能修改权威事件。
func get_open_violation(target_index: int) -> Dictionary:
	if target_index < 0 or target_index >= students.size() or not _is_classroom_distraction(target_index):
		return {}
	for violation in violations:
		if violation.target_index == target_index and violation.status == "open":
			return violation.duplicate(true)
	return {}


## 举报引用确切事件编号，旧请求和已处理事件不能转而处罚当前新事件。
func report_unavailable_reason(target_index: int, violation_id: int) -> String:
	if is_round_finished():
		return "本局已结束，不能发起举报"
	if target_index <= 0 or target_index >= students.size():
		return "请选择另一位同学"
	if "report" not in phase_scope.enabled_actions or not config.actions.report.enabled:
		return "举报尚未开放"
	var event: Dictionary = _violation_by_id(violation_id)
	if event.is_empty() or event.target_index != target_index:
		return "该次违纪事件不存在"
	if event.status != "open":
		return "该次违纪已处理或结束"
	if student_location(0) != "classroom" or get_open_violation(target_index).is_empty():
		return "只能举报教室上课中的当前开小差"
	return ""


## 瞬时举报保留举报者动作；举报当前搭档时按已确认例外整体结束互动。
func report_violation(target_index: int, violation_id: int) -> Error:
	var unavailable: String = report_unavailable_reason(target_index, violation_id)
	if not unavailable.is_empty():
		var event: Dictionary = _violation_by_id(violation_id)
		return _reject(unavailable, ERR_ALREADY_EXISTS if not event.is_empty() and event.status != "open" else ERR_UNAVAILABLE)
	var before: Array[float] = [students[0].focus, students[target_index].focus]
	var payload: Dictionary = {"violation_id": violation_id}
	var result: Error = _apply_targeted_phase(0, target_index, "report", "instant", payload)
	if result != OK:
		return result
	_log(0, "report", "举报%s的开小差，目标回归课堂" % students[target_index].name, {
		"target_index": target_index, "violation_id": violation_id,
		"reporter_focus_change": students[0].focus - before[0],
		"target_focus_change": students[target_index].focus - before[1],
	})
	return _fill_missing_actions()


## 专注只允许玩家控制自己的角色；每次点击都按配表瞬时生效。
func focus_command(student_index: int = 0) -> Error:
	if is_round_finished():
		return _reject("本局已结束，不能再使用专注指令", ERR_UNAVAILABLE)
	if student_index != 0:
		return _fail("只能对自己的角色使用专注指令")
	if "focus_command" not in phase_scope.enabled_actions or not config.actions.focus_command.enabled:
		return _fail("专注指令未在当前阶段开放")
	var before: float = students[student_index].focus
	var result: Error = _apply_phase(student_index, "focus_command", "instant", false)
	if result != OK:
		return result
	_log(student_index, "command", "使用专注指令", {"requested_action": "focus_command", "actual_focus_gain": students[student_index].focus - before})
	return OK


## 计算当时的资源上限，健康与体力资源保持明确区分。
func get_resource_max(student_index: int, resource: String) -> float:
	if resource == "focus":
		return config.global_value("focus_base") + config.global_value("focus_per_discipline") * effective_attribute(student_index, "discipline")
	assert(resource == "stamina", "未知资源：%s" % resource)
	return config.global_value("stamina_base") + config.global_value("stamina_per_health") * effective_attribute(student_index, "health")


## 新配置接管费率并中止已离开自由时段的宿舍动作；仍合条件的在途时长保持不变。
func apply_config(new_config: RefCounted) -> Error:
	var previous_version: String = config.version
	var previous_config: RefCounted = config
	config = new_config
	config.phase_scope = phase_scope
	var result: Error = _validate_scope()
	if result != OK:
		config = previous_config
		return result
	for index in students.size():
		var active: Dictionary = students[index].current_action
		if not active.is_empty():
			# 在途选科和来源已固定；改费率可以即时生效，改语义会使同一实例无法正确续算。
			var before: Dictionary = previous_config.actions[active.action_id]
			var after: Dictionary = config.actions[active.action_id]
			for field: String in ["knowledge_source", "knowledge_mode", "knowledge_subject_id", "eligible_period"]:
				if before[field] != after[field]:
					config = previous_config
					return _fail("新配置改变了在途动作的知识来源、选科或时段契约：%s" % active.action_id)
		# 背包是权威存档的一部分，调表不能删除已持有的物品并留下无法恢复的局。
		for item_id in students[index].inventory:
			if not config.items.has(item_id):
				config = previous_config
				return _fail("新配置删除了背包中的物品：%s" % item_id)
		var buff_groups: Dictionary = {}
		for instance in students[index].buffs:
			if not config.buffs.has(instance.buff_id):
				config = previous_config
				return _fail("新配置删除了仍在生效的状态：%s" % instance.buff_id)
			var lifecycle: String = String(config.buffs[instance.buff_id].lifecycle)
			if (lifecycle == "timed") != (instance.expires_at != null):
				config = previous_config
				return _fail("新配置改变了正在生效状态的持续方式：%s" % instance.buff_id)
			var definition: Dictionary = config.buffs[instance.buff_id]
			if definition.knowledge_redirect == "selected_subject":
				if not instance.has("selected_subject_id") or not _is_cultural_subject(instance.selected_subject_id):
					config = previous_config
					return _fail("新配置的知识重定向缺少已保存的有效科目：%s" % instance.buff_id)
			elif instance.has("selected_subject_id"):
				config = previous_config
				return _fail("新配置改变了正在生效状态的知识重定向方式：%s" % instance.buff_id)
			if definition.stacking != "independent" and buff_groups.has(definition.stack_group):
				config = previous_config
				return _fail("新配置使正在生效的状态组发生冲突：%s" % definition.stack_group)
			buff_groups[definition.stack_group] = true
	result = round_progression.apply_config(new_config, _round_participants())
	if result != OK:
		config = previous_config
		return _fail(round_progression.error_message)
	result = _end_unavailable_dorm_actions("课表更新后已离开宿舍自由活动时段")
	if result != OK:
		return result
	for index in students.size():
		_clamp_resources_after_max_change(index)
		_sync_violation(index)
	_log(-1, "config", "配置已更新：后续消耗恢复采用新值，本段时长保持不变", {"old_version": previous_version, "new_version": config.version})
	return OK


## 玩家将已有待分配点投入基础属性；不改变动作、随机流或已取值的历史成绩。
func allocate_attribute(attribute_id: String, amount: int = 1, student_index: int = 0) -> Error:
	if is_round_finished():
		return _reject("本局已结束，不能再分配属性点", ERR_UNAVAILABLE)
	if student_index != 0:
		return _reject("只能分配自己的属性点", ERR_INVALID_PARAMETER)
	if attribute_id not in ATTRIBUTE_KEYS or amount <= 0:
		return _reject("请选择有效属性，并分配正整数点数", ERR_INVALID_PARAMETER)
	var student: Dictionary = students[student_index]
	if amount > student.unspent_points:
		return _reject("待分配属性点不足", ERR_UNAVAILABLE)
	var previous_value: float = student.attributes[attribute_id]
	var next_value: float = previous_value + float(amount)
	if not is_finite(next_value) or next_value - previous_value != float(amount):
		return _reject("属性变化超出当前数值可精确表示的范围", ERR_INVALID_DATA)
	# 先验证上限运算，再统一扣点；配置导致非法上限时不能留下半份分配结果。
	for resource: String in ["focus", "stamina"]:
		var maximum: float = get_resource_max(student_index, resource)
		if attribute_id == ("discipline" if resource == "focus" else "health"):
			maximum += float(amount) * config.global_value("focus_per_discipline" if resource == "focus" else "stamina_per_health")
		if not is_finite(maximum) or maximum <= 0.0:
			return _reject("属性分配后的资源上限无效，请检查属性换算配置", ERR_INVALID_DATA)
	student.attributes[attribute_id] = next_value
	student.unspent_points -= amount
	# 上限变化仍走已有规则：提高不赠送资源，降低只裁去真实超额部分并记录。
	_clamp_resources_after_max_change(student_index)
	_log(student_index, "attribute", "分配属性点", {
		"attribute_id": attribute_id, "amount": amount, "previous": previous_value,
		"current": next_value, "unspent_points": student.unspent_points,
	})
	return OK


## 有效属性读取当前生效状态，不回算已经发生的收益。
func effective_attribute(student_index: int, attribute: String) -> float:
	var result: float = students[student_index].attributes[attribute]
	var field: String = "focus_delta" if attribute == "attention" else attribute + "_delta"
	for instance in students[student_index].buffs:
		result += config.buffs[instance.buff_id][field]
	return result


## 原子替换本地存档，随机状态和已抽时长使用精确文本保存。
func save_file(path: String) -> Error:
	round_progression.freeze(day, clock_seconds, _round_participants())
	# 保存前同步抽查、抢答与磨蹭的随机流状态，保证读档后继续可复现。
	inspection.rng_state = str(inspection_rng.state)
	challenge_auto.rng_state = str(challenge_rng.state)
	linger_auto.rng_state = str(linger_rng.state)
	var snapshot: Dictionary = {
		"save_version": SAVE_VERSION, "config_fingerprint": config.fingerprint, "config_version": config.version,
		"created_date": created_date, "day": day, "clock_seconds": clock_seconds, "elapsed_s": elapsed_s,
		"context_key": course_context().context_key, "students": students, "logs": logs,
		"rng_seed": str(rng.seed), "rng_state": str(rng.state), "next_action_number": next_action_number,
		"interactions": interactions, "notes": notes, "violations": violations,
		"next_interaction_number": next_interaction_number, "next_violation_number": next_violation_number,
		"round_progression": round_progression.encoded(), "inspection": inspection,
		"daily_points": daily_points, "npc_growth": npc_growth, "challenge_auto": challenge_auto,
		"linger_auto": linger_auto, "event_auto": event_auto, "events_log": events_log,
	}
	var global_path: String = ProjectSettings.globalize_path(path)
	var directory_result: Error = DirAccess.make_dir_recursive_absolute(global_path.get_base_dir())
	if directory_result != OK:
		return _fail("无法创建存档目录，错误码%s" % directory_result)
	var temporary_path: String = global_path + ".tmp"
	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		return _fail("无法写入存档：%s" % global_path)
	file.store_string(JSON.stringify(snapshot, "\t", true, true))
	file.flush()
	file.close()
	var result: Error = DirAccess.rename_absolute(temporary_path, global_path)
	if result != OK:
		return _fail("无法替换存档，错误码%s" % result)
	return OK


## 恢复已有局；新费率立即生效，已抽时长、已发生结果和启动费保持不变。
func load_file(path: String, align_system_time: bool = true) -> Error:
	return _load_file(path, align_system_time)


## 隔离验收显式指定恢复到的局内时刻，仍复用生产冻结恢复流程，不修改电脑时间。
func load_file_at_time(path: String, resume_day: int, resume_clock: float) -> Error:
	if resume_day < 1 or not is_finite(resume_clock) or resume_clock < 0.0 or resume_clock >= 86400.0:
		return _fail("显式恢复时间必须为有效局内日和当日秒")
	return _load_file(path, true, resume_day, resume_clock)


## 在覆盖有效局前验证完整新版账本，并先用保存的冻结来源规划离线纯事件。
func _load_file(path: String, align_system_time: bool, explicit_day: int = -1, explicit_clock: float = -1.0) -> Error:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _fail("无法读取存档：%s" % path)
	var parser := JSON.new()
	if parser.parse(file.get_as_text()) != OK or not parser.data is Dictionary:
		return _fail("存档JSON格式错误")
	var data: Dictionary = parser.data
	var validation: Error = _validate_snapshot(data)
	if validation != OK:
		return validation
	var resume_day: int = int(data.day)
	var resume_clock: float = data.clock_seconds
	if align_system_time:
		var now: Dictionary = Time.get_datetime_dict_from_system()
		var current_date: String = "%04d-%02d-%02d" % [now.year, now.month, now.day]
		resume_day = int((Time.get_unix_time_from_datetime_string(current_date + "T00:00:00") - Time.get_unix_time_from_datetime_string(data.created_date + "T00:00:00")) / 86400) + 1
		resume_clock = now.hour * 3600.0 + now.minute * 60.0 + now.second
		if resume_day < 1:
			return _fail("电脑日期早于本局创建日期，请检查系统时间")
	if explicit_day >= 1:
		resume_day = explicit_day
		resume_clock = explicit_clock
	var candidate_round := ROUND.new()
	var candidate_events: Array = []
	var participants: Array = _round_participants(data.students)
	if data.save_version >= 4:
		if not data.has("round_progression"):
			return _fail("v4及以后存档缺少七天结算账本")
		var restored_result: Error = candidate_round.restore(data.round_progression, config, participants, int(data.day), data.clock_seconds, data.config_fingerprint)
		if restored_result != OK:
			return _fail(candidate_round.error_message)
		if candidate_round.data.finished:
			for student: Dictionary in data.students:
				if not student.current_action.is_empty():
					return _fail("已结束局不能保存尚在运行的动作")
			resume_day = int(data.day)
			resume_clock = data.clock_seconds
		elif align_system_time:
			restored_result = candidate_round.process_position(resume_day, resume_clock, participants, "offline_frozen", candidate_round.data.frozen)
			if restored_result != OK:
				return _fail(candidate_round.error_message)
			candidate_events = candidate_round.events.duplicate(true)
	else:
		if data.has("round_progression"):
			return _fail("旧版存档含有无法归属的七天结算账本")
		var migration_result: Error = candidate_round.setup(config, participants, resume_day, resume_clock, true)
		if migration_result != OK:
			return _fail(candidate_round.error_message)
		var migration_events: Array = candidate_round.events.duplicate(true)
		migration_result = candidate_round.process_position(resume_day, resume_clock, participants)
		if migration_result != OK:
			return _fail(candidate_round.error_message)
		candidate_events = migration_events + candidate_round.events.duplicate(true)
	if data.config_fingerprint != config.fingerprint and not candidate_round.data.finished:
		# 离线事件沿用退出时旧边界与冻结参数；新课表兼容性也在覆盖有效局前一次性确认。
		var refreshed: Error = candidate_round.apply_config(config, participants)
		if refreshed != OK:
			return _fail(candidate_round.error_message)
	students.clear()
	for student in data.students:
		# 特殊事件字段是v6新增：同版本旧档与更低版本档缺失时按未触发默认迁移。
		if not student.has("pending_event") or not student.pending_event is Dictionary:
			student.pending_event = {}
		if not student.has("pending_forced_action") or not student.pending_forced_action is String:
			student.pending_forced_action = ""
		# v1/v2从未持久化领取记录；迁移只建空记录，不从库存猜测，也不重启当前课程补发。
		if data.save_version < 3:
			student.daily_item_claim_days = []
		else:
			# JSON整数可能解析为浮点数，边界归一为整数，确保后续日期成员检查保持幂等。
			var claim_days: Array[int] = []
			for claim_day in student.daily_item_claim_days:
				claim_days.append(int(claim_day))
			student.daily_item_claim_days = claim_days
		# 旧版只有普通宿舍休息，明确迁移为非强制恢复；不为新自习或刷题猜测状态。
		if not student.current_action.is_empty() and student.current_action.action_id == "dorm_rest" and not student.current_action.has("dorm_recovery"):
			student.current_action.dorm_recovery = false
		if data.save_version >= 5:
			# JSON可能把纪律分读成浮点，这里统一归一为浮点与整数天。
			student.daily_discipline = float(student.daily_discipline)
			student.daily_discipline_day = int(student.daily_discipline_day)
		else:
			# v4及更早没有每日纪律分：迁移为载入当天的基准值，不补造历史扣分。
			student.daily_discipline = float(_inspection_setting("daily_base"))
			student.daily_discipline_day = int(data.day)
		students.append(student)
	logs.clear()
	for entry in data.logs:
		logs.append(entry)
	created_date = data.created_date
	round_progression = candidate_round
	day = int(data.day)
	clock_seconds = data.clock_seconds
	elapsed_s = data.elapsed_s
	next_action_number = int(data.next_action_number)
	rng.seed = int(data.rng_seed)
	rng.state = int(data.rng_state)
	if data.save_version >= 5:
		inspection = data.inspection.duplicate(true)
		inspection.rng_state = str(inspection.rng_state)
		inspection.next_check_elapsed = float(inspection.next_check_elapsed)
		inspection.cooldown_until_elapsed = float(inspection.cooldown_until_elapsed)
		inspection.visible_until_elapsed = float(inspection.visible_until_elapsed)
		inspection.last = (inspection.last as Dictionary).duplicate(true)
		if not inspection.last.is_empty():
			inspection.last.day = int(inspection.last.day)
		inspection_rng.state = int(inspection.rng_state)
	else:
		# 旧版从读档时刻重新计时抽查，不猜测关闭期间发生过的检查。
		inspection_rng.seed = int(rng.seed) ^ 0x5DEECE66D
		inspection = {
			"rng_state": str(inspection_rng.state),
			"next_check_elapsed": elapsed_s + float(_inspection_setting("check_interval_seconds")),
			"cooldown_until_elapsed": 0.0,
			"visible_until_elapsed": -1.0,
			"last": {},
		}
	if data.save_version >= 6:
		# v6恢复抢答检查点随机流与下一次检查时刻，读档后沿同一随机流继续。
		challenge_rng.state = int(data.challenge_auto.rng_state)
		challenge_auto = {
			"rng_state": str(challenge_rng.state),
			"next_check_elapsed": float(data.challenge_auto.next_check_elapsed),
		}
	else:
		# v5及更早没有抢答检查点：从读档时刻按间隔重新计时，随机流种子照常派生。
		challenge_rng.seed = int(rng.seed) ^ 0x2FCB4C67
		challenge_auto = {
			"rng_state": str(challenge_rng.state),
			"next_check_elapsed": elapsed_s + float(config.global_value("answer_challenge_check_seconds")),
		}
	if data.save_version >= 6:
		# v6恢复磨蹭随机流与已处理课间标记，读档后同一课间不重复判定。
		linger_rng.state = int(data.linger_auto.rng_state)
		linger_auto = {
			"rng_state": str(linger_rng.state),
			"handled_key": String(data.linger_auto.handled_key),
		}
	else:
		# v5及更早没有磨蹭状态：随机流种子照常派生，读档课间视为未判定。
		linger_rng.seed = int(rng.seed) ^ 0x1D872B41
		linger_auto = {
			"rng_state": str(linger_rng.state),
			"handled_key": "",
		}
	# 特殊事件状态同属v6新增：字段缺失（同版本旧档）时按未触发默认，不补造历史事件。
	if data.save_version >= 6 and data.get("event_auto") is Dictionary and data.event_auto.has_all(["rng_state", "handled_key", "fired_day"]) and data.event_auto.rng_state is String and data.event_auto.rng_state.is_valid_int():
		event_rng.state = int(data.event_auto.rng_state)
		event_auto = {
			"rng_state": str(event_rng.state),
			"handled_key": String(data.event_auto.handled_key),
			"fired_day": int(data.event_auto.fired_day),
		}
		events_log.clear()
		if data.get("events_log") is Array:
			for entry: Variant in data.events_log:
				if entry is Dictionary:
					events_log.append(entry)
	else:
		# 旧v6档与更低版本档没有事件状态：随机流种子照常派生，读档后从未触发过事件。
		event_rng.seed = int(rng.seed) ^ 0x6E774B57
		event_auto = {
			"rng_state": str(event_rng.state),
			"handled_key": "",
			"fired_day": 0,
		}
		events_log.clear()
	if data.save_version >= 6:
		# v6恢复已发放日集合与NPC轮换游标，之后由统一的离线补发入口兜底。
		daily_points = {"granted_days": []}
		for granted_day: Variant in data.daily_points.granted_days:
			daily_points.granted_days.append(int(granted_day))
		npc_growth = {"cursor": int(data.npc_growth.cursor)}
	else:
		# v5及更早没有发点记录：迁移日及之前全部视为已发放，不补造历史，从下一天起正常发放。
		var migrated_days: Array = []
		for grant_day in range(int(config.global_value("first_daily_attribute_day")), int(data.day) + 1):
			migrated_days.append(grant_day)
		daily_points = {"granted_days": migrated_days}
		npc_growth = {"cursor": 0}
	interactions.clear()
	notes.clear()
	violations.clear()
	next_interaction_number = 1
	next_violation_number = 1
	if data.save_version >= 2:
		interactions.assign(data.interactions)
		# 旧版纸条和基础橡皮没有选科与胜负；边界校验确认后显式迁移空元数据。
		for interaction: Dictionary in interactions:
			if not interaction.has("selected_subject_id"):
				interaction.selected_subject_id = ""
				interaction.stamina_snapshot = {}
				interaction.result = {}
		notes.assign(data.notes)
		violations.assign(data.violations)
		next_interaction_number = int(data.next_interaction_number)
		next_violation_number = int(data.next_violation_number)
	else:
		# v1只存在单人动作；迁移保留原动作、资源和随机流，不补造过去的互动。
		for index in students.size():
			_sync_violation(index)
	if data.save_version < SAVE_VERSION:
		_log(-1, "migration", "旧版存档已迁移：原进度与已有领取保留，缺失榜单和开考历史明确标注；当日知识从接入时统计", {"from_version": int(data.save_version), "to_version": SAVE_VERSION})
	is_debug_time = not align_system_time or explicit_day >= 1
	if align_system_time:
		day = resume_day
		clock_seconds = resume_clock
	if course_context().context_key != data.context_key:
		for index in students.size():
			if not students[index].current_action.is_empty():
				var result: Error = _end_action(index, false, "关闭期间跨课，未结算离线收益")
				if result != OK:
					return result
		for index in students.size():
			_sync_violation(index)
	# 跨配置时可能沿用同一时段键但已改为上课，必须按真实新课表检查宿舍活动资格。
	var dorm_result: Error = _end_unavailable_dorm_actions("读档后课表已离开宿舍自由活动时段")
	if dorm_result != OK:
		return dorm_result
	var committed: Error = _commit_round_events(candidate_events)
	if committed != OK:
		return committed
	if data.config_fingerprint != config.fingerprint:
		_log(-1, "config", "配置已更新：新费率立即使用，当前动作时长保留", {"old_version": data.config_version, "new_version": config.version})
		for index in students.size():
			_clamp_resources_after_max_change(index)
			_sync_violation(index)
	_log(-1, "save", "已读取本地存档，关闭期间不推进资源与知识", {})
	# 读档恢复完成后再补点：此刻的day/clock才是“上线时刻”，八点后上线的离线点在此补上。
	var caught_up: Error = _catch_up_daily_points()
	if caught_up != OK:
		return caught_up
	return OK


## 显式开发入口只调整验证时钟，不制造已获得的知识、奖励或动作结果。
func set_debug_time(test_day: int, seconds: float) -> Error:
	if test_day < 1 or seconds < 0.0 or seconds >= 86400.0 or not is_finite(seconds):
		return _fail("开发时间必须是有效天数和当天秒数")
	if is_round_finished():
		return _reject("本局已结束，开发时钟不能重开或改写历史，请重新开始独立测试局", ERR_UNAVAILABLE)
	for index in students.size():
		if not students[index].current_action.is_empty():
			var result: Error = _end_action(index, false, "开发时间切换")
			if result != OK:
				return result
	day = test_day
	clock_seconds = seconds
	is_debug_time = true
	# 开发时钟可跨日，纪律分必须按新的当前日重置，避免把旧日扣分带入。
	_reset_daily_discipline()
	# 开发时钟切换后的补点与读档同一语义：当前时刻前错过的检查点补上，已发放的不回滚。
	var caught_up: Error = _catch_up_daily_points()
	if caught_up != OK:
		return caught_up
	var relocated: Error = round_progression.relocate(test_day, seconds, _round_participants())
	if relocated != OK:
		return _fail(round_progression.error_message)
	for index in students.size():
		_sync_violation(index)
	_log(-1, "debug", "开发时间切换至第%s天%s" % [day, _format_clock()], {})
	return _commit_round_events(round_progression.events)


## 显式验证推进复用生产结算流程，界面不得把它伪装为现实时间流逝。
func advance_for_test(seconds: float) -> Error:
	is_debug_time = true
	return advance(seconds)


## 启动时校验已开放内容，遇到当前执行器不支持的效果直接报错。
func _validate_scope() -> Error:
	# 选科状态必须共享唯一替换组，不能热改成多份并存后静默取最后一份。
	var redirect_group: String = ""
	if not phase_scope.get("subject_auto_actions") is Dictionary:
		return _fail("阶段范围必须声明subject_auto_actions对象")
	# 宿舍自主池含六项个人活动与两项双人结伴活动。
	if not phase_scope.get("dorm_auto_actions") is Array or phase_scope.dorm_auto_actions.size() != 8:
		return _fail("阶段范围必须明确声明八项宿舍自主活动")
	var dorm_ids: Array = []
	for action_id: Variant in phase_scope.dorm_auto_actions:
		if not action_id is String or action_id in dorm_ids or action_id not in phase_scope.enabled_actions or not config.actions.has(action_id) or config.actions[action_id].eligible_period != "dorm_free":
			return _fail("宿舍自主候选重复、未开放或时段契约错误：%s" % action_id)
		dorm_ids.append(action_id)
	for action_id in phase_scope.auto_actions:
		if not action_id is String or action_id not in phase_scope.enabled_actions:
			return _fail("默认自主候选未在本阶段开放：%s" % action_id)
	for subject_id in phase_scope.subject_auto_actions:
		if not config.subjects.has(subject_id) or config.subjects[subject_id].kind != "knowledge":
			return _fail("自主候选覆盖必须引用知识科目：%s" % subject_id)
		var allowed: Variant = phase_scope.subject_auto_actions[subject_id]
		if not allowed is Array:
			return _fail("科目%s的自主候选必须为数组" % subject_id)
		for action_id in allowed:
			if not action_id is String or action_id not in phase_scope.enabled_actions:
				return _fail("科目%s的自主候选未在本阶段开放：%s" % [subject_id, action_id])
	for action_id in phase_scope.enabled_actions:
		if not config.actions.has(action_id):
			return _fail("阶段范围引用了不存在的动作：%s" % action_id)
		var definition: Dictionary = config.actions[action_id]
		if (action_id in PAIR_ACTIONS or action_id == "report") and (definition.target != "pair" or definition.kind != ("instant" if action_id == "report" else "duration")):
			return _fail("互动对象或动作类型与执行契约不一致：%s" % action_id)
		if definition.target != "self" and action_id not in PAIR_ACTIONS and action_id != "report":
			return _fail("当前阶段尚未实现该互动：%s" % action_id)
		var policy: Dictionary = config.indexes.interrupt_policies[definition.interrupt_policy_id]
		if policy.keep_accrued != true or policy.refund_start_resource != false or policy.refund_consumed_items != false or policy.keep_progress != false or policy.cancel_pending_effects != true or policy.new_action_priority != true or policy.remaining_participants_route != "schedule":
			return _fail("当前执行器不支持该打断策略：%s" % policy.id)
		# 同物品的多条启动消耗要先汇总验证，避免实际扣除时才发生整型溢出。
		var item_totals: Dictionary = {}
		var self_route_count: int = 0
		for effect in config.effects_by_action[action_id]:
			var pair: bool = definition.target == "pair"
			if (definition.kind == "instant") != (effect.phase == "instant") or effect.phase not in ["start", "tick", "complete", "instant"]:
				return _fail("动作效果阶段与执行契约不一致：%s" % effect.id)
			var result_recipient: bool = pair and action_id in ["arm_wrestle", "answer_challenge"] and effect.phase == "complete" and effect.recipient in ["winner", "loser", "tie"] and effect.condition == effect.recipient
			if (not pair and effect.recipient != "self") or (pair and effect.recipient not in ["self", "target", "both"] and not result_recipient):
				return _fail("当前阶段尚未实现效果对象：%s" % effect.id)
			if effect.type not in (["resource", "event", "start_action", "apply_buff", "consume_item"] if pair else ["resource", "apply_buff", "consume_item", "start_action"]):
				return _fail("当前阶段尚未实现效果：%s" % effect.id)
			if effect.type == "consume_item":
				if effect.phase != "start" or not config.items.has(effect.item_id) or not config.items[effect.item_id].consumable or not _is_integer(effect.value) or effect.value <= 0:
					return _fail("物品消耗必须在启动阶段引用可消耗物品与正整数数量：%s" % effect.id)
				var quantity: int = int(effect.value)
				for payer: String in (["self", "target"] if effect.recipient == "both" else [effect.recipient]):
					var item_key: String = "%s/%s" % [payer, effect.item_id]
					var previous: int = int(item_totals.get(item_key, 0))
					if previous > MAX_ITEM_INTEGER - quantity:
						return _fail("动作的物品消耗合计超出整数表示范围：%s" % action_id)
					item_totals[item_key] = previous + quantity
			if effect.type == "apply_buff":
				if effect.phase not in ["start", "complete", "instant"] or not config.buffs.has(effect.buff_id):
					return _fail("当前阶段尚未实现该状态效果：%s" % effect.id)
				if config.buffs[effect.buff_id].knowledge_redirect != "none" and (action_id not in ["swap_book", "swap_book_boost"] or effect.phase != "complete" or effect.recipient != "target"):
					return _fail("知识重定向状态必须由已选科目的偷换课本完成效果施加：%s" % effect.id)
				if config.buffs[effect.buff_id].knowledge_redirect == "selected_subject":
					var redirect: Dictionary = config.buffs[effect.buff_id]
					if redirect.lifecycle != "timed" or redirect.stacking != "replace" or (not redirect_group.is_empty() and redirect.stack_group != redirect_group):
						return _fail("知识重定向状态必须定时并共享同一个替换组：%s" % effect.id)
					redirect_group = redirect.stack_group
				if config.buffs[effect.buff_id].lifecycle == "action" and effect.phase != "start":
					return _fail("动作绑定状态只能在动作启动阶段施加：%s" % effect.id)
			if not pair and effect.type == "start_action":
				self_route_count += 1
				if effect.phase != "complete" and not (action_id == "focus_command" and effect.phase == "instant"):
					return _fail("个人后续动作仅支持完成后接续或瞬时专注指令：%s" % effect.id)
				if effect.event not in ["natural_entry", "forced_entry"]:
					return _fail("个人后续动作缺少明确入段方式：%s" % effect.id)
				if effect.next_action_id != "current_course" and (effect.next_action_id not in phase_scope.enabled_actions or config.actions[effect.next_action_id].target != "self" or config.actions[effect.next_action_id].kind != "duration"):
					return _fail("个人后续动作必须引用已开放的个人持续动作：%s" % effect.id)
				for later_effect in config.effects_by_action[action_id]:
					if later_effect.phase == effect.phase and later_effect.sequence > effect.sequence:
						return _fail("个人后续动作必须位于对应阶段的最后：%s" % effect.id)
			if effect.type == "event" and not ((action_id == "send_note" and effect.phase == "complete" and effect.event == "deliver_note" and effect.recipient == "target") or (action_id == "report" and effect.phase == "instant" and effect.event == "close_violation" and effect.recipient == "target") or (action_id == "arm_wrestle" and effect.phase == "complete" and effect.event == "resolve_arm_wrestle" and effect.recipient == "both") or (action_id == "answer_challenge" and effect.phase == "complete" and effect.event == "resolve_answer_challenge" and effect.recipient == "both")):
				return _fail("当前阶段尚未实现事件：%s" % effect.id)
			if effect.type == "event" and effect.condition != "always":
				return _fail("送达与关闭违纪事件必须无条件执行：%s" % effect.id)
			if pair and effect.type == "start_action" and not ((action_id == "report" and effect.phase == "instant") or (action_id == "remind_friend" and effect.phase == "complete") or (action_id == "take_comic" and effect.phase == "complete")):
				return _fail("当前阶段尚未实现互动后续动作：%s" % effect.id)
			if pair and effect.type == "start_action" and (effect.recipient != "target" or effect.next_action_id != "current_course" or effect.event != "forced_entry"):
				return _fail("互动后续动作必须明确强制目标回当前课表：%s" % effect.id)
			if pair and effect.type == "start_action" and effect.condition != "always":
				return _fail("举报后的强制回课堂必须无条件执行：%s" % effect.id)
			if effect.condition not in ["always", "natural_entry", "course_active"] and not (action_id in ["arm_wrestle", "answer_challenge"] and effect.phase == "complete" and effect.condition in ["winner", "loser", "tie"]):
				return _fail("当前阶段尚未实现效果条件：%s" % effect.id)
			if effect.phase == "tick" and effect.type != "resource":
				return _fail("当前阶段持续效果只支持资源连续结算：%s" % effect.id)
		if self_route_count > 1:
			return _fail("个人动作只能包含一个明确的后续动作：%s" % action_id)
		# 业务事件必须有且只有一次，避免调表把同一纸条送达两次或重复结束违纪。
		if action_id in ["send_note", "report", "arm_wrestle", "remind_friend", "answer_challenge"]:
			var event_count: int = 0
			var route_count: int = 0
			var route_sequence: float = -1.0
			var last_sequence: float = -1.0
			for effect in config.effects_by_action[action_id]:
				last_sequence = maxf(last_sequence, effect.sequence)
				if effect.type == "event":
					event_count += 1
				if effect.type == "start_action":
					route_count += 1
					route_sequence = effect.sequence
			if event_count != (0 if action_id == "remind_friend" else 1) or (action_id in ["report", "remind_friend"] and route_count != 1):
				return _fail("互动必须包含唯一业务事件及规定的回课堂流程：%s" % action_id)
			if action_id in ["report", "remind_friend"] and route_sequence != last_sequence:
				return _fail("举报或提醒必须先结算效果，最后再唯一接续当前课堂")
		if action_id == "arm_wrestle":
			var resolve_sequence: float = -1.0
			for effect: Dictionary in config.phase_effects(action_id, "complete"):
				if effect.type == "event":
					resolve_sequence = effect.sequence
				elif effect.condition in ["winner", "loser", "tie"] and (resolve_sequence < 0.0 or effect.sequence <= resolve_sequence):
					return _fail("掰手腕必须先确定快照胜负再结算胜负效果")
		if action_id == "answer_challenge":
			# 抢答与掰手腕同序：先由判定事件给出胜负，再按条件结算双方专注变化。
			var resolve_sequence: float = -1.0
			for effect: Dictionary in config.phase_effects(action_id, "complete"):
				if effect.type == "event":
					resolve_sequence = effect.sequence
				elif effect.condition in ["winner", "loser", "tie"] and (resolve_sequence < 0.0 or effect.sequence <= resolve_sequence):
					return _fail("抢答必须先确定快照胜负再结算胜负效果")
	# 竞争社交候选必须是已开放的双人持续互动，不能把个人动作混入自主干扰池。
	if not phase_scope.get("social_auto_actions") is Array:
		return _fail("阶段范围必须声明social_auto_actions数组")
	var social_ids: Array = phase_scope.social_auto_actions
	var seen_social: Array = []
	for action_id: Variant in social_ids:
		if not action_id is String or action_id not in phase_scope.enabled_actions or action_id in seen_social or action_id not in ["borrow_notes", "swap_book", "invite_playground", "invite_canteen", "arm_wrestle", "eraser_prank", "answer_challenge"]:
			return _fail("竞争社交候选重复、未开放或不属于竞争动作池：%s" % action_id)
		seen_social.append(action_id)
	# 教师花名册必须覆盖语数英三科并恰好一位教导主任，立绘文件必须真实存在。
	var roster: Variant = phase_scope.get("teachers")
	if not roster is Array or roster.size() != 4:
		return _fail("阶段范围必须声明3位任课老师和1位教导主任")
	var covered: Dictionary = {}
	var dean_count: int = 0
	for row: Variant in roster:
		if not row is Dictionary or not row.get("id") is String or not row.get("name") is String or not row.get("subject_id") is String or not row.get("texture") is String:
			return _fail("教师条目缺少id、name、subject_id或texture")
		if (row.id as String).is_empty() or (row.name as String).is_empty() or (row.texture as String).is_empty():
			return _fail("教师条目id、name、texture不能为空")
		if not FileAccess.file_exists(row.texture):
			return _fail("教师立绘不存在：%s" % row.texture)
		if (row.subject_id as String).is_empty():
			dean_count += 1
			continue
		if not config.subjects.has(row.subject_id) or not _is_cultural_subject(row.subject_id):
			return _fail("任课老师科目必须是语数英之一：%s" % row.subject_id)
		if covered.has(row.subject_id):
			return _fail("同一文化科目出现多位任课老师：%s" % row.subject_id)
		covered[row.subject_id] = row.id
	if dean_count != 1 or covered.size() != 3:
		return _fail("教师花名册必须覆盖语数英三科且恰好一位教导主任")
	# 抽查参数必须完整、有限且落在可用区间，禁止代码里另藏默认值。
	var settings: Variant = phase_scope.get("inspection")
	if not settings is Dictionary:
		return _fail("阶段范围必须声明inspection对象")
	for key: String in ["check_interval_seconds", "chance", "cooldown_seconds", "deduction", "daily_base", "visible_seconds"]:
		if not settings.has(key) or not _is_number(settings[key]):
			return _fail("抽查参数必须是有限数字：%s" % key)
	if float(settings.check_interval_seconds) <= 0.0 or float(settings.visible_seconds) <= 0.0 or float(settings.cooldown_seconds) < 0.0:
		return _fail("抽查间隔与主任可见时长必须为正，冷却不能为负")
	if float(settings.chance) < 0.0 or float(settings.chance) > 1.0:
		return _fail("抽查概率必须在0到1之间")
	if float(settings.deduction) < 0.0 or float(settings.daily_base) <= 0.0 or float(settings.deduction) > float(settings.daily_base):
		return _fail("纪律扣分不能为负或超过每日基准，每日基准必须为正")
	return OK


## 存档作为不可信边界统一校验，损坏内容不能流入后续结算并伪装成功。
func _validate_snapshot(data: Dictionary) -> Error:
	var required: Array = ["save_version", "config_fingerprint", "config_version", "created_date", "day", "clock_seconds", "elapsed_s", "context_key", "students", "logs", "rng_seed", "rng_state", "next_action_number"]
	if not data.has_all(required) or not _is_integer(data.save_version) or data.save_version < 1 or data.save_version > SAVE_VERSION:
		return _fail("存档字段缺失或版本不支持")
	if not data.students is Array or data.students.size() != 4 or not data.logs is Array:
		return _fail("存档角色数量或日志类型错误")
	for key in ["config_fingerprint", "config_version", "created_date", "context_key", "rng_seed", "rng_state"]:
		if not data[key] is String:
			return _fail("存档字段%s必须为文本" % key)
	if not _is_integer(data.day) or data.day < 1 or not _is_integer(data.next_action_number) or data.next_action_number < 1:
		return _fail("存档天数或动作编号无效")
	if not _is_number(data.clock_seconds) or data.clock_seconds < 0.0 or data.clock_seconds >= 86400.0 or not _is_number(data.elapsed_s) or data.elapsed_s < 0.0:
		return _fail("存档时间必须是有效有限数字")
	for key in ["rng_seed", "rng_state"]:
		if not data[key].is_valid_int() or str(int(data[key])) != data[key]:
			return _fail("存档随机状态%s不是有效的精确整数文本" % key)
	if data.save_version >= 5:
		# 抽查状态属于权威进度：缺字段或字段非法都不能静默重建。
		if not data.get("inspection") is Dictionary or not data.inspection.has_all(["rng_state", "next_check_elapsed", "cooldown_until_elapsed", "visible_until_elapsed", "last"]):
			return _fail("存档缺少教导主任抽查状态或字段不完整")
		var state: Dictionary = data.inspection
		if not state.rng_state is String or not state.rng_state.is_valid_int():
			return _fail("存档抽查随机状态无效")
		for key in ["next_check_elapsed", "cooldown_until_elapsed", "visible_until_elapsed"]:
			if not _is_number(state[key]):
				return _fail("存档抽查时间字段%s无效" % key)
		if state.next_check_elapsed < 0.0 or state.cooldown_until_elapsed < 0.0:
			return _fail("存档抽查检查点或冷却时间无效")
		if not state.last is Dictionary:
			return _fail("存档最近抽查结果类型错误")
		if not state.last.is_empty():
			if not state.last.has_all(["day", "clock_seconds", "deduction", "found"]) or not _is_integer(state.last.day) or state.last.day < 1 or state.last.day > int(data.day) or not _is_number(state.last.clock_seconds) or state.last.clock_seconds < 0.0 or state.last.clock_seconds >= 86400.0 or not _is_number(state.last.deduction) or state.last.deduction < 0.0 or not state.last.found is Array:
				return _fail("存档最近抽查结果字段无效")
			for entry: Variant in state.last.found:
				if not entry is Dictionary or not entry.get("student_id") is String or not entry.get("name") is String or not entry.get("location") is String or entry.location == "classroom":
					return _fail("存档抽查发现记录无效")
	elif data.has("inspection"):
		return _fail("旧版存档含有无法归属的教导主任抽查状态")
	if data.save_version >= 6:
		# 每日发点记录与NPC轮换游标属于权威进度，缺失或非法都不能静默重建。
		if not data.get("daily_points") is Dictionary or not data.daily_points.get("granted_days") is Array or not data.get("npc_growth") is Dictionary or not _is_integer(data.npc_growth.cursor):
			return _fail("存档缺少每日属性点状态或字段不完整")
		if int(data.npc_growth.cursor) < 0 or int(data.npc_growth.cursor) >= NPC_GROWTH_CYCLE.size():
			return _fail("存档NPC轮换游标无效")
		var previous_day: int = 0
		for granted_day: Variant in data.daily_points.granted_days:
			if not _is_integer(granted_day) or int(granted_day) < 1 or int(granted_day) > int(data.day):
				return _fail("存档每日发点记录无效")
			if int(granted_day) <= previous_day:
				return _fail("存档每日发点记录必须升序且唯一")
			previous_day = int(granted_day)
		# 抢答检查点随机流状态同样属于权威进度，缺失或非法直接拒绝。
		if not data.get("challenge_auto") is Dictionary or not data.challenge_auto.has_all(["rng_state", "next_check_elapsed"]):
			return _fail("存档缺少抢答自主检查点状态或字段不完整")
		if not data.challenge_auto.rng_state is String or not data.challenge_auto.rng_state.is_valid_int() or not _is_number(data.challenge_auto.next_check_elapsed) or float(data.challenge_auto.next_check_elapsed) < 0.0:
			return _fail("存档抢答自主检查点状态无效")
		# 磨蹭随机流与已处理课间标记同属权威进度，缺失或非法直接拒绝。
		if not data.get("linger_auto") is Dictionary or not data.linger_auto.has_all(["rng_state", "handled_key"]):
			return _fail("存档缺少课间磨蹭状态或字段不完整")
		if not data.linger_auto.rng_state is String or not data.linger_auto.rng_state.is_valid_int() or not data.linger_auto.handled_key is String:
			return _fail("存档课间磨蹭状态无效")
	elif data.has("daily_points") or data.has("npc_growth") or data.has("challenge_auto") or data.has("linger_auto"):
		return _fail("旧版存档含有无法归属的每日属性点状态")
	var parsed_date: Dictionary = Time.get_datetime_dict_from_datetime_string(data.created_date + "T00:00:00", false)
	if data.created_date.length() != 10 or parsed_date.is_empty() or "%04d-%02d-%02d" % [parsed_date.year, parsed_date.month, parsed_date.day] != data.created_date:
		return _fail("存档创建日期无效")
	var identities: Dictionary = {}
	var instance_ids: Dictionary = {}
	for index in data.students.size():
		var student: Variant = data.students[index]
		if not student is Dictionary or not student.has_all(["id", "name", "focus", "stamina", "attributes", "knowledge", "inventory", "buffs", "current_action", "unspent_points"]):
			return _fail("存档角色状态不完整")
		if not student.id is String or identities.has(student.id) or not student.name is String:
			return _fail("存档角色标识重复或类型错误")
		identities[student.id] = true
		if not student.current_action is Dictionary or not student.attributes is Dictionary or not student.knowledge is Dictionary or not student.buffs is Array or not student.inventory is Dictionary:
			return _fail("存档角色状态类型错误")
		if data.save_version >= 3:
			if not student.has("daily_item_claim_days") or not student.daily_item_claim_days is Array:
				return _fail("存档缺少角色每日物品领取记录或记录类型错误")
			var previous_claim_day: int = 0
			for claim_day in student.daily_item_claim_days:
				# 回退时钟后可以保留未来已领日，但记录自身必须为升序、唯一的正整数。
				if not _is_integer(claim_day) or claim_day <= previous_claim_day:
					return _fail("存档每日物品领取日必须为升序且唯一的正整数")
				previous_claim_day = int(claim_day)
		elif student.has("daily_item_claim_days"):
			return _fail("旧版存档含有无法归属的每日物品领取记录")
		if data.save_version >= 5:
			# 每日纪律分必须在0到当日基准之间，且归属当天。
			if not student.has_all(["daily_discipline", "daily_discipline_day"]) or not _is_number(student.daily_discipline) or float(student.daily_discipline) < 0.0 or float(student.daily_discipline) > float(_inspection_setting("daily_base")) or not _is_integer(student.daily_discipline_day) or int(student.daily_discipline_day) < 1 or int(student.daily_discipline_day) > int(data.day):
				return _fail("存档角色每日纪律分缺失或无效")
		elif student.has("daily_discipline") or student.has("daily_discipline_day"):
			return _fail("旧版存档含有无法归属的每日纪律分")
		if not student.attributes.has_all(ATTRIBUTE_KEYS) or not _is_integer(student.unspent_points) or student.unspent_points < 0:
			return _fail("存档角色属性或未分配点数无效")
		for key in ["focus", "stamina"]:
			# 新表可能降低上限，旧存档绝对量在载入完成后按已确认规则裁去超额。
			if not _is_number(student[key]) or student[key] < 0.0:
				return _fail("存档资源%s无效" % key)
		for attribute in ATTRIBUTE_KEYS:
			if not _is_number(student.attributes[attribute]) or student.attributes[attribute] < 0.0:
				return _fail("存档属性%s无效" % attribute)
		for subject_id in config.subjects:
			if config.subjects[subject_id].kind == "knowledge" and (not student.knowledge.has(subject_id) or not _is_number(student.knowledge[subject_id]) or student.knowledge[subject_id] < 0.0):
				return _fail("存档知识%s缺失或无效" % subject_id)
		for item_id in student.inventory:
			if not config.items.has(item_id) or not _is_integer(student.inventory[item_id]) or student.inventory[item_id] < 0:
				return _fail("存档物品%s引用或数量无效" % item_id)
		var action: Dictionary = student.current_action
		if not action.is_empty():
			var action_required: Array = ["instance_id", "action_id", "started_at", "ends_at", "last_settled_at", "duration_s", "natural_entry", "subject_id", "resource_changes", "knowledge_gain"]
			if not action.has_all(action_required) or not action.action_id is String or action.action_id not in phase_scope.enabled_actions:
				return _fail("存档动作缺失或未在当前阶段开放")
			if config.actions[action.action_id].kind != "duration" or not action.natural_entry is bool or not action.subject_id is String or (action.subject_id != "" and not config.subjects.has(action.subject_id)) or not action.resource_changes is Dictionary:
				return _fail("存档动作类型或引用无效")
			if (config.actions[action.action_id].target == "pair") != action.has("interaction_id") or (data.save_version == 1 and action.has("interaction_id")):
				return _fail("存档动作的双人关联缺失或版本不符")
			var definition: Dictionary = config.actions[action.action_id]
			if definition.knowledge_mode == "selected_subject" and not _is_cultural_subject(action.subject_id):
				return _fail("宿舍选科动作必须保存真实文化课科目")
			if definition.knowledge_mode == "fixed_subject" and action.subject_id != definition.knowledge_subject_id:
				return _fail("宿舍固定科目与配置不一致")
			if definition.eligible_period == "dorm_free":
				if data.config_fingerprint == config.fingerprint and _context_at(int(data.day), data.clock_seconds).kind not in ["outside", "rest"]:
					return _fail("存档宿舍动作不属于保存时刻的宿舍自由活动时段")
				if definition.knowledge_mode == "none" and not action.subject_id.is_empty():
					return _fail("无知识收益的宿舍动作不能保存虚构科目")
				if not action.has("dorm_recovery"):
					var legacy_dorm: bool = data.save_version < SAVE_VERSION or (data.get("round_progression") is Dictionary and data.round_progression.get("schema_version") == 1)
					if action.action_id != "dorm_rest" or not legacy_dorm:
						return _fail("宿舍动作缺少已保存的休息接续状态")
				elif not action.dorm_recovery is bool or (action.dorm_recovery and action.action_id != "dorm_rest"):
					return _fail("宿舍休息接续状态无效")
			elif action.has("dorm_recovery"):
				return _fail("非宿舍动作包含无法归属的休息接续状态")
			if not _is_integer(action.instance_id) or action.instance_id < 1 or action.instance_id >= data.next_action_number or instance_ids.has(action.instance_id):
				return _fail("存档动作实例编号无效")
			instance_ids[action.instance_id] = true
			for key in ["started_at", "ends_at", "last_settled_at", "duration_s", "knowledge_gain"]:
				if not _is_number(action[key]):
					return _fail("存档动作字段%s必须为有限数字" % key)
			if action.started_at < 0.0 or action.started_at > data.elapsed_s or action.ends_at <= data.elapsed_s or action.duration_s <= 0.0 or action.knowledge_gain < 0.0 or absf(action.ends_at - action.started_at - action.duration_s) > 0.000001 or absf(action.last_settled_at - data.elapsed_s) > 0.000001:
				return _fail("存档动作结算时序不一致")
			for resource in action.resource_changes:
				var change: Variant = action.resource_changes[resource]
				if resource not in ["focus", "stamina"] or not change is Dictionary or not change.has_all(["requested", "actual", "current", "maximum"]):
					return _fail("存档动作资源记录无效")
				for key in ["requested", "actual", "current", "maximum"]:
					if not _is_number(change[key]):
						return _fail("存档动作资源记录%s无效" % key)
		var buff_groups: Dictionary = {}
		for buff in student.buffs:
			if not buff is Dictionary or not buff.has_all(["buff_id", "expires_at", "action_instance_id"]) or not config.buffs.has(buff.buff_id):
				return _fail("存档状态引用无效")
			var definition: Dictionary = config.buffs[buff.buff_id]
			if definition.knowledge_redirect == "selected_subject":
				if not buff.has("selected_subject_id") or not buff.selected_subject_id is String or not _is_cultural_subject(buff.selected_subject_id):
					return _fail("存档知识重定向状态缺少有效的选定科目")
			elif buff.has("selected_subject_id"):
				return _fail("存档普通状态含有无法归属的重定向科目")
			if (definition.lifecycle == "timed") != (buff.expires_at != null):
				return _fail("存档状态的持续方式与配置不一致：%s" % buff.buff_id)
			# 实例按施加顺序保存；刷新或替换应先清旧组，独立叠加才允许保留旧实例。
			if definition.stacking != "independent" and buff_groups.has(definition.stack_group):
				return _fail("存档包含未被刷新或替换的重复状态组：%s" % definition.stack_group)
			buff_groups[definition.stack_group] = true
			if buff.expires_at != null:
				if not _is_number(buff.expires_at) or buff.expires_at <= data.elapsed_s or buff.action_instance_id != null:
					return _fail("存档定时状态时序无效")
			elif not _is_integer(buff.action_instance_id) or action.is_empty() or buff.action_instance_id != action.instance_id:
				return _fail("存档动作状态不属于当前动作")
	for entry in data.logs:
		if not entry is Dictionary or not entry.has_all(["at", "elapsed_s", "day", "clock_seconds", "student_index", "name", "type", "message", "details"]):
			return _fail("存档日志结构无效")
		if not _is_number(entry.at) or not _is_number(entry.elapsed_s) or not _is_integer(entry.day) or not _is_number(entry.clock_seconds) or not _is_integer(entry.student_index) or not entry.name is String or not entry.type is String or not entry.message is String or not entry.details is Dictionary:
			return _fail("存档日志字段类型无效")
	if data.save_version >= 2:
		return _validate_interaction_snapshot(data)
	for key in ["interactions", "notes", "violations", "next_interaction_number", "next_violation_number"]:
		if data.has(key):
			return _fail("旧版存档含有无法归属的互动字段：%s" % key)
	return OK


## 互动存档交叉校验两位参与者、真实送达结果与违纪身份，拒绝孤儿或伪造完成。
func _validate_interaction_snapshot(data: Dictionary) -> Error:
	if not data.has_all(["interactions", "notes", "violations", "next_interaction_number", "next_violation_number"]) or not data.interactions is Array or not data.notes is Array or not data.violations is Array:
		return _fail("互动存档字段缺失或类型错误")
	if not _is_integer(data.next_interaction_number) or data.next_interaction_number < 1 or not _is_integer(data.next_violation_number) or data.next_violation_number < 1:
		return _fail("互动或违纪下一个编号无效")
	var registry: Dictionary = {}
	for interaction in data.interactions:
		if not interaction is Dictionary or not interaction.has_all(["interaction_id", "action_id", "initiator_index", "target_index", "started_at", "ends_at", "duration_s", "status", "finished_at", "note_text", "interrupted_by"]):
			return _fail("存档互动记录不完整")
		if not _is_integer(interaction.interaction_id) or interaction.interaction_id < 1 or interaction.interaction_id >= data.next_interaction_number or registry.has(interaction.interaction_id):
			return _fail("存档互动编号重复或无效")
		if not interaction.action_id is String or interaction.action_id not in PAIR_ACTIONS or interaction.action_id not in phase_scope.enabled_actions:
			return _fail("存档互动动作尚未开放")
		if not _valid_participant(interaction.initiator_index) or not _valid_participant(interaction.target_index) or interaction.initiator_index == interaction.target_index:
			return _fail("存档互动参与者无效")
		if not interaction.note_text is String or (interaction.action_id == "send_note" and interaction.note_text.strip_edges().is_empty()) or (interaction.action_id != "send_note" and not interaction.note_text.is_empty()):
			return _fail("存档纸条内容无效")
		if not interaction.status is String or interaction.status not in ["active", "completed", "interrupted"] or not _is_integer(interaction.interrupted_by) or interaction.interrupted_by < -1 or interaction.interrupted_by >= 4:
			return _fail("存档互动状态或打断者无效")
		var metadata_result: Error = _validate_pair_metadata(interaction)
		if metadata_result != OK:
			return metadata_result
		for key in ["started_at", "ends_at", "duration_s"]:
			if not _is_number(interaction[key]):
				return _fail("存档互动时间无效")
		if interaction.started_at < 0.0 or interaction.started_at > data.elapsed_s or interaction.duration_s <= 0.0 or absf(interaction.ends_at - interaction.started_at - interaction.duration_s) > 0.000001:
			return _fail("存档互动时序不一致")
		if interaction.status == "active":
			if interaction.finished_at != null or interaction.ends_at <= data.elapsed_s:
				return _fail("存档运行互动结束时序无效")
			for index in [interaction.initiator_index, interaction.target_index]:
				var action: Dictionary = data.students[int(index)].current_action
				if action.get("interaction_id") != interaction.interaction_id or action.action_id != interaction.action_id:
					return _fail("存档双人动作缺少对应参与者")
				for key in ["started_at", "ends_at", "duration_s"]:
					if absf(action[key] - interaction[key]) > 0.000001:
						return _fail("存档双人动作时间不一致")
		else:
			if not _is_number(interaction.finished_at) or interaction.finished_at < interaction.started_at or interaction.finished_at > data.elapsed_s or interaction.finished_at > interaction.ends_at + 0.000001:
				return _fail("存档历史互动结束时刻无效")
			# 完成结算由ends_at反向截断的段末触发，浮点累加允许百万分之一秒级别的同刻误差。
			if interaction.status == "completed" and absf(interaction.finished_at - interaction.ends_at) > 0.000001:
				return _fail("存档互动未执行到完成时刻")
		registry[interaction.interaction_id] = interaction
	for index in data.students.size():
		var action: Dictionary = data.students[index].current_action
		if action.has("interaction_id"):
			if not _is_integer(action.interaction_id) or not registry.has(action.interaction_id):
				return _fail("存档动作引用了不存在的互动")
			var interaction: Dictionary = registry[action.interaction_id]
			if interaction.status != "active" or (index != interaction.initiator_index and index != interaction.target_index):
				return _fail("存档动作引用了非运行互动或错误参与者")
	var delivered: Dictionary = {}
	for note in data.notes:
		if not note is Dictionary or not note.has_all(["interaction_id", "sender_index", "target_index", "text", "delivered_at"]) or not _is_integer(note.interaction_id) or not registry.has(note.interaction_id) or delivered.has(note.interaction_id):
			return _fail("存档聊天关联缺失或重复送达")
		var interaction: Dictionary = registry[note.interaction_id]
		if interaction.action_id != "send_note" or interaction.status != "completed" or not _valid_participant(note.sender_index) or not _valid_participant(note.target_index) or note.sender_index != interaction.initiator_index or note.target_index != interaction.target_index or not note.text is String or note.text != interaction.note_text or not _is_number(note.delivered_at) or absf(note.delivered_at - interaction.finished_at) > 0.000001:
			return _fail("存档聊天内容与真实完成结果不符")
		delivered[note.interaction_id] = true
	for interaction in data.interactions:
		if interaction.action_id == "send_note" and interaction.status == "completed" and not delivered.has(interaction.interaction_id):
			return _fail("存档已完成纸条缺少送达记录")
	var event_ids: Dictionary = {}
	var open_targets: Dictionary = {}
	var snapshot_context: Dictionary = _context_at(int(data.day), data.clock_seconds)
	var same_config: bool = data.config_fingerprint == config.fingerprint
	if same_config and snapshot_context.context_key != data.context_key:
		return _fail("存档课程上下文与当天时间不一致")
	for violation in data.violations:
		if not violation is Dictionary or not violation.has_all(["violation_id", "target_index", "started_at", "ended_at", "status", "action_ids", "action_instance_ids"]):
			return _fail("存档违纪事件不完整")
		if not _is_integer(violation.violation_id) or violation.violation_id < 1 or violation.violation_id >= data.next_violation_number or event_ids.has(violation.violation_id) or not _valid_participant(violation.target_index):
			return _fail("存档违纪事件身份无效")
		if not violation.status is String or violation.status not in ["open", "closed", "reported"] or not _is_number(violation.started_at) or violation.started_at < 0.0 or violation.started_at > data.elapsed_s:
			return _fail("存档违纪状态或开始时刻无效")
		if not violation.action_ids is Array or not violation.action_instance_ids is Array or violation.action_ids.is_empty() or violation.action_ids.size() != violation.action_instance_ids.size():
			return _fail("存档违纪涉及动作无效")
		var seen_instances: Dictionary = {}
		for index in violation.action_ids.size():
			var action_id: Variant = violation.action_ids[index]
			var instance_id: Variant = violation.action_instance_ids[index]
			# 历史分类保留发生当时的事实，不能用后来改表后的违纪分类否定过去。
			if not action_id is String or not config.actions.has(action_id) or not _is_integer(instance_id) or instance_id < 1 or instance_id >= data.next_action_number or seen_instances.has(instance_id):
				return _fail("存档违纪动作引用无效")
			seen_instances[instance_id] = true
		if violation.status == "open":
			var action: Dictionary = data.students[int(violation.target_index)].current_action
			if violation.ended_at != null or open_targets.has(int(violation.target_index)) or action.is_empty() or action.instance_id not in violation.action_instance_ids:
				return _fail("存档开放违纪没有匹配的当前动作")
			if same_config and (config.actions[action.action_id].violation != "distraction" or snapshot_context.kind != "lesson" or _action_location(action, snapshot_context) != "classroom"):
				return _fail("存档开放违纪不处于教室上课时间")
			var current_position: int = violation.action_instance_ids.find(action.instance_id)
			if violation.action_ids[current_position] != action.action_id:
				return _fail("存档开放违纪的当前动作身份不匹配")
			open_targets[int(violation.target_index)] = true
		elif not _is_number(violation.ended_at) or violation.ended_at < violation.started_at or violation.ended_at > data.elapsed_s:
			return _fail("存档违纪结束时刻无效")
		event_ids[violation.violation_id] = true
	for index in data.students.size():
		var action: Dictionary = data.students[index].current_action
		var requires_event: bool = not action.is_empty() and snapshot_context.kind == "lesson" and _action_location(action, snapshot_context) == "classroom" and config.actions[action.action_id].violation == "distraction"
		if same_config and requires_event and not open_targets.has(index):
			return _fail("存档课堂开小差缺少对应的连续违纪事件")
	return OK


## 旧纸条和基础橡皮按原契约读取；新动作的选科、快照与胜负必须完整且相互一致。
func _validate_pair_metadata(interaction: Dictionary) -> Error:
	var fields: Array[String] = ["selected_subject_id", "stamina_snapshot", "result"]
	var has_metadata: bool = false
	for field: String in fields:
		has_metadata = has_metadata or interaction.has(field)
	if not has_metadata and interaction.action_id in ["send_note", "eraser_prank"]:
		return OK
	if not interaction.has_all(fields) or not interaction.selected_subject_id is String or not interaction.stamina_snapshot is Dictionary or not interaction.result is Dictionary:
		return _fail("存档扩展互动的选科、体力快照或结果缺失")
	if interaction.action_id in ["swap_book", "swap_book_boost"]:
		if not _is_cultural_subject(interaction.selected_subject_id):
			return _fail("存档偷换课本缺少有效文化课科目")
	elif config.actions[interaction.action_id].knowledge_mode == "selected_subject":
		# 结伴自习等显式选科互动保存发起者的真实文化课。
		if not _is_cultural_subject(interaction.selected_subject_id):
			return _fail("存档显式选科互动缺少有效文化课科目")
	elif not interaction.selected_subject_id.is_empty():
		return _fail("存档非偷书互动不应包含换入科目")
	if interaction.action_id == "answer_challenge":
		return _validate_challenge_metadata(interaction)
	if interaction.action_id != "arm_wrestle":
		if not interaction.stamina_snapshot.is_empty() or not interaction.result.is_empty() or not (interaction.get("challenge_snapshot", {}) as Dictionary).is_empty():
			return _fail("存档普通互动含有无法归属的胜负快照或结果")
		return OK
	var snapshot: Dictionary = interaction.stamina_snapshot
	if snapshot.size() != 2 or not snapshot.has_all(["initiator", "target"]):
		return _fail("存档掰手腕必须记录双方发动时体力")
	for field: String in ["initiator", "target"]:
		if not _is_number(snapshot[field]) or snapshot[field] < 0.0:
			return _fail("存档掰手腕体力快照无效")
	if interaction.status == "completed":
		var actual: Dictionary = interaction.result
		if actual.size() != 3 or not actual.has_all(["outcome", "winner_index", "loser_index"]) or not actual.outcome is String or not _is_integer(actual.winner_index) or not _is_integer(actual.loser_index):
			return _fail("存档掰手腕结果字段无效")
		var expected: Dictionary = _arm_wrestle_result(interaction)
		if actual.outcome != expected.outcome or actual.winner_index != expected.winner_index or actual.loser_index != expected.loser_index:
			return _fail("存档掰手腕胜负与发动体力快照不符")
	elif not interaction.result.is_empty():
		return _fail("未完成的掰手腕不能保存胜负结果")
	return OK


## 抢答快照与结果校验：发动时记录双方该科知识与有效智力，完成结果必须由快照复算得出。
func _validate_challenge_metadata(interaction: Dictionary) -> Error:
	if not interaction.stamina_snapshot.is_empty():
		return _fail("存档抢答不应包含体力快照")
	var snapshot: Dictionary = interaction.challenge_snapshot
	if snapshot.size() != 5 or not snapshot.get("subject_id") is String or not _is_cultural_subject(String(snapshot.subject_id)):
		return _fail("存档抢答缺少有效的文化课快照")
	for field: String in ["initiator_knowledge", "target_knowledge"]:
		if not _is_number(snapshot[field]) or float(snapshot[field]) < 0.0:
			return _fail("存档抢答快照字段无效")
	# 有效智力可能被减益压到负数，只要求是有限数值即可复算。
	for field: String in ["initiator_intelligence", "target_intelligence"]:
		if not _is_number(snapshot[field]) or not is_finite(float(snapshot[field])):
			return _fail("存档抢答快照字段无效")
	if interaction.status == "completed":
		var actual: Dictionary = interaction.result
		if actual.size() != 3 or not actual.has_all(["outcome", "winner_index", "loser_index"]) or not actual.outcome is String or not _is_integer(actual.winner_index) or not _is_integer(actual.loser_index):
			return _fail("存档抢答结果字段无效")
		var expected: Dictionary = _answer_challenge_result(interaction)
		if actual.outcome != expected.outcome or actual.winner_index != expected.winner_index or actual.loser_index != expected.loser_index:
			return _fail("存档抢答胜负与发动快照不符")
	elif not interaction.result.is_empty():
		return _fail("未完成的抢答不能保存胜负结果")
	return OK


## 抢答判定只比较发动时快照：K×(1+考试智力系数×有效智力)，相对差在机器表示内判平局。
func _answer_challenge_result(interaction: Dictionary) -> Dictionary:
	var snapshot: Dictionary = interaction.challenge_snapshot
	var coefficient: float = float(config.global_value("exam_intelligence_coefficient"))
	var initiator_score: float = float(snapshot.initiator_knowledge) * (1.0 + coefficient * float(snapshot.initiator_intelligence))
	var target_score: float = float(snapshot.target_knowledge) * (1.0 + coefficient * float(snapshot.target_intelligence))
	var representation_error: float = maxf(5.0e-18, maxf(absf(initiator_score), absf(target_score)) * 1.0e-13)
	if absf(initiator_score - target_score) <= representation_error:
		return {"outcome": "tie", "winner_index": -1, "loser_index": -1}
	var initiator_wins: bool = initiator_score > target_score
	return {
		"outcome": "initiator" if initiator_wins else "target",
		"winner_index": int(interaction.initiator_index if initiator_wins else interaction.target_index),
		"loser_index": int(interaction.target_index if initiator_wins else interaction.initiator_index),
	}


## 所有互动参与者均来自本局固定四个角色，不接受小数索引或字符串。
func _valid_participant(value: Variant) -> bool:
	return _is_integer(value) and value >= 0 and value < 4


## JSON数字只接受有限数值，不隐式接受数字文本或布尔值。
func _is_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


## JSON会将整数解析为浮点数，此处按精确整数语义验证编号和数量。
func _is_integer(value: Variant) -> bool:
	return _is_number(value) and value == int(value)


## 只有待决策角色才请求共享行为树；执行中的动作不会被每帧重选。
func _fill_missing_actions() -> Error:
	if is_round_finished() or filling_actions:
		return OK
	filling_actions = true
	# 互动提交可能释放已经遍历过的旧搭档；每次重新找空位，避免嵌套tick同一棵树。
	while true:
		var missing: int = -1
		for index: int in students.size():
			if students[index].current_action.is_empty():
				missing = index
				break
		if missing < 0:
			break
		if not decision_handler.is_valid():
			filling_actions = false
			return _fail("共享行为树尚未接入，不能开始自主活动")
		decision_handler.call(missing)
		schedule_returns.erase(missing)
		if students[missing].current_action.is_empty():
			filling_actions = false
			return _fail("行为树没有为%s选择有效动作：%s" % [students[missing].name, error_message])
	filling_actions = false
	schedule_returns.clear()
	for index in students.size():
		_sync_violation(index)
	return OK


## 调表和跨配置读档重新核验真实自由时段，保留已得收益并明确记录中断原因。
func _end_unavailable_dorm_actions(reason: String) -> Error:
	for index in students.size():
		var action: Dictionary = students[index].current_action
		if not action.is_empty() and config.actions[action.action_id].eligible_period == "dorm_free" and not is_dorm_free_time(index):
			var result: Error = _end_action(index, false, reason)
			if result != OK:
				return result
	return OK


## 计算当前宿舍活动每秒净资源变化，费率始终读取当前配置和有效资源上限。
func _dorm_resource_rates(index: int) -> Dictionary:
	var rates: Dictionary = {"focus": 0.0, "stamina": 0.0}
	var action: Dictionary = students[index].current_action
	var context: Dictionary = course_context()
	for effect: Dictionary in config.phase_effects(action.action_id, "tick"):
		if _condition_matches(effect.condition, action.natural_entry, context):
			rates[effect.resource] += _resource_effect_value(index, effect) / effect.period_s
	return rates


## 耗尽时刻和动作到期同为真实边界，不能把零资源后的时间继续算成学习收益。
func _dorm_depletion_seconds(index: int) -> float:
	var action: Dictionary = students[index].current_action
	if config.actions[action.action_id].eligible_period != "dorm_free":
		return INF
	var next_seconds: float = INF
	var rates: Dictionary = _dorm_resource_rates(index)
	for resource: String in rates:
		if rates[resource] < 0.0:
			next_seconds = minf(next_seconds, students[index][resource] / -rates[resource])
	return next_seconds


## 资源真实耗尽时中断旧实例并保留已得知识，后续休息留到换课与终局判定之后。
func _end_exhausted_dorm_actions(recovery: Array[int]) -> Error:
	for index in students.size():
		var action: Dictionary = students[index].current_action
		if action.is_empty() or config.actions[action.action_id].eligible_period != "dorm_free":
			continue
		var exhausted: PackedStringArray = []
		for effect: Dictionary in config.phase_effects(action.action_id, "tick"):
			if effect.value < 0.0 and _condition_matches(effect.condition, action.natural_entry, course_context()) and students[index][effect.resource] <= 0.0:
				var resource_name: String = "专注" if effect.resource == "focus" else "体力"
				if resource_name not in exhausted:
					exhausted.append(resource_name)
		if not exhausted.is_empty():
			var result: Error = _end_action(index, false, "、".join(exhausted) + "耗尽")
			if result != OK:
				return result
			if index not in recovery:
				recovery.append(index)
	return OK


## 已批准的恢复是可见的真实十分钟宿舍休息，上课或终局同刻不会再启动它。
func _start_dorm_recovery(indices: Array[int]) -> Error:
	for index: int in indices:
		if students[index].current_action.is_empty() and is_dorm_free_time(index):
			var result: Error = start_action(index, "dorm_rest", true, -1, "宿舍活动后休息")
			if result != OK:
				return result
			students[index].current_action.dorm_recovery = true
			_log(index, "dorm_recovery", "宿舍活动结束，休息后再次自主选择", {
				"instance_id": students[index].current_action.instance_id,
				"duration_s": students[index].current_action.duration_s,
			})
	return OK


## 在状态及课表保持不变的区间，按真实秒数计算资源与知识。
func _settle_student(index: int, seconds: float, context: Dictionary) -> void:
	var student: Dictionary = students[index]
	var action: Dictionary = student.current_action
	var definition: Dictionary = config.actions[action.action_id]
	var resources_before: Dictionary = {"focus": student.focus, "stamina": student.stamina}
	var stamina_before: float = student.stamina
	var stamina_rate: float = 0.0
	for effect in config.phase_effects(action.action_id, "tick"):
		var applies: bool = effect.recipient == "self"
		if action.has("interaction_id"):
			var interaction: Dictionary = _interaction_by_id(action.interaction_id)
			applies = index in _effect_recipients(effect.recipient, interaction.initiator_index, interaction.target_index)
		if applies and _condition_matches(effect.condition, action.natural_entry, context):
			var amount: float = _resource_effect_value(index, effect) * seconds / effect.period_s
			if effect.resource == "stamina":
				stamina_rate += amount / seconds
			_change_resource(index, effect.resource, amount, true)
	if definition.eligible_period == "dorm_free":
		var rates: Dictionary = _dorm_resource_rates(index)
		for resource: String in rates:
			if rates[resource] < 0.0 and seconds >= resources_before[resource] / -rates[resource] and student[resource] != 0.0:
				# 边界已按真实耗尽时刻截断；消除浮点减法余量，避免产生零时长循环。
				_change_resource(index, resource, -student[resource], true)
	var knowledge_subject: String = ""
	if definition.knowledge_mode == "course" and context.subject_kind == "knowledge" and action.subject_id == context.subject_id:
		knowledge_subject = context.subject_id
	elif definition.knowledge_source == "dorm":
		knowledge_subject = action.subject_id
	if not knowledge_subject.is_empty():
		var threshold: float = config.global_value("sleep_stamina_threshold")
		var tired_seconds: float = seconds if stamina_before < threshold else 0.0
		if stamina_rate < 0.0 and stamina_before >= threshold and stamina_before + stamina_rate * seconds < threshold:
			tired_seconds = seconds - (threshold - stamina_before) / stamina_rate
		elif stamina_rate > 0.0 and stamina_before < threshold and stamina_before + stamina_rate * seconds >= threshold:
			tired_seconds = (threshold - stamina_before) / stamina_rate
		var effective_seconds: float = seconds - tired_seconds * (1.0 - config.global_value("tired_knowledge_multiplier"))
		var multiplier: float = 1.0 + config.global_value("learning_focus_coefficient") * effective_attribute(index, "attention")
		var gained_subject: String = knowledge_subject
		for buff in student.buffs:
			multiplier *= config.buffs[buff.buff_id].knowledge_multiplier
			# 课外选科始终按动作中的真实选择到账，错误课本只重定向在校课程来源。
			if definition.knowledge_source == "school" and config.buffs[buff.buff_id].knowledge_redirect == "selected_subject":
				gained_subject = buff.selected_subject_id
		var gain: float = config.subjects[knowledge_subject].base_rate_per_min * multiplier * definition.knowledge_multiplier * effective_seconds / 60.0
		student.knowledge[gained_subject] += gain
		action.knowledge_gain += gain
		if definition.knowledge_source == "dorm":
			round_progression.add_dorm_knowledge(day, gained_subject, student.id, action.action_id, gain)
		else:
			round_progression.add_knowledge(day, gained_subject, student.id, gain)
	action.last_settled_at = elapsed_s + seconds


## 按配表阶段执行效果；完成接续先登记，等旧实例结算清理后才建立新动作。
func _apply_phase(index: int, action_id: String, phase: String, natural_entry: bool, completion_routes: Array = []) -> Error:
	var context: Dictionary = course_context()
	for effect in config.phase_effects(action_id, phase):
		if not _condition_matches(effect.condition, natural_entry, context):
			continue
		match effect.type:
			"resource":
				_change_resource(index, effect.resource, _resource_effect_value(index, effect), phase != "instant" and not students[index].current_action.is_empty())
			"apply_buff":
				_apply_buff(index, effect.buff_id)
			"consume_item":
				# 发动入口已整体核验资源和同物品合计；此处只提交真实成功启动的扣物。
				var quantity: int = int(effect.value)
				students[index].inventory[effect.item_id] -= quantity
				_log(index, "consume_item", "使用%s × %d" % [config.items[effect.item_id].name, quantity], {
					"action_id": action_id, "instance_id": students[index].current_action.instance_id,
					"item_id": effect.item_id, "quantity": quantity, "remaining": students[index].inventory[effect.item_id],
				})
			"start_action":
				if phase == "complete":
					completion_routes.append(effect)
					continue
				var next_id: String = context.default_action_id if effect.next_action_id == "current_course" else effect.next_action_id
				var result: Error = start_action(index, next_id, effect.event == "natural_entry", index, "专注指令" if action_id == "focus_command" else "后续动作")
				if result != OK:
					return result
			_:
				return _fail("当前执行器不支持效果：%s" % effect.id)
	return OK


## 完成和打断共用结束入口，正常完成的接续指令留给统一边界流程处理。
func _end_action(index: int, completed: bool, reason: String, interrupted_by: int = -1, deferred_routes: Array = []) -> Error:
	var instance: Dictionary = students[index].current_action
	if instance.has("interaction_id"):
		return _end_interaction(instance.interaction_id, completed, reason, interrupted_by, deferred_routes)
	var completion_routes: Array = []
	if completed:
		var result: Error = _apply_phase(index, instance.action_id, "complete", instance.natural_entry, completion_routes)
		if result != OK:
			return result
	_finish_action_instance(index, instance, completed, reason, interrupted_by)
	# 旧动作只结束一次；后续动作等到换课、状态到期和终局都处理完才取得新实例。
	for effect: Dictionary in completion_routes:
		deferred_routes.append({"student_index": index, "effect": effect})
	return OK


## 清理确切动作实例；旧结束处理不能覆盖已经接管该角色的新动作。
func _finish_action_instance(index: int, instance: Dictionary, completed: bool, reason: String, interrupted_by: int) -> void:
	var details: Dictionary = {
		"action_id": instance.action_id, "executed_s": elapsed_s - instance.started_at,
		"resource_changes": instance.resource_changes.duplicate(true), "knowledge_gain": instance.knowledge_gain,
		"instance_id": instance.instance_id, "interrupted_by": interrupted_by,
		"subject_id": instance.subject_id, "knowledge_source": config.actions[instance.action_id].knowledge_source,
	}
	if instance.has("interaction_id"):
		details.interaction_id = instance.interaction_id
		var interaction: Dictionary = _interaction_by_id(instance.interaction_id)
		details.initiator_index = interaction.initiator_index
		details.target_index = interaction.target_index
	_log(index, "complete" if completed else "interrupt", "%s：%s" % [reason, config.actions[instance.action_id].name], details)
	if not students[index].current_action.is_empty() and students[index].current_action.instance_id == instance.instance_id:
		students[index].current_action = {}
	var remaining_buffs: Array = []
	for buff in students[index].buffs:
		if buff.action_instance_id != instance.instance_id:
			remaining_buffs.append(buff)
	students[index].buffs = remaining_buffs
	_clamp_resources_after_max_change(index)


## 双人结束只执行一遍完成效果，然后清理两位参与者的旧实例。
func _end_interaction(interaction_id: int, completed: bool, reason: String, interrupted_by: int, deferred_routes: Array = []) -> Error:
	var interaction: Dictionary = _interaction_by_id(interaction_id)
	if interaction.is_empty() or interaction.status != "active":
		return _fail("双人动作缺少有效运行记录：%s" % interaction_id)
	if completed:
		var applied: Error = _apply_targeted_phase(interaction.initiator_index, interaction.target_index, interaction.action_id, "complete", interaction, deferred_routes)
		if applied != OK:
			return applied
	for index in [interaction.initiator_index, interaction.target_index]:
		var instance: Dictionary = students[index].current_action
		if instance.get("interaction_id") != interaction_id:
			return _fail("双人动作参与者关联损坏：%s" % interaction_id)
		_finish_action_instance(index, instance, completed, reason, interrupted_by)
	interaction.status = "completed" if completed else "interrupted"
	interaction.finished_at = elapsed_s
	interaction.interrupted_by = interrupted_by
	var result_text: String = "纸条已送达" if completed else "纸条未送达"
	if interaction.action_id != "send_note":
		result_text = "%s%s" % [config.actions[interaction.action_id].name, "完成" if completed else "被打断，未结算完成效果"]
		if completed and interaction.action_id in ["arm_wrestle", "answer_challenge"]:
			result_text += "，平局" if interaction.result.outcome == "tie" else "，%s获胜" % students[int(interaction.result.winner_index)].name
	_log(interaction.initiator_index, "interaction_end", "%s → %s：%s（%s）" % [students[interaction.initiator_index].name, students[interaction.target_index].name, result_text, reason], interaction.duplicate(true))
	return OK


## 将配表对象投影到真实参与者，both不会因双方各持一份动作而重复结算。
func _effect_recipients(recipient: String, initiator_index: int, target_index: int, payload: Dictionary = {}) -> Array:
	match recipient:
		"self": return [initiator_index]
		"target": return [target_index]
		"both": return [initiator_index, target_index]
		"winner": return [] if payload.result.winner_index < 0 else [int(payload.result.winner_index)]
		"loser": return [] if payload.result.loser_index < 0 else [int(payload.result.loser_index)]
	assert(false, "未通过入口校验的效果对象：%s" % recipient)
	return []


## 按原配表顺序执行互动阶段，瞬时举报不会写进举报者的持续动作。
func _apply_targeted_phase(initiator_index: int, target_index: int, action_id: String, phase: String, payload: Dictionary, deferred_routes: Array = []) -> Error:
	var context: Dictionary = course_context()
	for effect in config.phase_effects(action_id, phase):
		if effect.condition in ["winner", "loser", "tie"]:
			if (effect.condition == "tie") != (payload.result.outcome == "tie"):
				continue
		elif not _condition_matches(effect.condition, true, context):
			continue
		# 双方事件属于一次互动，先确定结果，不能因both对象重复求值或发奖。
		if effect.type == "event" and effect.event == "resolve_arm_wrestle":
			payload.result = _arm_wrestle_result(payload)
			continue
		if effect.type == "event" and effect.event == "resolve_answer_challenge":
			payload.result = _answer_challenge_result(payload)
			continue
		for index in _effect_recipients(effect.recipient, initiator_index, target_index, payload):
			match effect.type:
				"resource":
					var before: float = students[index][effect.resource]
					var requested: float = _resource_effect_value(index, effect)
					_change_resource(index, effect.resource, requested, phase != "instant")
					_log(index, "interaction_resource", "%s：%s%+.2f" % [config.actions[action_id].name, "专注" if effect.resource == "focus" else "体力", students[index][effect.resource] - before], {
						"action_id": action_id, "phase": phase, "resource": effect.resource,
						"requested": requested, "actual": students[index][effect.resource] - before,
						"current": students[index][effect.resource], "maximum": get_resource_max(index, effect.resource),
						"initiator_index": initiator_index, "target_index": target_index,
					})
				"event":
					if effect.event == "deliver_note":
						notes.append({"interaction_id": payload.interaction_id, "sender_index": initiator_index, "target_index": target_index, "text": payload.note_text, "delivered_at": elapsed_s})
					elif effect.event == "close_violation":
						_close_violation(_violation_by_id(payload.violation_id), "reported", "被举报")
					else:
						return _fail("当前互动执行器不支持事件：%s" % effect.id)
				"start_action":
					if phase == "complete":
						deferred_routes.append({"student_index": index, "effect": effect})
						continue
					var next_id: String = context.default_action_id if effect.next_action_id == "current_course" else effect.next_action_id
					var result: Error = start_action(index, next_id, effect.event == "natural_entry", initiator_index, "被举报")
					if result != OK:
						return result
				"consume_item":
					var quantity: int = int(effect.value)
					students[index].inventory[effect.item_id] -= quantity
					_log(index, "consume_item", "使用%s × %d" % [config.items[effect.item_id].name, quantity], {
						"action_id": action_id, "interaction_id": payload.interaction_id,
						"item_id": effect.item_id, "quantity": quantity, "remaining": students[index].inventory[effect.item_id],
					})
				"apply_buff":
					_apply_buff(index, effect.buff_id, String(payload.selected_subject_id) if config.buffs[effect.buff_id].knowledge_redirect == "selected_subject" else "")
				_:
					return _fail("当前互动执行器不支持效果：%s" % effect.id)
	return OK


## 结果只比较已经记录的发动体力，不在完成时重新取值或消耗随机数。
func _arm_wrestle_result(interaction: Dictionary) -> Dictionary:
	var initiator_stamina: float = interaction.stamina_snapshot.initiator
	var target_stamina: float = interaction.stamina_snapshot.target
	if initiator_stamina == target_stamina:
		return {"outcome": "tie", "winner_index": -1, "loser_index": -1}
	var initiator_wins: bool = initiator_stamina > target_stamina
	return {
		"outcome": "initiator" if initiator_wins else "target",
		"winner_index": int(interaction.initiator_index if initiator_wins else interaction.target_index),
		"loser_index": int(interaction.target_index if initiator_wins else interaction.initiator_index),
	}


## 连续课堂开小差沿用事件编号；离开违纪后关闭，下一次另建事件。
func _sync_violation(index: int) -> void:
	var current: Dictionary = {}
	for violation in violations:
		if violation.target_index == index and violation.status == "open":
			current = violation
			break
	if not _is_classroom_distraction(index):
		if not current.is_empty():
			_close_violation(current, "closed", "回归课表或离开课堂开小差")
		return
	var action: Dictionary = students[index].current_action
	if current.is_empty():
		current = {
			"violation_id": next_violation_number, "target_index": index,
			"started_at": action.started_at, "ended_at": null, "status": "open",
			"action_ids": [], "action_instance_ids": [],
		}
		next_violation_number += 1
		violations.append(current)
		_log(index, "violation_start", "开始一次课堂开小差", {"violation_id": current.violation_id, "action_id": action.action_id})
	if action.instance_id not in current.action_instance_ids:
		current.action_instance_ids.append(action.instance_id)
		current.action_ids.append(action.action_id)


## 只有课堂内真实的开小差动作才形成可举报事件。
func _is_classroom_distraction(index: int) -> bool:
	var action: Dictionary = students[index].current_action
	return not action.is_empty() and course_context().kind == "lesson" and student_location(index) == "classroom" and config.actions[action.action_id].violation == "distraction"


## 事件结束保留处理结果，重复请求不能重新打开或再次结算。
func _close_violation(violation: Dictionary, status: String, reason: String) -> void:
	assert(not violation.is_empty() and violation.status == "open", "违纪事件不处于开放状态")
	violation.status = status
	violation.ended_at = elapsed_s
	_log(violation.target_index, "violation_end", "本次开小差结束：%s" % reason, {"violation_id": violation.violation_id, "status": status})


## 查询历史记录保留字典引用，仅供权威执行器内部修改。
func _interaction_by_id(interaction_id: int) -> Dictionary:
	for interaction in interactions:
		if interaction.interaction_id == interaction_id:
			return interaction
	return {}


## 通过业务事件编号定位原违纪，不借用当前新事件代替旧请求。
func _violation_by_id(violation_id: int) -> Dictionary:
	for violation in violations:
		if violation.violation_id == violation_id:
			return violation
	return {}


## 条件只来自明确的动作上下文，不添加隐式的频率或资源限制。
func _condition_matches(condition: String, natural_entry: bool, context: Dictionary) -> bool:
	match condition:
		"always": return true
		"natural_entry": return natural_entry
		"course_active": return context.kind == "lesson"
	return false


## 比例资源在发生当刻读取上限，不能锁定为发动时的上限。
func _resource_effect_value(index: int, effect: Dictionary) -> float:
	return effect.value * get_resource_max(index, effect.resource) if effect.mode == "max_ratio" else effect.value


## 资源上下限是已确认业务规则；累计请求与实际变化供动作结束日志使用。
func _change_resource(index: int, resource: String, requested: float, accumulate: bool) -> void:
	var before: float = students[index][resource]
	var maximum: float = get_resource_max(index, resource)
	students[index][resource] = clampf(before + requested, 0.0, maximum)
	if accumulate:
		var changes: Dictionary = students[index].current_action.resource_changes
		if not changes.has(resource):
			changes[resource] = {"requested": 0.0, "actual": 0.0, "current": before, "maximum": maximum}
		changes[resource].requested += requested
		changes[resource].actual += students[index][resource] - before
		changes[resource].current = students[index][resource]
		changes[resource].maximum = maximum


## 日程所需的自身状态也按Buff配表生效，不能跳过完成奖励。
func _apply_buff(index: int, buff_id: String, selected_subject_id: String = "") -> void:
	var definition: Dictionary = config.buffs[buff_id]
	if definition.stacking in ["refresh", "replace"]:
		var retained: Array = []
		for buff in students[index].buffs:
			if config.buffs[buff.buff_id].stack_group != definition.stack_group:
				retained.append(buff)
		students[index].buffs = retained
	var expiration: Variant = elapsed_s + definition.duration_s if definition.lifecycle == "timed" else null
	var action_id: Variant = students[index].current_action.instance_id if definition.lifecycle == "action" else null
	var instance: Dictionary = {"buff_id": buff_id, "expires_at": expiration, "action_instance_id": action_id}
	if definition.knowledge_redirect == "selected_subject":
		instance.selected_subject_id = selected_subject_id
	students[index].buffs.append(instance)
	_clamp_resources_after_max_change(index)
	var details: Dictionary = {"buff_id": buff_id}
	var subject_text: String = ""
	if definition.knowledge_redirect == "selected_subject":
		details.selected_subject_id = selected_subject_id
		subject_text = "，知识转入%s" % config.subjects[selected_subject_id].name
	_log(index, "buff", "获得状态：%s%s" % [definition.name, subject_text], details)


## 独立状态到期只移除修正，不撤销过去的资源或知识。
func _expire_buffs(index: int) -> void:
	var retained: Array = []
	var changed: bool = false
	for buff in students[index].buffs:
		if buff.expires_at != null and buff.expires_at <= elapsed_s:
			_log(index, "buff", "状态结束：%s" % config.buffs[buff.buff_id].name, {"buff_id": buff.buff_id})
			changed = true
		else:
			retained.append(buff)
	students[index].buffs = retained
	if changed:
		_clamp_resources_after_max_change(index)


## 上限提高不赠送资源，上限降低只裁去超出的绝对量并如实记录。
func _clamp_resources_after_max_change(index: int) -> void:
	for resource in ["focus", "stamina"]:
		var maximum: float = get_resource_max(index, resource)
		if students[index][resource] > maximum:
			var before: float = students[index][resource]
			students[index][resource] = maximum
			_log(index, "resource", "上限变化：%s减少%.2f" % ["专注" if resource == "focus" else "体力", before - maximum], {"resource": resource, "requested": maximum - before, "actual": maximum - before, "current": maximum, "maximum": maximum})


## 保存真实发生的事件，持续变化按动作累计，不生成逐帧噪声记录。
func _log(index: int, event_type: String, message: String, details: Dictionary) -> void:
	logs.append({"at": elapsed_s, "elapsed_s": elapsed_s, "day": day, "clock_seconds": clock_seconds, "student_index": index, "name": students[index].name if index >= 0 else "班级", "type": event_type, "message": message, "details": details})


## 为时段事件提供课程名称，保持界面与规则读取同一上下文。
func _context_label(context: Dictionary) -> String:
	return "%s · %s" % [context.period_name, context.subject_name] if not context.subject_name.is_empty() else context.period_name


## 开发日志使用与当前游戏时钟一致的时分秒。
func _format_clock() -> String:
	return "%02d:%02d:%02d" % [int(clock_seconds) / 3600, int(clock_seconds) / 60 % 60, int(clock_seconds) % 60]


## 所有失败交给调用方展示，不替换动作或伪造成功。
func _fail(message: String) -> Error:
	error_message = message
	return ERR_INVALID_DATA


## 玩家输入或业务前置条件失败可见返回，不能停止原本健康的游戏时钟。
func _reject(message: String, code: Error) -> Error:
	error_message = message
	return code
