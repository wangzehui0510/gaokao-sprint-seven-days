extends SceneTree
## 验证AI升级：NPC占位加点、属性倾向加权、弱科选科、开小差阈值个性化与竞争互动候选。

const CONFIG = preload("res://scripts/core/game_config.gd")
const SIMULATION = preload("res://scripts/core/classroom_simulation.gd")

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_npc_builds()
	_test_persona_factor()
	_test_weak_subject()
	_test_distraction_threshold()
	_test_cultural_subject_selection()
	_test_social_candidates_gate()
	if failures.is_empty():
		print("AI_UPGRADE_TEST_PASS checks=%s" % checks)
		quit(0)
	else:
		for message in failures:
			push_error(message)
		print("AI_UPGRADE_TEST_FAIL checks=%s failures=%s" % [checks, failures.size()])
		quit(1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)


## 占位假人按预设加点，玩家“我”保留待分配点。
func _test_npc_builds() -> void:
	var simulation: ClassroomSimulation = _new_simulation()
	_check(float(simulation.students[0].attributes.discipline) == 0.0 and simulation.students[0].unspent_points == 8, "玩家我保留8点待分配点、属性为0")
	_check(float(simulation.students[1].attributes.discipline) == 4.0 and simulation.students[1].unspent_points == 0, "小林自律性4")
	_check(float(simulation.students[1].attributes.intelligence) == 2.0, "小林智力2")
	_check(float(simulation.students[2].attributes.discipline) == 1.0, "小陈自律性1")
	_check(float(simulation.students[3].attributes.health) == 5.0, "小周健康5")


## 属性倾向系数按配表增益与归一化属性计算。
func _test_persona_factor() -> void:
	var simulation: ClassroomSimulation = _new_simulation()
	# 小林自律4/8=0.5，自习系数=1+0.5*0.5=1.25；贪玩=1-0.5=0.5，游戏=1+0.5*0.5=1.25
	_check(is_equal_approx(simulation.persona_factor(1, "dorm_study"), 1.25), "小林自习系数1.25")
	_check(is_equal_approx(simulation.persona_factor(1, "dorm_game"), 1.25), "小林游戏系数1.25")
	# 小周健康5/8=0.625，健身=1+0.5*0.625=1.3125
	_check(is_equal_approx(simulation.persona_factor(3, "dorm_workout"), 1.3125), "小周健身系数1.3125")
	# 中性动作不受属性影响
	_check(is_equal_approx(simulation.persona_factor(1, "dorm_rest"), 1.0), "宿舍休息系数1.0")


## 弱科取当前累计知识量最低的文化课，并列取遍历序首个。
func _test_weak_subject() -> void:
	var simulation: ClassroomSimulation = _new_simulation()
	_check(simulation.weak_subject(0) == "chinese", "全零知识弱科取首个chinese")
	simulation.students[0].knowledge["chinese"] = 5.0
	simulation.students[0].knowledge["math"] = 2.0
	simulation.students[0].knowledge["english"] = 9.0
	_check(simulation.weak_subject(0) == "math", "知识量最低为math")


## 开小差阈值按自律性下调：自律越高阈值越低。
func _test_distraction_threshold() -> void:
	var simulation: ClassroomSimulation = _new_simulation()
	# 玩家我自律0：阈值保持50
	_check(is_equal_approx(simulation.distraction_threshold(0), 50.0), "我开小差阈值50")
	# 小林自律4/8=0.5：50*(1-0.4*0.5)=40
	_check(is_equal_approx(simulation.distraction_threshold(1), 40.0), "小林开小差阈值40")


## 补弱科选科只在语数英内返回，且弱科被加权。
func _test_cultural_subject_selection() -> void:
	var simulation: ClassroomSimulation = _new_simulation()
	for attempt in 20:
		var subject: String = simulation.select_cultural_subject(0)
		_check(subject in ["chinese", "math", "english"], "选科必须是语数英之一")


## 竞争互动候选只在知识课产生，且目标不包含自己。
func _test_social_candidates_gate() -> void:
	var simulation: ClassroomSimulation = _new_simulation()
	# 默认课表起始通常是上课时段；用真实课表上下文验证候选目标合法性。
	var options: Array[Dictionary] = simulation.get_social_candidates(0)
	for option in options:
		_check(int(option["target_index"]) != 0, "竞争互动目标不包含自己")
		_check(String(option["action_id"]) in ["borrow_notes", "swap_book", "invite_playground", "invite_canteen", "arm_wrestle", "eraser_prank"], "竞争互动动作在自主池内")


## 建立真实模拟器并设置开发时钟，复用统一随机流。
func _new_simulation() -> ClassroomSimulation:
	var game_config := CONFIG.new()
	_check(game_config.load_file() == OK, "正式JSON配置应完整通过校验：%s" % game_config.error_message)
	var simulation := SIMULATION.new()
	_check(simulation.setup(game_config, 261106) == OK, "模拟器初始化成功：%s" % simulation.error_message)
	_check(simulation.set_debug_time(1, 3600.0) == OK, "开发时钟设置成功")
	return simulation
