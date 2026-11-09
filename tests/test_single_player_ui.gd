extends SceneTree
## 单机界面验收仅使用真实配表、行为树、课程奖励与生产控件，不预填库存或业务结果。

const APPLICATION_PREFIX: String = "ClassroomSinglePlayerUiTest_"
const ATTRIBUTE_IDS: Array[String] = ["attention", "discipline", "health", "intelligence"]
const SCENE_IDS: Array[String] = ["auto", "classroom", "playground", "canteen", "dorm"]
const ITEM_ACTIONS: Dictionary = {"snack": "snack_self", "comic": "read_comic_item", "candy": "eat_candy_item"}

# 测试应用独占用户目录，所有断言与失败原因均由真实执行结果产生。
var checks: int = 0
var failures: Array[String] = []


## 等待场景树建立后，再复制生产工程并验证用户目录隔离。
func _initialize() -> void:
	call_deferred("_run")


## 子进程必须同时持有显式标记与专用用户目录，避免正式存档参与测试。
func _run() -> void:
	if "--isolated-single-player-ui" not in OS.get_cmdline_user_args():
		_launch_isolated_project()
		return
	var marker: String = str(ProjectSettings.get_setting("application/config/name"))
	if not marker.begins_with(APPLICATION_PREFIX) or marker not in OS.get_user_data_dir():
		push_error("单机界面测试用户目录未隔离，拒绝运行。")
		quit(1)
		return
	create_timer(150.0).timeout.connect(func():
		_check(false, "单机界面验收超时，可能存在未处理脚本错误")
		_finish()
	)
	await _test_interface()
	_finish()


## 复制完整业务源码，导入与存档只写本次独占工程和用户目录。
func _launch_isolated_project() -> void:
	var marker: String = APPLICATION_PREFIX + "%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var isolated_root: String = OS.get_cache_dir().path_join(marker)
	for folder: String in ["scripts", "config", "assets", "addons", "scenes", "tests"]:
		var result: Error = _copy_directory(ProjectSettings.globalize_path("res://" + folder), isolated_root.path_join(folder))
		if result != OK:
			push_error("复制单机界面隔离工程失败：%s，错误码%s。" % [folder, result])
			quit(1)
			return
	if not _disable_isolated_social(isolated_root):
		quit(1)
		return
	var project := ConfigFile.new()
	if project.load("res://project.godot") != OK:
		push_error("无法读取单机界面测试所需真实工程设置。")
		quit(1)
		return
	project.set_value("application", "config/name", marker)
	project.set_value("application", "config/use_custom_user_dir", true)
	project.set_value("application", "config/custom_user_dir_name", marker)
	if project.save(isolated_root.path_join("project.godot")) != OK:
		push_error("无法保存单机界面隔离工程设置。")
		quit(1)
		return
	var output: Array = []
	var exit_code: int = OS.execute(OS.get_executable_path(), ["--headless", "--path", isolated_root, "--editor", "--import"], output, true)
	if exit_code != 0:
		for line: String in output:
			print(line)
		quit(exit_code)
		return
	output.clear()
	exit_code = OS.execute(OS.get_executable_path(), ["--headless", "--path", isolated_root, "--script", get_script().resource_path, "--", "--isolated-single-player-ui"], output, true)
	for line: String in output:
		print(line)
	print("SINGLE_PLAYER_UI_TEST_PROJECT=%s" % isolated_root)
	quit(exit_code)


## 仅修改本次隔离工程，避免竞争AI随机打断个人动作或双人扩展的专属界面验收。
func _disable_isolated_social(isolated_root: String) -> bool:
	var path: String = isolated_root.path_join("config/phase_scope.json")
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not data is Dictionary:
		push_error("单机界面隔离副本的阶段配置无效：" + path)
		return false
	data.social_auto_actions = []
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("无法写入单机界面的隔离阶段配置：" + path)
		return false
	file.store_string(JSON.stringify(data, "\t", true, true))
	file.close()
	return true


## 每个文件都检查复制错误，不在缺失源码时继续验收。
func _copy_directory(source: String, destination: String) -> Error:
	var directory := DirAccess.open(source)
	if directory == null:
		return ERR_CANT_OPEN
	var result: Error = DirAccess.make_dir_recursive_absolute(destination)
	if result != OK:
		return result
	for folder: String in directory.get_directories():
		result = _copy_directory(source.path_join(folder), destination.path_join(folder))
		if result != OK:
			return result
	for filename: String in directory.get_files():
		result = DirAccess.copy_absolute(source.path_join(filename), destination.path_join(filename))
		if result != OK:
			return result
	return OK


## 仅省略无头环境的原生托盘初始化，其余界面与业务绑定均复用生产实现。
func _test_interface() -> void:
	var ui := Control.new()
	root.add_child(ui)
	ui.set_script(load("res://scripts/ui/main.gd"))
	ui.set_process(false)
	ui._build_theme()
	ui._build_interface()
	var configuration := GameConfig.new()
	if not _result(configuration.load_file(), "读取正式配置", configuration.error_message):
		ui.free()
		return
	ui.configuration = configuration
	if not _control_contract(ui) or not _reset_session(ui, 1):
		ui.free()
		return
	_check(ui.inspector_tabs.get_tab_count() == 6, "新增玩法不增加或移动原六页")
	for index in 6:
		_check(ui.inspector_tabs.get_tab_title(index) == ["人物", "课表", "记录", "互动", "背包", "榜单"][index], "第%d页保留名称和索引" % index)
	if not await _test_attributes(ui):
		ui.free()
		return
	await _test_scene_controls(ui)
	if not await _test_personal_actions(ui):
		ui.free()
		return
	if not await _test_real_item_use(ui):
		ui.free()
		return
	if not await _test_rejection(ui):
		ui.free()
		return
	if not await _test_save_and_offline(ui):
		ui.free()
		return
	await _test_layout(ui)
	if not await _test_terminal(ui):
		ui.free()
		return
	print("SINGLE_PLAYER_UI_TEST_USER_DIR=%s" % OS.get_user_data_dir())
	ui.free()


## 明确检查新增控件契约，缺少接线时立即失败而非跳过后续场景。
func _control_contract(ui: Control) -> bool:
	var property_names: Array[String] = []
	for property: Dictionary in ui.get_property_list():
		property_names.append(String(property.name))
	for name: String in [
		"scene_picker", "attribute_entry_button", "attribute_dialog", "attribute_buttons",
		"attribute_points_label", "attribute_value_labels", "personal_action_entry_button",
		"personal_action_dialog", "personal_action_picker", "personal_action_button",
		"personal_action_text", "personal_action_reason", "inventory_action_picker", "inventory_use_button",
	]:
		if not _check(name in property_names and ui.get(name) != null, "生产界面提供真实控件：" + name):
			return false
	for attribute_id: String in ATTRIBUTE_IDS:
		if not _check(ui.attribute_buttons.has(attribute_id) and ui.attribute_buttons[attribute_id] is Button, "属性按钮存在：" + attribute_id):
			return false
	return true


## 新局先设置确定时刻再绑定四棵真实树，不依赖宿主日期或遗留库存。
func _reset_session(ui: Control, seed_value: int, at_day: int = 1, seconds: float = 28800.0) -> bool:
	if is_instance_valid(ui.behavior):
		ui.remove_child(ui.behavior)
		ui.behavior.free()
	ui.simulation = ClassroomSimulation.new()
	if not _result(ui.simulation.setup(ui.configuration, seed_value), "建立真实四人局", ui.simulation.error_message):
		return false
	if not _result(ui.simulation.set_debug_time(at_day, seconds), "首次推进前定位真实课表", ui.simulation.error_message):
		return false
	ui._attach_behavior()
	return _check(not ui.fatal_error and ui.simulation != null, "生产界面绑定共享行为树成功")


## 固定种子集合只用于寻找真实缺物前置，不依赖AI升级之前的随机消耗次数或伪造库存。
func _reset_without_items(ui: Control, item_ids: Array) -> bool:
	for seed_value in range(1, 65):
		if not _reset_session(ui, seed_value):
			return false
		var missing: bool = true
		for item_id: String in item_ids:
			if int(ui.simulation.students[0].inventory.get(item_id, 0)) != 0:
				missing = false
				break
		if missing:
			return _check(_events(ui, "daily_items", 0).size() == 1, "缺物前置来自一次真实课程奖励")
	return _check(false, "固定种子集合未得到所需真实缺物前置：" + str(item_ids))


## 真实加点只消费现有初始点，上限增加不能赠资源或改变其他同学。
func _test_attributes(ui: Control) -> bool:
	var initial_points: int = int(ui.configuration.global_value("initial_attribute_points"))
	_check(ui.simulation.students[0].unspent_points == initial_points, "本人点数来自正式配置")
	ui.attribute_entry_button.pressed.emit()
	await process_frame
	_check(ui.attribute_dialog.visible, "人物加点入口打开真实对话框")
	var original_focus: float = ui.simulation.students[0].focus
	var original_stamina: float = ui.simulation.students[0].stamina
	var before: Dictionary = _authority(ui)
	for attribute_id: String in ATTRIBUTE_IDS:
		var old_value: float = ui.simulation.students[0].attributes[attribute_id]
		ui.attribute_buttons[attribute_id].pressed.emit()
		_check(ui.simulation.students[0].attributes[attribute_id] == old_value + 1.0, "真实按钮只增加所选基础属性：" + attribute_id)
		_check(String(ui.attribute_value_labels[attribute_id].text).contains(str(int(old_value + 1.0))), "加点后真实属性文字刷新：" + attribute_id)
	_check(ui.simulation.students[0].unspent_points == initial_points - ATTRIBUTE_IDS.size(), "四次按钮只消费四个实际点数")
	_check(ui.simulation.students.slice(1) == before.students.slice(1), "本人加点不替NPC分配或更改NPC状态")
	_check(ui.simulation.students[0].focus == original_focus and ui.simulation.students[0].stamina == original_stamina, "自律与健康增加上限但不赠送当前资源")
	_check(is_equal_approx(ui.simulation.get_resource_max(0, "focus"), 110.0) and is_equal_approx(ui.simulation.get_resource_max(0, "stamina"), 110.0), "两个资源上限真实采用新基础属性")
	_check(str(ui.simulation.rng.state) == before.rng_state and ui.simulation.round_progression.data == before.round, "加点不消耗随机数或重算账本")
	ui.attribute_dialog.hide()
	ui._select_student(1)
	_check(ui.attribute_entry_button.disabled, "查看同学时初始点分配入口只读")
	var npc_before: Dictionary = _authority(ui)
	ui.attribute_entry_button.pressed.emit()
	if ui.attribute_dialog.visible:
		for attribute_id: String in ATTRIBUTE_IDS:
			_check(ui.attribute_buttons[attribute_id].disabled, "同学加点按钮禁用：" + attribute_id)
	_check(_authority(ui) == npc_before, "同学详情入口不会偷偷给本人或NPC加点")
	ui.attribute_dialog.hide()
	ui._select_student(0)
	ui.attribute_entry_button.pressed.emit()
	for _point in initial_points - ATTRIBUTE_IDS.size():
		ui.attribute_buttons.intelligence.pressed.emit()
	_check(ui.simulation.students[0].unspent_points == 0, "真实按钮可以花完全部剩余点")
	for attribute_id: String in ATTRIBUTE_IDS:
		_check(ui.attribute_buttons[attribute_id].disabled, "点数耗尽后禁用加点：" + attribute_id)
	ui.attribute_dialog.hide()
	return not ui.fatal_error


## 镜头逐场切换只改变画面，草稿、随机流和权威地点均保持不变。
func _test_scene_controls(ui: Control) -> void:
	ui._set_interaction_target(2)
	ui.note_input.text = "镜头与动作入口不转移这份草稿"
	ui.note_input.text_changed.emit(ui.note_input.text)
	var drafts: Dictionary = _drafts(ui)
	var before: Dictionary = _authority(ui)
	_check(ui.room.get_view_mode() == "auto", "新局镜头默认自动跟随本人")
	for scene_id: String in SCENE_IDS:
		if not _choose(ui.scene_picker, scene_id, "镜头"):
			return
		_check(ui.room.get_view_mode() == scene_id, "镜头选择保存真实观察模式：" + scene_id)
		_check(ui.room.get_view_location() == (ui.simulation.student_location(0) if scene_id == "auto" else scene_id), "实际镜头地点符合选择：" + scene_id)
		_check(_authority(ui) == before, "选择镜头不发令、不结算、不挪动角色：" + scene_id)
		_check(_drafts(ui) == drafts, "镜头切换保留收件人与草稿：" + scene_id)
	_choose(ui.scene_picker, "auto", "自动跟随镜头")
	var scenes: Array[Dictionary] = [
		{"seconds": 42000.0, "location": "canteen"},
		{"seconds": 50400.0, "location": "playground"},
		{"seconds": 77400.0, "location": "dorm"},
	]
	for scenario: Dictionary in scenes:
		if not _result(ui.simulation.set_debug_time(1, scenario.seconds), "定位真实场景时段", ui.simulation.error_message):
			return
		if not _result(ui.simulation.advance(0.0), "真实树开始对应课表活动", ui.simulation.error_message):
			return
		ui._refresh_interface()
		await process_frame
		_check(ui.simulation.student_location(0) == scenario.location and ui.room.get_view_location() == scenario.location, "自动镜头跟随真实课程地点：" + scenario.location)
		_check(_drafts(ui) == drafts, "真实时段切换不发送或转移草稿")


## 个人动作由底栏真实入口发起，查看NPC不改变指令始终控制本人的语义。
func _test_personal_actions(ui: Control) -> bool:
	if not _reset_session(ui, 1):
		return false
	ui._select_student(1)
	var npc_before: Array = ui.simulation.students.slice(1).duplicate(true)
	ui.personal_action_entry_button.pressed.emit()
	await process_frame
	_check(ui.personal_action_dialog.visible, "底栏行动入口打开真实个人动作对话框")
	var actual_ids: Array[String] = []
	for index in ui.personal_action_picker.item_count:
		var action_id: String = str(ui.personal_action_picker.get_item_metadata(index))
		actual_ids.append(action_id)
		var definition: Dictionary = ui.configuration.actions[action_id]
		_check(definition.target == "self" and definition.source in ["player", "both"], "个人列表只包含已开放的本人主动动作：" + action_id)
		_check(action_id in ui.simulation.phase_scope.enabled_actions and action_id not in ["focus_command", "rest", "sleep", "linger_break"], "个人列表不重复基础按钮或开放自主专用动作：" + action_id)
	var expected_ids: Array[String] = [
		"snack_self", "lunch_rest", "read_comic", "bathroom", "sprint_study",
		"preview", "notes", "self_test", "standing_study", "chores", "exercise_slack",
		"remind_self", "wake_self", "recall_classroom", "read_comic_item", "eat_candy_item",
	]
	actual_ids.sort()
	expected_ids.sort()
	_check(actual_ids == expected_ids, "个人列表完整覆盖本轮16项主动动作，不把课表默认活动开放为任意指令")
	if not _choose(ui.personal_action_picker, "sprint_study", "个人动作"):
		return false
	_check(not ui.personal_action_text.get_parsed_text().is_empty(), "选择动作显示真实配表费用和效果")
	_check(not ui.personal_action_button.disabled, "前置满足时真实开始按钮可用")
	ui.personal_action_button.pressed.emit()
	_check(ui.simulation.students[0].current_action.action_id == "sprint_study", "查看同学时发令仍启动本人的冲刺学习")
	_check(ui.simulation.students.slice(1) == npc_before, "个人动作不改变查看同学及其他NPC")
	_check(_has_buff(ui, "sprinting"), "按钮接通真实冲刺状态")
	_check(not ui.fatal_error, "正常个人动作不会停止有效局")
	var duration: float = ui.simulation.students[0].current_action.ends_at - ui.simulation.elapsed_s
	if not _result(ui.simulation.advance(duration), "真实完成界面启动的冲刺动作", ui.simulation.error_message):
		return false
	ui._refresh_interface()
	_check(not _has_buff(ui, "sprinting") and ui.simulation.students[0].knowledge.chinese > 0.0, "冲刺产生真实知识并按动作结束清理状态")
	ui.personal_action_dialog.hide()
	return true


## 自用物品必须实际来自课程抽奖，按钮开始扣物，完成收益由真实时间推进产生。
func _test_real_item_use(ui: Control) -> bool:
	var seeds: Dictionary = {"snack": 1, "comic": 2, "candy": 6}
	for item_id: String in ITEM_ACTIONS:
		if not _reset_session(ui, int(seeds[item_id])):
			return false
		var inventory_count: int = int(ui.simulation.students[0].inventory.get(item_id, 0))
		if not _check(inventory_count > 0 and _events(ui, "daily_items", 0).size() == 1, "使用前物品来自一次真实课程发奖：" + item_id):
			return false
		ui._set_interaction_target(3)
		ui.note_input.text = "背包自用仍保留给同学的草稿"
		ui.note_input.text_changed.emit(ui.note_input.text)
		var drafts: Dictionary = _drafts(ui)
		ui.inventory_entry_button.pressed.emit()
		if not _choose(ui.inventory_action_picker, ITEM_ACTIONS[item_id], "背包自用"):
			return false
		_check(not ui.inventory_use_button.disabled, "实际持物时自用按钮可用：" + item_id)
		ui.inventory_use_button.pressed.emit()
		var instance: Dictionary = ui.simulation.students[0].current_action.duplicate(true)
		_check(instance.action_id == ITEM_ACTIONS[item_id], "背包按钮启动真实物品动作：" + item_id)
		_check(ui.simulation.students[0].inventory[item_id] == inventory_count - 1, "成功发动准确消费一件真实物品：" + item_id)
		var consumed: Array[Dictionary] = _events(ui, "consume_item", 0)
		_check(consumed.size() == 1 and consumed[0].details.item_id == item_id and consumed[0].details.instance_id == instance.instance_id, "消费日志关联真实物品和动作实例：" + item_id)
		_check(_drafts(ui) == drafts, "物品自用保留原收件人与草稿")
		if not _result(ui.simulation.advance(float(instance.ends_at) - ui.simulation.elapsed_s), "实际完成物品动作：" + item_id, ui.simulation.error_message):
			return false
		ui._refresh_interface()
		_check(_events(ui, "complete", 0).any(func(entry: Dictionary): return entry.details.instance_id == instance.instance_id), "物品收益有真实完成记录：" + item_id)
		if item_id == "comic":
			_check(_has_buff(ui, "comic_afterglow"), "完成真实漫画自用后才获得余韵状态")
		ui._select_student(1)
		ui.inventory_entry_button.pressed.emit()
		var npc_before: Dictionary = _authority(ui)
		_check(ui.inventory_action_picker.disabled and ui.inventory_use_button.disabled, "查看同学背包时自用选择和按钮均只读")
		ui.inventory_use_button.pressed.emit()
		await _acknowledge_error(ui, "只能使用自己的物品")
		_check(_authority(ui) == npc_before, "过期的自用点击也不能消耗同学或本人库存")
	return true


## 缺物拒绝在真实入口重新核验，不能先打断旧动作或使有效局进入致命停止。
func _test_rejection(ui: Control) -> bool:
	if not _reset_without_items(ui, ITEM_ACTIONS.keys()):
		return false
	ui._select_student(0)
	ui.inventory_entry_button.pressed.emit()
	for item_id: String in ITEM_ACTIONS:
		if not _check(int(ui.simulation.students[0].inventory.get(item_id, 0)) == 0, "缺物场景来自真实抽奖结果：" + item_id):
			return false
		if not _choose(ui.inventory_action_picker, ITEM_ACTIONS[item_id], "缺物自用"):
			return false
		_check(ui.inventory_use_button.disabled, "库存不足时界面禁用自用按钮：" + item_id)
		var reason: String = ui.simulation.action_unavailable_reason(0, ITEM_ACTIONS[item_id])
		var before: Dictionary = _authority(ui)
		# 模拟控件刷新前已经排队的点击，入口仍必须重新检查真实库存。
		ui.inventory_use_button.pressed.emit()
		await _acknowledge_error(ui, reason)
		_check(_authority(ui) == before, "缺物拒绝保留旧动作、资源、库存、随机流及日志：" + item_id)
		_check(not ui.fatal_error, "普通库存不足不停止原有效局：" + item_id)
	ui.personal_action_entry_button.pressed.emit()
	if not _choose(ui.personal_action_picker, "snack_self", "个人动作缺物"):
		return false
	var before: Dictionary = _authority(ui)
	_check(ui.personal_action_button.disabled and not ui.personal_action_reason.text.is_empty(), "个人动作列表同样显示真实缺物原因")
	var reason: String = ui.simulation.action_unavailable_reason(0, "snack_self")
	ui.personal_action_button.pressed.emit()
	await _acknowledge_error(ui, reason)
	_check(_authority(ui) == before and not ui.fatal_error, "个人动作缺物再次拒绝且不破坏有效旧动作")
	ui.personal_action_dialog.hide()
	ui.error_dialog.hide()
	return true


## 通过真实保存按钮写隔离开发局，再走生产恢复验证不重扣消费或补发离线权益。
func _test_save_and_offline(ui: Control) -> bool:
	if not _reset_session(ui, 2):
		return false
	ui.attribute_entry_button.pressed.emit()
	ui.attribute_buttons.attention.pressed.emit()
	ui.attribute_dialog.hide()
	ui.inventory_entry_button.pressed.emit()
	if not _choose(ui.inventory_action_picker, "read_comic_item", "保存前物品自用"):
		return false
	ui.inventory_use_button.pressed.emit()
	if not _result(ui.simulation.advance(30.0), "在途阅读真实执行三十秒", ui.simulation.error_message):
		return false
	ui._refresh_interface()
	var before: Dictionary = _authority(ui)
	var save_button: Button = _find_button(ui, "保存当前正式局或开发局")
	if not _check(save_button != null, "找到生产顶部保存按钮"):
		return false
	save_button.pressed.emit()
	if not _check(FileAccess.file_exists("user://classroom_debug_save.json"), "真实保存按钮写入隔离开发局"):
		return false
	_check(not FileAccess.file_exists("user://classroom_save.json"), "开发局保存不冒充正式局文件")
	var after_save: Dictionary = _authority(ui)
	var frozen: Dictionary = after_save.round.frozen
	_check(frozen.day == ui.simulation.day and frozen.clock_seconds == ui.simulation.clock_seconds, "保存冻结来源准确更新为当前真实边界")
	# 保存按约定刷新离线冻结来源；其他账本与角色业务数据必须保持不变。
	after_save.round.erase("frozen")
	before.round.erase("frozen")
	_check(after_save == before, "保存只更新冻结来源，不推进时间、不重扣物品或改变角色结果")
	var restored := ClassroomSimulation.new()
	if not _result(restored.setup(ui.configuration, 998), "建立真实恢复目标", restored.error_message):
		return false
	if not _result(restored.load_file("user://classroom_debug_save.json", false), "生产恢复在途自用动作", restored.error_message):
		return false
	_check(_same(restored.students, ui.simulation.students) and str(restored.rng.state) == before.rng_state, "存档往返保留实际加点、库存、动作进度和随机流")
	var offline := ClassroomSimulation.new()
	if not _result(offline.setup(ui.configuration, 999), "建立跨日恢复目标", offline.error_message):
		return false
	if not _result(offline.load_file_at_time("user://classroom_debug_save.json", 3, 28800.0), "生产冻结来源跨两日恢复", offline.error_message):
		return false
	for index in 4:
		var saved: Dictionary = ui.simulation.students[index]
		var actual: Dictionary = offline.students[index]
		_check(_same(actual.knowledge, saved.knowledge) and _same(actual.inventory, saved.inventory), "离线恢复不学习、不发物品或退回消费：%d" % index)
		_check(_same(actual.focus, saved.focus) and _same(actual.stamina, saved.stamina), "离线恢复不赠专注与体力：%d" % index)
		_check(_same(actual.attributes, saved.attributes) and actual.unspent_points == saved.unspent_points, "离线恢复不补每日点或替NPC加点：%d" % index)
	_check(offline.notes == ui.simulation.notes and str(offline.rng.state) == before.rng_state, "离线恢复不送纸条或抽取额外随机结果")
	return true


## 新控件和弹窗在既定1x/2x尺寸中完整排版，切页与查看不修改业务状态。
func _test_layout(ui: Control) -> void:
	ui._select_student(0)
	var before: Dictionary = _authority(ui)
	for scale_value in [1, 2]:
		ui._set_window_scale(scale_value)
		ui._refresh_interface()
		ui.inventory_entry_button.pressed.emit()
		await process_frame
		await process_frame
		var expected := Vector2i(684, 320) if scale_value == 1 else Vector2i(1068, 576)
		_check(Vector2i(ui.size) == expected and ui._get_layout_size() == expected, "%d倍新增控件保持既定展开尺寸" % scale_value)
		# 该组省略原生控制器，显式令隔离宿主视口采用生产布局尺寸。
		root.size = expected
		_check_clock_text(ui, "%d倍开发时钟" % scale_value)
		for tab_index in 6:
			ui.inspector_tabs.current_tab = tab_index
			await process_frame
			await process_frame
			_check_control_bounds(ui, Rect2(ui.global_position, ui.size).grow(1.0), "%d倍第%d页" % [scale_value, tab_index])
		ui._select_student(0)
		ui.attribute_entry_button.pressed.emit()
		await process_frame
		await process_frame
		_check_dialog(ui.attribute_dialog, "%d倍属性弹窗" % scale_value)
		ui.attribute_dialog.hide()
		ui.personal_action_entry_button.pressed.emit()
		await process_frame
		await process_frame
		_check_dialog(ui.personal_action_dialog, "%d倍行动弹窗" % scale_value)
		ui.personal_action_dialog.hide()
	_check(_authority(ui) == before, "布局、切页、弹窗与缩放均不改权威状态")
	# 普通时钟从生产新局入口读取真实电脑时间，不伪改开发局时间来源标记。
	ui._start_session(false)
	_check(ui.simulation != null and not ui.fatal_error and not ui.simulation.is_debug_time, "生产新局采用真实电脑时间")
	ui._select_student(0)
	for scale_value in [1, 2]:
		ui._set_window_scale(scale_value)
		ui._refresh_interface()
		root.size = ui._get_layout_size()
		await process_frame
		await process_frame
		_check_clock_text(ui, "%d倍电脑时钟" % scale_value)


## 真实推进到终局后所有新玩法入口禁用，镜头与六页仍可只读查看。
func _test_terminal(ui: Control) -> bool:
	if not _reset_session(ui, 1):
		return false
	ui._set_interaction_target(2)
	ui.note_input.text = "终局保留的未发送草稿"
	ui.note_input.text_changed.emit(ui.note_input.text)
	var drafts: Dictionary = _drafts(ui)
	var summary: Dictionary = ui.simulation.get_round_summary()
	var target: float = (int(summary.final_day) - 1.0) * 86400.0 + float(summary.final_seconds)
	if not _result(ui.simulation.advance(target - ui.simulation.clock_seconds), "真实课程连续推进至七天终局", ui.simulation.error_message):
		return false
	ui._refresh_interface()
	_check(ui.simulation.is_round_finished(), "实际七天账本确认局末")
	ui._select_student(0)
	ui.inventory_entry_button.pressed.emit()
	_check(ui.attribute_entry_button.disabled and ui.personal_action_entry_button.disabled and ui.inventory_use_button.disabled, "局末禁用加点、个人动作和物品自用入口")
	var before: Dictionary = _authority(ui)
	ui.personal_action_button.pressed.emit()
	ui.inventory_use_button.pressed.emit()
	for attribute_id: String in ATTRIBUTE_IDS:
		ui.attribute_buttons[attribute_id].pressed.emit()
	await _acknowledge_error(ui, "本局已结束")
	_check(_authority(ui) == before, "终局排队点击不能改写已结束的真实结果")
	for scene_id: String in SCENE_IDS:
		if not _choose(ui.scene_picker, scene_id, "终局镜头"):
			return false
	ui._show_round_boards()
	ui._show_records()
	ui.inventory_entry_button.pressed.emit()
	_check(_authority(ui) == before, "终局镜头、榜单、记录和背包仍严格只读")
	_check(_drafts(ui) == drafts, "局末新入口不发送或丢弃原会话草稿")
	return true


## 通过OptionButton真实选择信号切换，不直接调用生产业务处理方法。
func _choose(picker: OptionButton, metadata: String, context: String) -> bool:
	for index in picker.item_count:
		if str(picker.get_item_metadata(index)) == metadata:
			picker.select(index)
			picker.item_selected.emit(index)
			return true
	return _check(false, "%s没有所需选项：%s" % [context, metadata])


## 业务比较包含账本、动作编号与随机流，排除仅用于呈现错误的文字状态。
func _authority(ui: Control) -> Dictionary:
	var simulation: ClassroomSimulation = ui.simulation
	return {
		"students": simulation.students.duplicate(true), "logs": simulation.logs.duplicate(true),
		"interactions": simulation.interactions.duplicate(true), "notes": simulation.notes.duplicate(true),
		"violations": simulation.violations.duplicate(true), "day": simulation.day,
		"clock_seconds": simulation.clock_seconds, "elapsed_s": simulation.elapsed_s,
		"rng_seed": str(simulation.rng.seed), "rng_state": str(simulation.rng.state),
		"round": simulation.round_progression.data.duplicate(true),
		"next_action_number": simulation.next_action_number,
		"next_interaction_number": simulation.next_interaction_number,
		"next_violation_number": simulation.next_violation_number,
	}


## 草稿与收件人属于界面状态，单独证明镜头和新玩法没有转移会话。
func _drafts(ui: Control) -> Dictionary:
	return {"recipient": ui.interaction_target_index, "text": ui.note_input.text, "drafts": ui.note_drafts.duplicate(true)}


## 等生产错误真正显示后验证原因并关闭，不能把延后弹窗泄漏给后续布局场景。
func _acknowledge_error(ui: Control, expected: String) -> void:
	await process_frame
	await process_frame
	_check(ui.error_dialog.visible and not expected.is_empty() and ui.error_dialog.dialog_text.contains(expected), "生产错误窗口显示明确拒绝原因：" + expected)
	ui.error_dialog.hide()
	await process_frame


## JSON普通浮点仅容忍表示误差，整数、字符串和容器结构仍精确比较。
func _same(left: Variant, right: Variant) -> bool:
	if left is Dictionary and right is Dictionary:
		if left.size() != right.size():
			return false
		for key: Variant in left:
			if not right.has(key) or not _same(left[key], right[key]):
				return false
		return true
	if left is Array and right is Array:
		if left.size() != right.size():
			return false
		for index in left.size():
			if not _same(left[index], right[index]):
				return false
		return true
	if left is int and right is int:
		return left == right
	if (left is int or left is float) and (right is int or right is float):
		return absf(float(left) - float(right)) < 0.0000000001
	return typeof(left) == typeof(right) and left == right


## 读取执行器真实状态，不为缺失业务效果补造实例。
func _has_buff(ui: Control, buff_id: String) -> bool:
	for buff: Dictionary in ui.simulation.students[0].buffs:
		if buff.buff_id == buff_id:
			return true
	return false


## 只筛选执行器已写入日志，物品与完成必须具有可追溯来源。
func _events(ui: Control, event_type: String, student_index: int) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for entry: Dictionary in ui.simulation.logs:
		if entry.type == event_type and entry.student_index == student_index:
			entries.append(entry)
	return entries


## 从生产界面找到已存在的保存按钮，不新造测试专用保存入口。
func _find_button(node: Node, tooltip: String) -> Button:
	if node is Button and node.tooltip_text == tooltip:
		return node
	for child: Node in node.get_children():
		var found: Button = _find_button(child, tooltip)
		if found != null:
			return found
	return null


## 弹窗内容采用自己的视口坐标验证，独立Window不混入主界面坐标。
func _check_dialog(dialog: Window, context: String) -> void:
	_check(dialog.visible, context + "已经显示")
	_check(dialog.size.x <= root.size.x and dialog.size.y <= root.size.y, context + "不超过宿主窗口")
	_check_control_bounds(dialog, Rect2(Vector2.ZERO, Vector2(dialog.size)).grow(1.0), context)


## 按实际字体测量完整时钟，控件在边界内也不能掩盖文字被省略的问题。
func _check_clock_text(ui: Control, context: String) -> void:
	var label: Label = ui.clock_label
	var width: float = label.get_theme_font("font").get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, label.get_theme_font_size("font_size")).x
	_check(label.is_visible_in_tree() and label.size.x + 1.0 >= ceilf(width), "%s完整显示而非省略：%s，宽度%s/%s" % [context, label.text, width, label.size.x])
	_check(label.tooltip_text.contains("第%d天" % ui.simulation.day) and label.tooltip_text.contains(ui._clock(ui.simulation.clock_seconds)), context + "悬停显示真实日与完整秒数")
	if ui.simulation.is_debug_time:
		_check(label.text.contains("开发") and label.tooltip_text.contains("开发"), context + "保留明确开发来源")
	if not ui.simulation.is_debug_time or ui.window_scale == 2:
		_check(label.text.contains(ui._clock(ui.simulation.clock_seconds)), context + "直接显示完整秒数")


## 固定区域内检查所有可见控件，隐藏页与滚动内容不被误判为窗口扩张。
func _check_control_bounds(node: Node, bounds: Rect2, context: String) -> void:
	if node is Control and node.is_visible_in_tree() and node.size.x > 0.0 and node.size.y > 0.0:
		_check(bounds.encloses(node.get_global_rect()), "%s控件在边界内：%s %s" % [context, node.name, node.get_global_rect()])
	for child: Node in node.get_children():
		if not child is Window:
			_check_control_bounds(child, bounds, context)


## 每个前置失败均保留真实原因，依赖它的后续业务不继续伪造结果。
func _result(result: Error, message: String, detail: String = "") -> bool:
	return _check(result == OK, "%s：%s" % [message, detail])


## 只计数实际执行断言，失败统一留待最终非零退出。
func _check(condition: bool, message: String) -> bool:
	checks += 1
	if not condition:
		failures.append(message)
	return condition


## 汇总真实UI接线结果，无头通过不能替代原生桌面和GPU显示验收。
func _finish() -> void:
	if failures.is_empty():
		print("SINGLE_PLAYER_UI_TEST_PASS checks=%d real_controls_real_items native_tray_not_tested" % checks)
		quit(0)
	else:
		for message: String in failures:
			push_error(message)
		print("SINGLE_PLAYER_UI_TEST_FAIL checks=%d failures=%d" % [checks, failures.size()])
		quit(1)
