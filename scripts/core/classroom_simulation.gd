class_name ClassroomSimulation
extends RefCounted
## 本地班级的权威规则入口；行为树和界面都只能通过这里改变动作。

const ConfigScript = preload("res://scripts/core/game_config.gd")
const ATTRIBUTE_KEYS: Array[String] = ["attention", "discipline", "health", "intelligence"]

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
	students.clear()
	logs.clear()
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
		})
	_log(-1, "session", "新班级开始，四名同学自主活动", {"config_version": config.version})
	return OK


## 按实际经过秒数推进，并在动作、课表和状态边界分段结算。
func advance(delta_s: float) -> Error:
	if not is_finite(delta_s) or delta_s < 0.0:
		return _fail("推进时间必须是非负有限秒数")
	var result: Error = _fill_missing_actions()
	if result != OK:
		return result
	var remaining: float = delta_s
	while remaining > 0.0:
		var old_context: Dictionary = course_context()
		var interval: float = minf(remaining, old_context.end_seconds - clock_seconds)
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
		for index in students.size():
			if not students[index].current_action.is_empty() and students[index].current_action.ends_at <= elapsed_s:
				result = _end_action(index, true, "动作完成")
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
		result = _fill_missing_actions()
		if result != OK:
			return result
	return OK


## 返回当前课表上下文，非课时也有明确的默认休息动作和下一边界。
func course_context() -> Dictionary:
	var result: Dictionary = {
		"period_id": "outside", "period_name": "课外休息", "kind": "outside",
		"subject_id": "", "subject_name": "", "subject_kind": "", "default_action_id": "dorm_rest",
		"end_seconds": 86400.0, "context_key": "%s/outside" % day,
	}
	for period in config.periods:
		var start: float = roundf(period.start_time * 86400.0)
		var finish: float = roundf(period.end_time * 86400.0)
		if clock_seconds < start:
			result.end_seconds = start
			return result
		if clock_seconds >= finish:
			continue
		result.period_id = period.id
		result.period_name = period.name
		result.kind = period.kind
		result.default_action_id = period.default_action_id
		result.end_seconds = finish
		result.context_key = "%s/%s" % [day, period.id]
		if period.kind == "lesson":
			for row in config.tables.schedule:
				if int(row.day) == day and row.period_id == period.id:
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


## 在边界统一检查动作是否已开放、可支付且适用于当前时段。
func can_start_action(student_index: int, action_id: String, natural_entry: bool = true) -> bool:
	if student_index < 0 or student_index >= students.size() or action_id not in phase_scope.enabled_actions:
		return false
	var definition: Dictionary = config.actions[action_id]
	if not definition.enabled or definition.target != "self":
		return false
	var context: Dictionary = course_context()
	if action_id in ["study", "physical_study"] and context.subject_kind != "knowledge":
		return false
	if action_id in ["music_class", "art_class", "exam"] and context.default_action_id != action_id:
		return false
	var costs: Dictionary = {"focus": 0.0, "stamina": 0.0}
	for effect in config.phase_effects(action_id, "start"):
		if effect.type == "resource" and _condition_matches(effect.condition, natural_entry, context):
			var value: float = _resource_effect_value(student_index, effect)
			if value < 0.0:
				costs[effect.resource] += -value
	return students[student_index].focus >= costs.focus and students[student_index].stamina >= costs.stamina


## 创建持续动作实例；只在这里抽时长，手动指令和行为树都复用这一入口。
func start_action(student_index: int, action_id: String, natural_entry: bool = true) -> Error:
	if not can_start_action(student_index, action_id, natural_entry):
		return _fail("角色%s当前不能发动动作%s" % [student_index, action_id])
	var definition: Dictionary = config.actions[action_id]
	if definition.kind != "duration":
		return _fail("%s不是持续动作，请使用对应瞬时指令入口" % action_id)
	if not students[student_index].current_action.is_empty():
		var interrupted: Error = _end_action(student_index, false, "主动切换")
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
	return OK


## 专注只允许玩家控制自己的角色；每次点击都按配表瞬时生效。
func focus_command(student_index: int = 0) -> Error:
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
	config = new_config
	config.phase_scope = phase_scope
	var result: Error = _validate_scope()
	if result != OK:
		return result
	for index in students.size():
		for instance in students[index].buffs:
			if not config.buffs.has(instance.buff_id):
				return _fail("新配置删除了仍在生效的状态：%s" % instance.buff_id)
		_clamp_resources_after_max_change(index)
	_log(-1, "config", "配置已更新：后续消耗恢复采用新值，本段时长保持不变", {"old_version": previous_version, "new_version": config.version})
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
	var snapshot: Dictionary = {
		"save_version": 1, "config_fingerprint": config.fingerprint, "config_version": config.version,
		"created_date": created_date, "day": day, "clock_seconds": clock_seconds, "elapsed_s": elapsed_s,
		"context_key": course_context().context_key, "students": students, "logs": logs,
		"rng_seed": str(rng.seed), "rng_state": str(rng.state), "next_action_number": next_action_number,
	}
	var global_path: String = ProjectSettings.globalize_path(path)
	var directory_result: Error = DirAccess.make_dir_recursive_absolute(global_path.get_base_dir())
	if directory_result != OK:
		return _fail("无法创建存档目录，错误码%s" % directory_result)
	var temporary_path: String = global_path + ".tmp"
	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		return _fail("无法写入存档：%s" % global_path)
	file.store_string(JSON.stringify(snapshot, "\t"))
	file.flush()
	file.close()
	var result: Error = DirAccess.rename_absolute(temporary_path, global_path)
	if result != OK:
		return _fail("无法替换存档，错误码%s" % result)
	return OK


## 恢复已有局；新费率立即生效，已抽时长、已发生结果和启动费保持不变。
func load_file(path: String, align_system_time: bool = true) -> Error:
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
	students.clear()
	for student in data.students:
		students.append(student)
	logs.clear()
	for entry in data.logs:
		logs.append(entry)
	created_date = data.created_date
	day = int(data.day)
	clock_seconds = data.clock_seconds
	elapsed_s = data.elapsed_s
	next_action_number = int(data.next_action_number)
	rng.seed = int(data.rng_seed)
	rng.state = int(data.rng_state)
	is_debug_time = not align_system_time
	if align_system_time:
		var now: Dictionary = Time.get_datetime_dict_from_system()
		var current_date: String = "%04d-%02d-%02d" % [now.year, now.month, now.day]
		day = int((Time.get_unix_time_from_datetime_string(current_date + "T00:00:00") - Time.get_unix_time_from_datetime_string(created_date + "T00:00:00")) / 86400) + 1
		clock_seconds = now.hour * 3600.0 + now.minute * 60.0 + now.second
		if day < 1:
			return _fail("电脑日期早于本局创建日期，请检查系统时间")
	if course_context().context_key != data.context_key:
		for index in students.size():
			if not students[index].current_action.is_empty():
				var result: Error = _end_action(index, false, "关闭期间跨课，未结算离线收益")
				if result != OK:
					return result
	if data.config_fingerprint != config.fingerprint:
		_log(-1, "config", "配置已更新：新费率立即使用，当前动作时长保留", {"old_version": data.config_version, "new_version": config.version})
		for index in students.size():
			_clamp_resources_after_max_change(index)
	_log(-1, "save", "已读取本地存档，关闭期间不推进资源与知识", {})
	return OK


## 显式开发入口只调整验证时钟，不制造已获得的知识、奖励或动作结果。
func set_debug_time(test_day: int, seconds: float) -> Error:
	if test_day < 1 or seconds < 0.0 or seconds >= 86400.0 or not is_finite(seconds):
		return _fail("开发时间必须是有效天数和当天秒数")
	for index in students.size():
		if not students[index].current_action.is_empty():
			var result: Error = _end_action(index, false, "开发时间切换")
			if result != OK:
				return result
	day = test_day
	clock_seconds = seconds
	is_debug_time = true
	_log(-1, "debug", "开发时间切换至第%s天%s" % [day, _format_clock()], {})
	return OK


## 显式验证推进复用生产结算流程，界面不得把它伪装为现实时间流逝。
func advance_for_test(seconds: float) -> Error:
	is_debug_time = true
	return advance(seconds)


## 启动时校验已开放内容，遇到当前执行器不支持的效果直接报错。
func _validate_scope() -> Error:
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
		if config.actions[action_id].target != "self":
			return _fail("阶段1/2尚未实现双人动作：%s" % action_id)
		for effect in config.effects_by_action[action_id]:
			if effect.recipient != "self" or effect.type not in ["resource", "apply_buff", "start_action"]:
				return _fail("当前阶段尚未实现效果：%s" % effect.id)
			if effect.condition not in ["always", "natural_entry", "course_active"]:
				return _fail("当前阶段尚未实现效果条件：%s" % effect.id)
			if effect.phase == "tick" and effect.type != "resource":
				return _fail("当前阶段持续效果只支持资源连续结算：%s" % effect.id)
	return OK


## 存档作为不可信边界统一校验，损坏内容不能流入后续结算并伪装成功。
func _validate_snapshot(data: Dictionary) -> Error:
	var required: Array = ["save_version", "config_fingerprint", "config_version", "created_date", "day", "clock_seconds", "elapsed_s", "context_key", "students", "logs", "rng_seed", "rng_state", "next_action_number"]
	if not data.has_all(required) or data.save_version != 1:
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
		for buff in student.buffs:
			if not buff is Dictionary or not buff.has_all(["buff_id", "expires_at", "action_instance_id"]) or not config.buffs.has(buff.buff_id):
				return _fail("存档状态引用无效")
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
	return OK


## JSON数字只接受有限数值，不隐式接受数字文本或布尔值。
func _is_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


## JSON会将整数解析为浮点数，此处按精确整数语义验证编号和数量。
func _is_integer(value: Variant) -> bool:
	return _is_number(value) and value == int(value)


## 只有待决策角色才请求共享行为树；执行中的动作不会被每帧重选。
func _fill_missing_actions() -> Error:
	for index in students.size():
		if students[index].current_action.is_empty():
			if not decision_handler.is_valid():
				return _fail("共享行为树尚未接入，不能开始自主活动")
			decision_handler.call(index)
			if students[index].current_action.is_empty():
				return _fail("行为树没有为%s选择有效动作：%s" % [students[index].name, error_message])
	return OK


## 在状态及课表保持不变的区间，按真实秒数计算资源与知识。
func _settle_student(index: int, seconds: float, context: Dictionary) -> void:
	var student: Dictionary = students[index]
	var action: Dictionary = student.current_action
	var stamina_before: float = student.stamina
	var stamina_rate: float = 0.0
	for effect in config.phase_effects(action.action_id, "tick"):
		if _condition_matches(effect.condition, action.natural_entry, context):
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
		for buff in student.buffs:
			multiplier *= config.buffs[buff.buff_id].knowledge_multiplier
		var gain: float = config.subjects[context.subject_id].base_rate_per_min * multiplier * definition.knowledge_multiplier * effective_seconds / 60.0
		student.knowledge[context.subject_id] += gain
		action.knowledge_gain += gain
	action.last_settled_at = elapsed_s + seconds


## 按配表阶段执行真实效果；未知效果从不被忽略为成功。
func _apply_phase(index: int, action_id: String, phase: String, natural_entry: bool) -> Error:
	var context: Dictionary = course_context()
	for effect in config.phase_effects(action_id, phase):
		if not _condition_matches(effect.condition, natural_entry, context):
			continue
		match effect.type:
			"resource":
				_change_resource(index, effect.resource, _resource_effect_value(index, effect), phase != "instant" and not students[index].current_action.is_empty())
			"apply_buff":
				_apply_buff(index, effect.buff_id)
			"start_action":
				var next_id: String = context.default_action_id if effect.next_action_id == "current_course" else effect.next_action_id
				var result: Error = start_action(index, next_id, effect.event == "natural_entry")
				if result != OK:
					return result
			_:
				return _fail("当前执行器不支持效果：%s" % effect.id)
	return OK


## 完成和打断共用结束入口，只有正常完成执行complete阶段。
func _end_action(index: int, completed: bool, reason: String) -> Error:
	var instance: Dictionary = students[index].current_action
	if completed:
		var result: Error = _apply_phase(index, instance.action_id, "complete", instance.natural_entry)
		if result != OK:
			return result
	_log(index, "complete" if completed else "interrupt", "%s：%s" % [reason, config.actions[instance.action_id].name], {
		"action_id": instance.action_id, "executed_s": elapsed_s - instance.started_at,
		"resource_changes": instance.resource_changes.duplicate(true), "knowledge_gain": instance.knowledge_gain,
	})
	students[index].current_action = {}
	var remaining_buffs: Array = []
	for buff in students[index].buffs:
		if buff.action_instance_id != instance.instance_id:
			remaining_buffs.append(buff)
	students[index].buffs = remaining_buffs
	_clamp_resources_after_max_change(index)
	return OK


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
func _apply_buff(index: int, buff_id: String) -> void:
	var definition: Dictionary = config.buffs[buff_id]
	if definition.stacking in ["refresh", "replace"]:
		var retained: Array = []
		for buff in students[index].buffs:
			if config.buffs[buff.buff_id].stack_group != definition.stack_group:
				retained.append(buff)
		students[index].buffs = retained
	var expiration: Variant = elapsed_s + definition.duration_s if definition.lifecycle == "timed" else null
	var action_id: Variant = students[index].current_action.instance_id if definition.lifecycle == "action" else null
	students[index].buffs.append({"buff_id": buff_id, "expires_at": expiration, "action_instance_id": action_id})
	_clamp_resources_after_max_change(index)
	_log(index, "buff", "获得状态：%s" % definition.name, {"buff_id": buff_id})


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
