class_name ClassroomSimulation
extends RefCounted
## 本地班级的权威规则入口；行为树和界面都只能通过这里改变动作。

const ConfigScript = preload("res://scripts/core/game_config.gd")
const ROUND = preload("res://scripts/core/round_progression.gd")
const ATTRIBUTE_KEYS: Array[String] = ["attention", "discipline", "health", "intelligence"]
# v4保存日榜、考试快照、终局及离线冻结来源，v3已有的领取日继续原样迁移。
const SAVE_VERSION: int = 4
const DAILY_COURSE_ACTIONS: Array[String] = ["study", "physical_study", "music_class", "art_class", "exam"]
# 持续互动的实现范围独立于自主候选，开放玩家入口不会让同学自动发起。
const PAIR_ACTIONS: Array[String] = [
	"send_note", "eraser_prank", "remind_friend", "solve_together",
	"invite_playground", "invite_canteen", "borrow_notes", "encourage",
	"pillow_fight", "feed_snack", "use_eraser", "give_comic_item",
	"give_candy_item", "swap_book", "swap_book_boost", "arm_wrestle",
]
# Godot整型的表示边界，仅用于防止数量溢出为负数，不限制背包格数或业务容量。
const MAX_ITEM_INTEGER: int = 9223372036854775807

# 四人的状态分别创建，不能共享当前动作、资源或知识字典。
var students: Array[Dictionary] = []
var config: RefCounted
var phase_scope: Dictionary = {}
var rng := RandomNumberGenerator.new()
var decision_handler: Callable
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
			# 保存全部已领日期，开发时钟回退后仍能识别曾领过的日子。
			"daily_item_claim_days": [],
		})
	_log(-1, "session", "新班级开始，四名同学自主活动", {"config_version": config.version})
	round_progression = ROUND.new()
	result = round_progression.setup(config, _round_participants(), day, clock_seconds)
	if result != OK:
		return _fail(round_progression.error_message)
	return OK


## 按实际经过秒数推进，并在动作、课表和状态边界分段结算。
func advance(delta_s: float) -> Error:
	if not is_finite(delta_s) or delta_s < 0.0:
		return _fail("推进时间必须是非负有限秒数")
	if is_round_finished():
		return OK
	var result: Error = _process_round_position()
	if result != OK or is_round_finished():
		return result
	result = _fill_missing_actions()
	if result != OK:
		return result
	var remaining: float = delta_s
	while remaining > 0.0:
		var old_context: Dictionary = course_context()
		var interval: float = minf(remaining, old_context.end_seconds - clock_seconds)
		interval = minf(interval, round_progression.next_boundary(day, clock_seconds) - clock_seconds)
		for student in students:
			interval = minf(interval, student.current_action.ends_at - elapsed_s)
			for buff in student.buffs:
				if buff.expires_at != null:
					interval = minf(interval, buff.expires_at - elapsed_s)
		if interval <= 0.0:
			return _fail("时间边界未被处理，不能继续推进：%s" % interval)
		for index in students.size():
			_settle_student(index, interval, old_context)
		elapsed_s += interval
		clock_seconds += interval
		remaining -= interval
		if clock_seconds >= 86400.0:
			clock_seconds -= 86400.0
			day += 1
		# 完成效果先于下一段决策发生，只有完整执行到结束的动作才能获得。
		var completion_routes: Array = []
		for index in students.size():
			if not students[index].current_action.is_empty() and students[index].current_action.ends_at <= elapsed_s:
				result = _end_action(index, true, "动作完成", -1, completion_routes)
				if result != OK:
					return result
			_expire_buffs(index)
		var new_context: Dictionary = course_context()
		if new_context.context_key != old_context.context_key:
			_log(-1, "course", "时段切换：%s" % _context_label(new_context), {"period_id": new_context.period_id})
			for index in students.size():
				if not students[index].current_action.is_empty():
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


## 行为树使用当前阶段允许且符合真实条件的开小差候选，权重保持配表原值。
func get_auto_candidates(student_index: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var context: Dictionary = course_context()
	if context.subject_kind != "knowledge":
		return result
	# 单科覆盖只替换本阶段候选名单，原配表权重和动作场景保持不变。
	var allowed: Array = phase_scope.subject_auto_actions.get(context.subject_id, phase_scope.auto_actions)
	for row in config.tables.auto_pool:
		if row.enabled and row.action_id in allowed and can_start_action(student_index, row.action_id):
			result.append(row)
	return result


## 查询实际发动前置条件，不扣物、不消耗随机流，也不结束角色已有动作。
func action_unavailable_reason(student_index: int, action_id: String, natural_entry: bool = true) -> String:
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
func can_start_action(student_index: int, action_id: String, natural_entry: bool = true) -> bool:
	return action_unavailable_reason(student_index, action_id, natural_entry).is_empty()


## 创建持续动作实例；只在这里抽时长，手动指令和行为树都复用这一入口。
func start_action(student_index: int, action_id: String, natural_entry: bool = true, interrupted_by: int = -1, reason: String = "主动切换") -> Error:
	var unavailable: String = action_unavailable_reason(student_index, action_id, natural_entry)
	if not unavailable.is_empty():
		return _reject(unavailable, ERR_UNAVAILABLE)
	var definition: Dictionary = config.actions[action_id]
	var leaves_pair: bool = students[student_index].current_action.has("interaction_id")
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
	next_action_number += 1
	students[student_index].current_action = instance
	var result: Error = _apply_phase(student_index, action_id, "start", natural_entry)
	if result != OK:
		return result
	_log(student_index, "start", "开始%s" % definition.name, {"action_id": action_id, "duration_s": duration, "natural_entry": natural_entry})
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
	elif not selected_subject_id.is_empty():
		return "这个互动不接受换入科目"
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
func start_interaction(initiator_index: int, target_index: int, action_id: String, note_text: String = "", selected_subject_id: String = "") -> Error:
	var unavailable: String = interaction_unavailable_reason(initiator_index, target_index, action_id, selected_subject_id)
	if not unavailable.is_empty():
		return _reject(unavailable, ERR_UNAVAILABLE)
	if action_id == "send_note" and note_text.strip_edges().is_empty():
		return _reject("请输入纸条内容", ERR_INVALID_PARAMETER)
	# 掰手腕只取真实发动时的体力；完成时不重新取值，不受之后恢复或调表影响。
	var stamina_snapshot: Dictionary = {}
	if action_id == "arm_wrestle":
		stamina_snapshot = {"initiator": students[initiator_index].stamina, "target": students[target_index].stamina}
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
	}
	next_interaction_number += 1
	interactions.append(interaction)
	for index in [initiator_index, target_index]:
		students[index].current_action = {
			"instance_id": next_action_number, "interaction_id": interaction.interaction_id,
			"action_id": action_id, "started_at": elapsed_s, "ends_at": interaction.ends_at,
			"duration_s": duration, "last_settled_at": elapsed_s, "subject_id": course_context().subject_id,
			"natural_entry": true, "resource_changes": {}, "knowledge_gain": 0.0,
		}
		next_action_number += 1
	var result: Error = _apply_targeted_phase(initiator_index, target_index, action_id, "start", interaction)
	if result != OK:
		return result
	_log(initiator_index, "interaction_start", "%s → %s：%s%s" % [students[initiator_index].name, students[target_index].name, definition.name, "（尚未送达）" if action_id == "send_note" else ""], interaction.duplicate(true))
	return _fill_missing_actions()


## 地点使用动作和当前课表，供场景前置条件与可视化共用。
func student_location(student_index: int) -> String:
	return _action_location(students[student_index].current_action, course_context())


## 实时动作与快照动作共用地点规则，避免存档校验引入另一份场景推测。
func _action_location(action: Dictionary, context: Dictionary) -> String:
	if action.get("action_id") == "invite_playground":
		return "playground"
	if action.get("action_id") == "invite_canteen":
		return "canteen"
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


## 新配置通过完整入口校验后立即接管费率，不重收启动费或改写在途时长。
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
	var snapshot: Dictionary = {
		"save_version": SAVE_VERSION, "config_fingerprint": config.fingerprint, "config_version": config.version,
		"created_date": created_date, "day": day, "clock_seconds": clock_seconds, "elapsed_s": elapsed_s,
		"context_key": course_context().context_key, "students": students, "logs": logs,
		"rng_seed": str(rng.seed), "rng_state": str(rng.state), "next_action_number": next_action_number,
		"interactions": interactions, "notes": notes, "violations": violations,
		"next_interaction_number": next_interaction_number, "next_violation_number": next_violation_number,
		"round_progression": round_progression.encoded(),
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
	if data.save_version == SAVE_VERSION:
		if not data.has("round_progression"):
			return _fail("v4存档缺少七天结算账本")
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
		# v1/v2从未持久化领取记录；迁移只建空记录，不从库存猜测，也不重启当前课程补发。
		if data.save_version < 3:
			student.daily_item_claim_days = []
		else:
			# JSON整数可能解析为浮点数，边界归一为整数，确保后续日期成员检查保持幂等。
			var claim_days: Array[int] = []
			for claim_day in student.daily_item_claim_days:
				claim_days.append(int(claim_day))
			student.daily_item_claim_days = claim_days
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
	var committed: Error = _commit_round_events(candidate_events)
	if committed != OK:
		return committed
	if data.config_fingerprint != config.fingerprint:
		_log(-1, "config", "配置已更新：新费率立即使用，当前动作时长保留", {"old_version": data.config_version, "new_version": config.version})
		for index in students.size():
			_clamp_resources_after_max_change(index)
			_sync_violation(index)
	_log(-1, "save", "已读取本地存档，关闭期间不推进资源与知识", {})
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
			var result_recipient: bool = pair and action_id == "arm_wrestle" and effect.phase == "complete" and effect.recipient in ["winner", "loser"] and effect.condition == effect.recipient
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
			if effect.type == "event" and not ((action_id == "send_note" and effect.phase == "complete" and effect.event == "deliver_note" and effect.recipient == "target") or (action_id == "report" and effect.phase == "instant" and effect.event == "close_violation" and effect.recipient == "target") or (action_id == "arm_wrestle" and effect.phase == "complete" and effect.event == "resolve_arm_wrestle" and effect.recipient == "both")):
				return _fail("当前阶段尚未实现事件：%s" % effect.id)
			if effect.type == "event" and effect.condition != "always":
				return _fail("送达与关闭违纪事件必须无条件执行：%s" % effect.id)
			if pair and effect.type == "start_action" and not ((action_id == "report" and effect.phase == "instant") or (action_id == "remind_friend" and effect.phase == "complete")):
				return _fail("当前阶段尚未实现互动后续动作：%s" % effect.id)
			if pair and effect.type == "start_action" and (effect.recipient != "target" or effect.next_action_id != "current_course" or effect.event != "forced_entry"):
				return _fail("互动后续动作必须明确强制目标回当前课表：%s" % effect.id)
			if pair and effect.type == "start_action" and effect.condition != "always":
				return _fail("举报后的强制回课堂必须无条件执行：%s" % effect.id)
			if effect.condition not in ["always", "natural_entry", "course_active"] and not (action_id == "arm_wrestle" and effect.phase == "complete" and effect.condition in ["winner", "loser", "tie"]):
				return _fail("当前阶段尚未实现效果条件：%s" % effect.id)
			if effect.phase == "tick" and effect.type != "resource":
				return _fail("当前阶段持续效果只支持资源连续结算：%s" % effect.id)
		if self_route_count > 1:
			return _fail("个人动作只能包含一个明确的后续动作：%s" % action_id)
		# 业务事件必须有且只有一次，避免调表把同一纸条送达两次或重复结束违纪。
		if action_id in ["send_note", "report", "arm_wrestle", "remind_friend"]:
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
	return OK


## 存档作为不可信边界统一校验，损坏内容不能流入后续结算并伪装成功。
func _validate_snapshot(data: Dictionary) -> Error:
	var required: Array = ["save_version", "config_fingerprint", "config_version", "created_date", "day", "clock_seconds", "elapsed_s", "context_key", "students", "logs", "rng_seed", "rng_state", "next_action_number"]
	if not data.has_all(required) or (data.save_version != 1 and data.save_version != 2 and data.save_version != 3 and data.save_version != SAVE_VERSION):
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
	elif not interaction.selected_subject_id.is_empty():
		return _fail("存档非偷书互动不应包含换入科目")
	if interaction.action_id != "arm_wrestle":
		if not interaction.stamina_snapshot.is_empty() or not interaction.result.is_empty():
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
	if is_round_finished():
		return OK
	for index in students.size():
		if students[index].current_action.is_empty():
			if not decision_handler.is_valid():
				return _fail("共享行为树尚未接入，不能开始自主活动")
			decision_handler.call(index)
			if students[index].current_action.is_empty():
				return _fail("行为树没有为%s选择有效动作：%s" % [students[index].name, error_message])
	for index in students.size():
		_sync_violation(index)
	return OK


## 在状态及课表保持不变的区间，按真实秒数计算资源与知识。
func _settle_student(index: int, seconds: float, context: Dictionary) -> void:
	var student: Dictionary = students[index]
	var action: Dictionary = student.current_action
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
	var definition: Dictionary = config.actions[action.action_id]
	if context.subject_kind == "knowledge" and action.subject_id == context.subject_id and definition.knowledge_multiplier > 0.0:
		var threshold: float = config.global_value("sleep_stamina_threshold")
		var tired_seconds: float = seconds if stamina_before < threshold else 0.0
		if stamina_rate < 0.0 and stamina_before >= threshold and stamina_before + stamina_rate * seconds < threshold:
			tired_seconds = seconds - (threshold - stamina_before) / stamina_rate
		elif stamina_rate > 0.0 and stamina_before < threshold and stamina_before + stamina_rate * seconds >= threshold:
			tired_seconds = (threshold - stamina_before) / stamina_rate
		var effective_seconds: float = seconds - tired_seconds * (1.0 - config.global_value("tired_knowledge_multiplier"))
		var multiplier: float = 1.0 + config.global_value("learning_focus_coefficient") * effective_attribute(index, "attention")
		var gained_subject: String = context.subject_id
		for buff in student.buffs:
			multiplier *= config.buffs[buff.buff_id].knowledge_multiplier
			if config.buffs[buff.buff_id].knowledge_redirect == "selected_subject":
				gained_subject = buff.selected_subject_id
		var gain: float = config.subjects[context.subject_id].base_rate_per_min * multiplier * definition.knowledge_multiplier * effective_seconds / 60.0
		student.knowledge[gained_subject] += gain
		action.knowledge_gain += gain
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
		if completed and interaction.action_id == "arm_wrestle":
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
