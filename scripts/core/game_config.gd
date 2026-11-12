class_name GameConfig
extends RefCounted
## 从Excel导出的JSON建立只读配置索引，入口发现配置错误即明确失败。

# 配置内容摘要同时记录进存档，防止不同数值版本的动作被混合结算。
var fingerprint: String = ""
var version: String = ""
var error_message: String = ""
var tables: Dictionary = {}
var indexes: Dictionary = {}
var actions: Dictionary = {}
var effects_by_action: Dictionary = {}
var effects_by_option: Dictionary = {}
var events_by_trigger: Dictionary = {}
var subjects: Dictionary = {}
var periods: Array = []
var globals: Dictionary = {}
var buffs: Dictionary = {}
var items: Dictionary = {}
# 阶段范围由模拟器入口读取，行为树使用同一份显式内容范围。
var phase_scope: Dictionary = {}

const ENUMS: Dictionary = {
	"actions": {
		"kind": ["instant", "duration"], "source": ["player", "auto", "both"],
		"target": ["self", "pair", "group"], "scene": ["any", "classroom", "playground", "canteen", "dorm", "course"],
		"violation": ["none", "distraction"], "completion_route": ["schedule", "study", "previous"],
		"knowledge_source": ["school", "dorm", "none"], "knowledge_mode": ["course", "selected_subject", "fixed_subject", "none"],
		"eligible_period": ["any", "dorm_free", "break"],
	},
	"effects": {
		"phase": ["start", "tick", "complete", "instant"], "recipient": ["self", "target", "both", "ally", "winner", "loser"],
		"type": ["resource", "apply_buff", "consume_item", "start_action", "event"], "resource": ["focus", "stamina"],
		"mode": ["flat", "max_ratio"], "max_basis": ["current"],
		"condition": ["always", "natural_entry", "selected_variant", "course_active", "winner", "loser", "tie"],
		"event": ["forced_entry", "natural_entry", "close_violation", "deliver_note", "resolve_answer_challenge", "resolve_arm_wrestle", "interrupt_reading"],
	},
	"buffs": {"lifecycle": ["action", "timed"], "stacking": ["refresh", "replace", "independent"], "knowledge_redirect": ["none", "selected_subject"]},
	"events": {"trigger_point": ["morning", "lesson_start", "break_start", "lunch", "after_school"]},
	"event_effects": {
		"recipient": ["self", "target", "both"], "type": ["resource", "apply_buff", "attribute_point", "give_item", "force_action"],
		"resource": ["focus", "stamina", "knowledge"],
	},
	"globals": {"type": ["string", "number", "boolean"]},
	"subjects": {"kind": ["knowledge", "recovery", "exam"]},
	"periods": {"kind": ["lesson", "break", "exercise", "eye_exercise", "lunch", "rest"]},
	"auto_pool": {"eligible_period": ["knowledge_course", "dorm_free"]},
	"interrupt_policies": {"remaining_participants_route": ["schedule"]},
}
const REFERENCES: Dictionary = {
	"action_id": "actions", "default_action_id": "actions", "interrupt_policy_id": "interrupt_policies",
	"buff_id": "buffs", "item_id": "items", "subject_id": "subjects", "knowledge_subject_id": "subjects", "period_id": "periods",
	"event_id": "events", "option_id": "event_options",
}
# 核心和行为树直接读取的全局参数，必须在加载入口保证存在且为数字。
const REQUIRED_NUMBER_GLOBALS: Array[String] = [
	"initial_focus", "initial_stamina", "focus_base", "focus_per_discipline",
	"stamina_base", "stamina_per_health", "initial_attribute_points",
	"learning_focus_coefficient", "distraction_focus_threshold",
	"sleep_stamina_threshold", "tired_knowledge_multiplier",
	"exam_intelligence_coefficient", "score_decimal_places",
	"session_days",
	# AI升级：属性驱动行为加权与竞争自主社交所需的数值系数。
	"personality_ref_attr", "dorm_weight_floor", "social_auto_base",
	"g_study", "g_game", "g_workout", "g_playful", "g_weak", "g_lead",
	"k_threshold",
	# 抢答自主检查点：课内按独立随机流尝试发起。
	"answer_challenge_check_seconds", "answer_challenge_auto_chance",
	# 课间磨蹭：课间开始按专注阈值与概率触发，四地点抽一。
	"linger_break_focus_threshold", "linger_break_chance",
]
# 成绩以整数刻度相加；这里只校验实际表示范围，不设置人为分数或小数位上限。
const MAX_SCORE_INTEGER: int = 9223372036854775807


## 读取并校验完整配置；不使用默认配置或旧缓存覆盖读取失败。
func load_file(path: String = "res://config/game_config.json", schema_path: String = "res://config/config_schema.json") -> Error:
	error_message = ""
	var source_file := FileAccess.open(path, FileAccess.READ)
	if source_file == null:
		return _fail("无法读取配置：%s（错误码%s）" % [path, FileAccess.get_open_error()])
	var source: String = source_file.get_as_text()
	var parser := JSON.new()
	var result: Error = parser.parse(source)
	if result != OK:
		return _fail("配置JSON第%s行：%s" % [parser.get_error_line(), parser.get_error_message()])
	if not parser.data is Dictionary or not parser.data.has_all(["version", "schema_version", "tables"]):
		return _fail("配置根对象必须包含version、schema_version和tables")
	if parser.data.schema_version != 1:
		return _fail("当前执行器不支持配置schema_version=%s" % parser.data.schema_version)
	if not parser.data.tables is Dictionary:
		return _fail("配置tables必须为对象")
	var schema_file := FileAccess.open(schema_path, FileAccess.READ)
	if schema_file == null:
		return _fail("无法读取字段契约：%s" % schema_path)
	var schema_parser := JSON.new()
	if schema_parser.parse(schema_file.get_as_text()) != OK:
		return _fail("字段契约JSON格式错误：%s" % schema_parser.get_error_message())
	if not schema_parser.data is Dictionary or not schema_parser.data.get("tables") is Array:
		return _fail("字段契约缺少tables数组")
	tables = parser.data.tables
	indexes.clear()
	for definition in schema_parser.data.tables:
		result = _validate_table(definition)
		if result != OK:
			return result
	result = _validate_relations()
	if result != OK:
		return result
	version = str(parser.data.version)
	fingerprint = source.sha256_text()
	actions = indexes.actions
	subjects = indexes.subjects
	buffs = indexes.buffs
	items = indexes.items
	periods = tables.periods.duplicate(true)
	periods.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.start_time < b.start_time)
	globals.clear()
	for row in tables.globals:
		globals[row.key] = row.value
	effects_by_action.clear()
	for action_id in actions:
		effects_by_action[action_id] = []
	for row in tables.effects:
		effects_by_action[row.action_id].append(row)
	for action_id in effects_by_action:
		effects_by_action[action_id].sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.sequence < b.sequence)
	effects_by_option.clear()
	for option_id in indexes.event_options:
		effects_by_option[option_id] = []
	for row in tables.event_effects:
		effects_by_option[row.option_id].append(row)
	for option_id in effects_by_option:
		effects_by_option[option_id].sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.sequence < b.sequence)
	events_by_trigger.clear()
	for trigger_point in ["morning", "lesson_start", "break_start", "lunch", "after_school"]:
		events_by_trigger[trigger_point] = []
	for row in tables.events:
		if row.enabled:
			events_by_trigger[row.trigger_point].append(row)
	var event_result: Error = _validate_events()
	if event_result != OK:
		return event_result
	return OK


## 事件表专项校验：每个启用事件至少一个选项，效果类型与字段匹配。
func _validate_events() -> Error:
	for row in tables.event_options:
		if not indexes.events.has(row.event_id):
			return _fail("事件选项%s引用了不存在的事件：%s" % [row.id, row.event_id])
		if row.sequence != int(row.sequence):
			return _fail("事件选项%s的sequence必须为整数" % row.id)
	for event_id in indexes.events:
		var option_count: int = 0
		for row in tables.event_options:
			if row.event_id == event_id:
				option_count += 1
		if indexes.events[event_id].enabled and option_count < 2:
			return _fail("启用事件%s必须至少提供两个选项" % event_id)
	for row in tables.event_effects:
		if not indexes.event_options.has(row.option_id) or String(indexes.event_options[row.option_id].event_id) != String(row.event_id):
			return _fail("事件效果%s的选项归属不一致：%s" % [row.id, row.option_id])
		if row.sequence != int(row.sequence):
			return _fail("事件效果%s的sequence必须为整数" % row.id)
		match String(row.type):
			"resource":
				if row.resource == null or row.value == null:
					return _fail("事件资源效果%s缺少资源或数值" % row.id)
			"apply_buff":
				if row.buff_id == null:
					return _fail("事件状态效果%s缺少状态引用" % row.id)
			"attribute_point", "give_item":
				if row.value == null:
					return _fail("事件效果%s缺少数量" % row.id)
			"force_action":
				if row.action_id == null:
					return _fail("事件强制动作效果%s缺少后续动作" % row.id)
	return OK


## 取出已经在入口校验过的全局参数，不产生另一份默认数值。
func global_value(key: String) -> Variant:
	assert(globals.has(key), "缺少全局参数：%s" % key)
	return globals[key]


## 返回指定动作阶段的效果，执行顺序直接沿用配表sequence。
func phase_effects(action_id: String, phase: String) -> Array:
	var result: Array = []
	for effect in effects_by_action[action_id]:
		if effect.phase == phase:
			result.append(effect)
	return result


## 按字段契约校验每张表，并在这里统一保证主键、枚举及基本类型。
func _validate_table(definition: Dictionary) -> Error:
	var key: String = definition.key
	if not tables.has(key) or not tables[key] is Array:
		return _fail("配置表%s缺失或不是数组" % key)
	var table_index: Dictionary = {}
	for row_index in tables[key].size():
		var row: Variant = tables[key][row_index]
		if not row is Dictionary:
			return _fail("%s第%s条必须为对象" % [key, row_index + 1])
		for column in definition.columns:
			var field: String = column.key
			if not row.has(field):
				return _fail("%s第%s条缺少字段%s" % [key, row_index + 1, field])
			if row[field] == null:
				if not column.nullable:
					return _fail("%s第%s条的%s不可为空" % [key, row_index + 1, field])
				continue
			if not _matches_type(row[field], column.type):
				return _fail("%s第%s条的%s类型错误，应为%s" % [key, row_index + 1, field, column.type])
			if ENUMS.has(key) and ENUMS[key].has(field) and row[field] not in ENUMS[key][field]:
				return _fail("%s第%s条的%s为未知枚举：%s" % [key, row_index + 1, field, row[field]])
		var identity_key: String = "key" if key == "globals" else "id"
		var identity: String = row[identity_key]
		if identity.is_empty() or identity != identity.strip_edges() or table_index.has(identity):
			return _fail("%s包含空白或重复主键：%s" % [key, identity])
		table_index[identity] = row
	indexes[key] = table_index
	return OK


## 校验表间引用与执行时序，防止不完整配置进入核心结算过程。
func _validate_relations() -> Error:
	var effect_sequences: Dictionary = {}
	for table_key in tables:
		for row in tables[table_key]:
			for field in REFERENCES:
				if row.has(field) and row[field] != null:
					if field == "default_action_id" and row[field] == "current_course":
						continue
					if not indexes[REFERENCES[field]].has(row[field]):
						return _fail("%s.%s引用了不存在的%s：%s" % [table_key, field, REFERENCES[field], row[field]])
			if row.has("next_action_id") and row.next_action_id != null and row.next_action_id != "current_course" and not indexes.actions.has(row.next_action_id):
				return _fail("效果引用了不存在的后续动作：%s" % row.next_action_id)
	for row in tables.actions:
		if row.kind == "instant":
			if row.duration_min_s != null or row.duration_max_s != null:
				return _fail("瞬时动作%s的持续时长必须留空" % row.id)
		elif not _positive_number(row.duration_min_s) or not _positive_number(row.duration_max_s) or row.duration_min_s > row.duration_max_s:
			return _fail("持续动作%s的时长范围无效" % row.id)
		if row.knowledge_multiplier < 0.0 or (row.knowledge_source == "none") != (row.knowledge_mode == "none") or (row.knowledge_mode == "none") != (row.knowledge_multiplier == 0.0):
			return _fail("动作%s的知识来源、方式与倍率不一致" % row.id)
		if row.knowledge_mode == "fixed_subject":
			if row.knowledge_subject_id == null or indexes.subjects[row.knowledge_subject_id].kind != "knowledge":
				return _fail("动作%s的固定知识归属必须引用知识科目" % row.id)
		elif row.knowledge_subject_id != null:
			return _fail("动作%s不使用固定知识科目，knowledge_subject_id必须留空" % row.id)
		if row.knowledge_source == "school" and row.knowledge_mode != "course":
			return _fail("动作%s的在校知识必须来自当前知识课程" % row.id)
		if row.knowledge_source == "dorm" and (row.knowledge_mode not in ["selected_subject", "fixed_subject"] or row.eligible_period != "dorm_free"):
			return _fail("动作%s的宿舍知识必须明确科目来源并限定宿舍自由时段" % row.id)
		# 结伴自习/室友开黑是宿舍pair动作：需要同场景同学，其余仍要求可支付。
		if row.eligible_period == "dorm_free" and (row.scene != "dorm" or row.target not in ["self", "pair"] or row.kind != "duration"):
			return _fail("动作%s的宿舍自由活动必须是宿舍内个人或双人持续动作" % row.id)
	for row in tables.effects:
		var identity: String = "%s/%s/%s" % [row.action_id, row.phase, row.sequence]
		if effect_sequences.has(identity):
			return _fail("效果执行顺序重复：%s" % identity)
		effect_sequences[identity] = true
		if row.sequence != int(row.sequence):
			return _fail("效果%s的sequence必须为整数" % row.id)
		if (indexes.actions[row.action_id].kind == "instant") != (row.phase == "instant"):
			return _fail("效果%s的阶段与动作类型不匹配" % row.id)
		if row.phase == "tick" and not _positive_number(row.period_s):
			return _fail("持续效果%s的计量周期必须大于0" % row.id)
		if row.phase != "tick" and row.period_s != null:
			return _fail("非持续效果%s不能填写计量周期" % row.id)
		if row.type == "resource":
			if row.resource == null or row.mode == null or not _matches_type(row.value, "number"):
				return _fail("资源效果%s缺少资源、模式或数值" % row.id)
			if row.mode == "max_ratio" and row.max_basis != "current":
				return _fail("比例效果%s必须以current当前上限结算" % row.id)
		if row.type == "start_action" and (row.next_action_id == null or row.event not in ["natural_entry", "forced_entry"]):
			return _fail("效果%s缺少后续动作或入段方式" % row.id)
		if row.type == "apply_buff" and row.buff_id == null:
			return _fail("效果%s缺少状态引用" % row.id)
	for row in tables.globals:
		if not _matches_type(row.value, row.type):
			return _fail("全局参数%s的值与声明类型不符" % row.key)
	for key in REQUIRED_NUMBER_GLOBALS:
		if not indexes.globals.has(key) or indexes.globals[key].type != "number":
			return _fail("核心所需全局参数%s缺失或未声明为数字" % key)
	var ai_result: Error = _validate_ai_parameters()
	if ai_result != OK:
		return ai_result
	for row in tables.periods:
		if row.start_time < 0.0 or row.end_time > 1.0 or row.start_time >= row.end_time:
			return _fail("时段%s的起止时间无效" % row.id)
	for row in tables.buffs:
		if row.lifecycle == "timed" and not _positive_number(row.duration_s):
			return _fail("状态%s的持续时间必须大于0" % row.id)
	for pool_key in ["auto_pool", "drop_pool"]:
		for row in tables[pool_key]:
			if row.weight < 0.0:
				return _fail("%s的权重不能为负：%s" % [pool_key, row.id])
	var scoring_result: Error = _validate_exam_scoring()
	if scoring_result != OK:
		return scoring_result
	var round_result: Error = _validate_round_schedule()
	if round_result != OK:
		return round_result
	var dorm_result: Error = _validate_dorm_pool()
	if dorm_result != OK:
		return dorm_result
	var builds_result: Error = _validate_npc_builds()
	if builds_result != OK:
		return builds_result
	return _validate_daily_rewards()


## 初始占位加点只读权威Excel导出的表，读档和每日成长不重新套用预设。
func _validate_npc_builds() -> Error:
	if tables.npc_attributes.size() != 3:
		return _fail("占位加点表必须完整包含三名本地同学")
	var initial_points: float = indexes.globals.initial_attribute_points.value
	for identity: String in ["student_1", "student_2", "student_3"]:
		if not indexes.npc_attributes.has(identity):
			return _fail("占位加点表缺少角色：%s" % identity)
		var total: float = 0.0
		for attribute: String in ["attention", "discipline", "health", "intelligence"]:
			var value: float = indexes.npc_attributes[identity][attribute]
			if value < 0.0 or value != int(value):
				return _fail("占位属性%s/%s必须为非负整数" % [identity, attribute])
			total += value
		if total != initial_points:
			return _fail("占位角色%s必须恰好消耗初始属性点" % identity)
	return OK


## AI概率与属性加权在配置入口统一校验，运行中不截断非法概率或回退默认系数。
func _validate_ai_parameters() -> Error:
	if indexes.globals.personality_ref_attr.value <= 0.0:
		return _fail("AI参数personality_ref_attr必须为正有限数")
	var floor_probability: float = indexes.globals.dorm_weight_floor.value
	if floor_probability < 0.0 or floor_probability > 1.0 / 6.0:
		return _fail("AI参数dorm_weight_floor必须在0至1/6之间，才能为六项活动同时保底")
	for key: String in ["g_study", "g_game", "g_workout", "g_playful", "g_weak", "g_lead"]:
		if indexes.globals[key].value < 0.0:
			return _fail("AI增益参数%s必须为非负有限数" % key)
	var threshold_factor: float = indexes.globals.k_threshold.value
	if threshold_factor < 0.0 or threshold_factor > 1.0:
		return _fail("AI参数k_threshold必须在0至1之间")
	var social_base: float = indexes.globals.social_auto_base.value
	var social_probability: float = social_base * (1.0 + indexes.globals.g_game.value)
	if social_base < 0.0 or not is_finite(social_probability) or social_probability > 1.0:
		return _fail("AI参数social_auto_base必须非负，且与g_game组合后的发起概率不得超过1")
	# 提前验证加权与求和的实际表示范围，不以运行时静默丢弃候选掩盖溢出。
	var totals: Dictionary = {"dorm_free": 0.0, "knowledge_course": 0.0}
	var gains: Dictionary = {
		"dorm_study": "g_study", "dorm_practice": "g_study",
		"dorm_game": "g_game", "dorm_workout": "g_workout",
		"playground_play": "g_workout", "daydream": "g_playful", "read_comic": "g_playful",
	}
	for row: Dictionary in tables.auto_pool:
		if not row.enabled:
			continue
		var gain: float = indexes.globals[gains[row.action_id]].value if gains.has(row.action_id) else 0.0
		var maximum_weight: float = row.weight * (1.0 + gain)
		totals[row.eligible_period] += maximum_weight
		if not is_finite(maximum_weight) or not is_finite(totals[row.eligible_period]):
			return _fail("AI候选%s的属性加权或权重合计超出有限数字范围" % row.id)
	if not is_finite(3.0 * (1.0 + indexes.globals.g_weak.value)) or not is_finite(18.0 * (1.0 + indexes.globals.g_lead.value)):
		return _fail("AI参数g_weak或g_lead导致选科或竞争目标权重合计超出有限数字范围")
	return OK


## 宿舍候选必须与课堂池隔离，八项活动使用相同基础权重，再由AI按属性加权。
func _validate_dorm_pool() -> Error:
	# 结伴自习与室友开黑需要同场景同学，其余为个人活动。
	var expected: Array[String] = ["dorm_study", "dorm_practice", "dorm_game", "dorm_workout", "dorm_wash", "dorm_rest", "study_together", "roommate_game"]
	var candidates: Dictionary = {}
	var weight: float = -1.0
	for row: Dictionary in tables.auto_pool:
		if row.eligible_period != "dorm_free":
			continue
		var action: Dictionary = indexes.actions[row.action_id]
		if action.eligible_period != "dorm_free" or not action.enabled or not row.enabled or not row.requires_affordable_start:
			return _fail("宿舍候选%s必须启用且可支付" % row.id)
		# 双人结伴候选必须声明同场景同伴要求；个人候选必须无需同伴，防止单人入口误开。
		if action.target == "pair" and not row.requires_same_scene_target:
			return _fail("宿舍双人候选%s必须要求同场景同伴" % row.id)
		if action.target != "pair" and row.requires_same_scene_target:
			return _fail("宿舍个人候选%s不能要求同场景同伴" % row.id)
		if row.action_id not in expected or candidates.has(row.action_id):
			return _fail("宿舍候选%s不是八项活动之一或存在重复" % row.id)
		if row.weight <= 0.0 or (weight > 0.0 and row.weight != weight):
			return _fail("宿舍候选%s必须使用相等的正权重" % row.id)
		weight = row.weight
		candidates[row.action_id] = true
	if candidates.size() != expected.size():
		return _fail("宿舍自主候选必须完整包含八项活动")
	return OK


## 计分输入必须在配置入口完整校验，不能以默认满分、曲线或科目替代缺失字段。
func _validate_exam_scoring() -> Error:
	if indexes.globals.exam_intelligence_coefficient.value < 0.0:
		return _fail("考试参数exam_intelligence_coefficient必须为非负数")
	var decimal_places: Variant = indexes.globals.score_decimal_places.value
	if decimal_places < 0.0 or decimal_places != int(decimal_places):
		return _fail("考试参数score_decimal_places必须为非负整数")
	var score_factor: float = pow(10.0, float(decimal_places))
	if not is_finite(score_factor):
		return _fail("考试参数score_decimal_places导致计分刻度超出浮点表示范围")
	var total_max_units: int = 0
	for subject in tables.subjects:
		if subject.kind == "knowledge":
			if not _positive_number(subject.max_score) or not _positive_number(subject.score_scale):
				return _fail("知识科目%s的max_score与score_scale必须为正有限数" % subject.id)
			var rounded_units: float = roundf(float(subject.max_score) * score_factor)
			# 浮点数不能精确表示int64最大值，使用严格小于2^63避免转换时绕回负数。
			if not is_finite(rounded_units) or rounded_units >= 9223372036854775808.0:
				return _fail("知识科目%s的满分刻度超出整数表示范围" % subject.id)
			var max_units: int = int(rounded_units)
			if max_units > MAX_SCORE_INTEGER - total_max_units:
				return _fail("各科舍入满分相加超出总分整数表示范围")
			total_max_units += max_units
		elif subject.kind == "exam":
			if subject.knowledge_subject_id == null or indexes.subjects[subject.knowledge_subject_id].kind != "knowledge":
				return _fail("考试科目%s的knowledge_subject_id必须引用知识科目" % subject.id)
	return OK


## 七天事件依赖唯一完整课表，歧义与缺课在入口拒绝，核心不猜测出榜或考试时刻。
func _validate_round_schedule() -> Error:
	var session_days: Variant = indexes.globals.session_days.value
	if not _positive_integer(session_days):
		return _fail("session_days必须为正整数")
	if not indexes.subjects.has("physical") or indexes.subjects.physical.kind != "knowledge":
		return _fail("七天结算必须有physical体育知识科目")
	var ordered_periods: Array = tables.periods.duplicate(true)
	ordered_periods.sort_custom(func(left: Dictionary, right: Dictionary) -> bool: return left.start_time < right.start_time)
	var previous_end: float = 0.0
	var lessons: Array[String] = []
	for period: Dictionary in ordered_periods:
		var start: float = roundf(period.start_time * 86400.0)
		var finish: float = roundf(period.end_time * 86400.0)
		if start < previous_end or finish <= start:
			return _fail("课表时段重叠或秒级边界无效：%s" % period.id)
		previous_end = finish
		if period.kind == "lesson":
			lessons.append(period.id)
	if lessons.is_empty():
		return _fail("七天结算课表不能没有课程")
	var scheduled: Dictionary = {}
	var slots: Dictionary = {}
	var examined: Dictionary = {}
	for row: Dictionary in tables.schedule:
		if not _positive_integer(row.day) or row.day > session_days or not _positive_integer(row.slot):
			return _fail("课程行%s的局内日或课时序号无效" % row.id)
		if row.period_id not in lessons:
			return _fail("课程行%s必须引用上课时段" % row.id)
		var identity: String = "%s/%s" % [int(row.day), row.period_id]
		var slot_identity: String = "%s/%s" % [int(row.day), int(row.slot)]
		if scheduled.has(identity) or slots.has(slot_identity):
			return _fail("课程表同日时段或课时序号重复：%s" % row.id)
		scheduled[identity] = true
		slots[slot_identity] = true
		var subject: Dictionary = indexes.subjects[row.subject_id]
		if subject.kind == "exam":
			if row.day != session_days or examined.has(subject.knowledge_subject_id) or subject.knowledge_subject_id == "physical":
				return _fail("考试课程必须在最后一天且各科仅一次：%s" % row.id)
			examined[subject.knowledge_subject_id] = true
	for round_day: int in range(1, int(session_days) + 1):
		for period_id: String in lessons:
			if not scheduled.has("%s/%s" % [round_day, period_id]):
				return _fail("课程表缺少第%s天的%s" % [round_day, period_id])
	for subject: Dictionary in tables.subjects:
		if subject.kind == "knowledge" and subject.id != "physical" and not examined.has(subject.id):
			return _fail("知识科目%s缺少最后一天的考试课程" % subject.id)
	return OK


## 每日奖励只接受完整且可执行的配表，零权重和停用行不参与抽取。
func _validate_daily_rewards() -> Error:
	if not indexes.globals.has("daily_item_draw_count") or indexes.globals.daily_item_draw_count.type != "number":
		return _fail("每日奖励全局参数daily_item_draw_count缺失或未声明为数字")
	var draw_count: Variant = indexes.globals.daily_item_draw_count.value
	if not _positive_integer(draw_count):
		return _fail("每日奖励daily_item_draw_count必须为正整数")
	if not indexes.globals.has("daily_item_with_replacement") or indexes.globals.daily_item_with_replacement.type != "boolean":
		return _fail("每日奖励全局参数daily_item_with_replacement缺失或未声明为boolean")
	# 逐行数字类型已由字段契约验证；仍需阻止数量小数和总权重累加溢出。
	var total_weight: float = 0.0
	var enabled_row_count: int = 0
	for row in tables.drop_pool:
		if not _positive_integer(row.quantity):
			return _fail("每日物品奖池%s的quantity必须为正整数" % row.id)
		if row.enabled and row.weight > 0.0:
			total_weight += row.weight
			enabled_row_count += 1
	if not is_finite(total_weight) or total_weight <= 0.0:
		return _fail("每日物品奖池启用且正权重项的权重总和必须为正有限数")
	if not indexes.globals.daily_item_with_replacement.value and enabled_row_count < draw_count:
		return _fail("每日物品奖池无放回抽取需要%s条启用且正权重项，当前仅%s条" % [draw_count, enabled_row_count])
	return OK


## 字段类型只接受契约中的显式类型，不将数字字符串或布尔值自动转换。
func _matches_type(value: Variant, expected: String) -> bool:
	match expected:
		"string": return value is String
		"boolean": return value is bool
		"number": return (value is int or value is float) and is_finite(float(value))
		"any": return value != null
	return false


## 业务持续时间与周期必须是正的有限数字。
func _positive_number(value: Variant) -> bool:
	return _matches_type(value, "number") and float(value) > 0.0


## 数量必须可原样表示为正整数，不截断小数或把布尔值转换成数量。
func _positive_integer(value: Variant) -> bool:
	return _positive_number(value) and value == int(value)


## 将入口失败保存在可展示字段中，调用方必须中止本次加载。
func _fail(message: String) -> Error:
	error_message = message
	return ERR_INVALID_DATA
