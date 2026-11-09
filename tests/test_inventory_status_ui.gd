extends SceneTree
## 在隔离工程中检查真实上课发奖、只读背包与状态展示，库存夹具另行明确标记。

# 仅统计真实断言，生产存档、原生托盘和物品使用不属于本组检查。
var checks: int = 0
var failures: Array[String] = []


## 等待场景树就绪后，在独立工程内启动真实界面检查。
func _initialize() -> void:
	call_deferred("_run")


## 双重验证专用用户目录，测试前置库存不能写入正式玩家环境。
func _run() -> void:
	if "--isolated-inventory-status-ui" not in OS.get_cmdline_user_args():
		_launch_isolated_project()
		return
	var marker: String = str(ProjectSettings.get_setting("application/config/name"))
	if not marker.begins_with("ClassroomInventoryStatusUiTest_") or marker not in OS.get_user_data_dir():
		push_error("背包状态界面测试用户目录未隔离，拒绝运行。")
		quit(1)
		return
	# 脚本运行错误必须明确结束子进程，避免隔离测试一直等待。
	create_timer(45.0).timeout.connect(func():
		_check(false, "背包状态界面验收超时，可能存在未处理脚本错误")
		_finish()
	)
	await _test_interface()
	_finish()


## 复制生产源文件并设置独立应用名称，导入与用户文件均留在隔离工程。
func _launch_isolated_project() -> void:
	var marker: String = "ClassroomInventoryStatusUiTest_%s_%s" % [OS.get_process_id(), Time.get_ticks_usec()]
	var isolated_root: String = OS.get_cache_dir().path_join(marker)
	for folder in ["scripts", "config", "assets", "addons", "scenes", "tests"]:
		var result: Error = _copy_directory(ProjectSettings.globalize_path("res://" + folder), isolated_root.path_join(folder))
		if result != OK:
			push_error("复制背包状态隔离工程失败：%s，错误码%s。" % [folder, result])
			quit(1)
			return
	var project := ConfigFile.new()
	if project.load("res://project.godot") != OK:
		push_error("无法读取背包状态测试所需的真实工程设置。")
		quit(1)
		return
	project.set_value("application", "config/name", marker)
	project.set_value("application", "config/use_custom_user_dir", true)
	project.set_value("application", "config/custom_user_dir_name", marker)
	if project.save(isolated_root.path_join("project.godot")) != OK:
		push_error("无法保存背包状态隔离工程设置。")
		quit(1)
		return
	var output: Array = []
	var exit_code: int = OS.execute(OS.get_executable_path(), ["--headless", "--path", isolated_root, "--editor", "--import"], output, true)
	if exit_code != 0:
		for line in output:
			print(line)
		quit(exit_code)
		return
	output.clear()
	exit_code = OS.execute(OS.get_executable_path(), ["--headless", "--path", isolated_root, "--script", "res://tests/test_inventory_status_ui.gd", "--", "--isolated-inventory-status-ui"], output, true)
	for line in output:
		print(line)
	print("INVENTORY_STATUS_UI_TEST_PROJECT=%s" % isolated_root)
	quit(exit_code)


## 逐项复制测试所需目录；资源或写入失败直接返回真实错误。
func _copy_directory(source: String, destination: String) -> Error:
	var directory := DirAccess.open(source)
	if directory == null:
		return ERR_CANT_OPEN
	var result: Error = DirAccess.make_dir_recursive_absolute(destination)
	if result != OK:
		return result
	for folder in directory.get_directories():
		result = _copy_directory(source.path_join(folder), destination.path_join(folder))
		if result != OK:
			return result
	for filename in directory.get_files():
		result = DirAccess.copy_absolute(source.path_join(filename), destination.path_join(filename))
		if result != OK:
			return result
	return OK


## 真实界面使用正式配置与四人执行器，只省略无头环境不支持的原生桌面初始化。
func _test_interface() -> void:
	var ui := Control.new()
	root.add_child(ui)
	ui.set_script(load("res://scripts/ui/main.gd"))
	ui.set_process(false)
	for method in ["_show_inventory", "_refresh_inventory_interface", "_refresh_status_effects"]:
		if not ui.has_method(method):
			_check(false, "生产界面缺少背包状态入口：%s" % method)
			ui.free()
			return
	ui._build_theme()
	ui._build_interface()
	var configuration := GameConfig.new()
	_check(configuration.load_file() == OK, "背包状态界面读取正式配置并通过完整校验")
	ui.configuration = configuration
	_reset_session(ui, 0.0)
	_check(ui.inventory_text is RichTextLabel and ui.status_effects_text is RichTextLabel, "背包和状态使用真实可滚动文本控件")
	_check(ui.inspector_tabs.get_tab_count() == 6, "榜单追加第六页，背包仍为第五页")
	for index in 6:
		_check(ui.inspector_tabs.get_tab_title(index) == ["人物", "课表", "记录", "互动", "背包", "榜单"][index], "第%d页保持已约定的名称与索引" % index)
	_test_empty_inventory(ui)
	_test_real_daily_items(ui)
	_test_inventory_ownership_and_read_only(ui)
	await _test_layout(ui, 1, Vector2i(684, 320))
	await _test_layout(ui, 2, Vector2i(1068, 576))
	await _test_long_inventory(ui)
	await _test_timed_status(ui)
	_test_action_status(ui)
	_check(not FileAccess.file_exists("user://classroom_save.json") and not FileAccess.file_exists("user://classroom_debug_save.json"), "背包状态展示没有写入正式局或开发局文件")
	print("INVENTORY_STATUS_UI_TEST_USER_DIR=%s" % OS.get_user_data_dir())
	ui.free()


## 新局先设置明确时刻再走生产绑定，避免本机时间先触发课程或上一场景遗留已领库存。
func _reset_session(ui: Control, seconds: float = 28800.0) -> void:
	if is_instance_valid(ui.behavior):
		ui.remove_child(ui.behavior)
		ui.behavior.queue_free()
	ui.simulation = ClassroomSimulation.new()
	_check(ui.simulation.setup(ui.configuration, 42517) == OK, "界面展示夹具建立真实四人新局")
	_check(ui.simulation.set_debug_time(1, seconds) == OK, "首次推进前设置明确的第1天课表时刻")
	ui._attach_behavior()
	_check(not ui.fatal_error and ui.simulation != null, "生产绑定为四人建立共享行为树并安排实际活动")


## 新局空背包和空状态直接来自真实数据，打开页面不产生奖励或业务变化。
func _test_empty_inventory(ui: Control) -> void:
	_check(ui.simulation.course_context().kind == "outside", "空背包检查来自新局课外时刻，不清空已发课程奖励")
	for student in ui.simulation.students:
		_check(student.inventory.is_empty() and student.daily_item_claim_days.is_empty(), "新局课外同学保持真实空库存和未发奖记录：%s" % student.name)
	var before: Dictionary = _authoritative_snapshot(ui)
	ui._show_inventory()
	_check(ui.inspector_panel.visible and ui.inspector_tabs.current_tab == 4, "背包入口展开第五页")
	_check(ui.inventory_owner_label.text.contains(String(ui.simulation.students[0].name)), "空背包仍标明真实查看对象")
	_check(ui.inventory_text.get_parsed_text().contains("暂无物品"), "真实空背包显示明确空态")
	_check(ui.status_effects_text.get_parsed_text().contains("暂无生效状态"), "没有生效状态时显示明确空态")
	_check(ui.attributes_label.text.contains("基础") and ui.status_effects_text.get_parsed_text().contains("有效"), "基础属性与有效属性分别说明")
	_check(_authoritative_snapshot(ui) == before, "打开空背包不扣资源、不抽奖、不消耗随机流或写业务日志")


## 第一节真实开始后四人各自到账，界面只展示权威库存与发奖记录，不额外触发领取。
func _test_real_daily_items(ui: Control) -> void:
	_check(ui.simulation.set_debug_time(1, 28800.0) == OK, "同一真实空包新局进入第一天第一节")
	_check(ui.simulation.advance(0.0) == OK, "共享行为树成功开始当前课程并触发每日物品")
	ui._refresh_interface()
	var draw_count: int = int(ui.configuration.global_value("daily_item_draw_count"))
	for student_index in ui.simulation.students.size():
		var student: Dictionary = ui.simulation.students[student_index]
		_check(student.daily_item_claim_days == [1], "同学%s的首次上课已记录第1天且无重复领取日" % student.name)
		var entries: Array[Dictionary] = _daily_item_entries(ui, student_index)
		_check(entries.size() == 1, "同学%s只有一条真实每日发奖日志" % student.name)
		if entries.size() != 1:
			continue
		var receipt: Dictionary = entries[0]
		_check(receipt.details.claim_day == 1 and receipt.details.action_id == ui.simulation.course_context().default_action_id, "发奖日志绑定真实日期与成功开始的课程动作")
		_check(receipt.details.draws.size() == draw_count, "发奖日志保留当前配表要求的逐次抽取结果")
		_check(not student.inventory.is_empty() and receipt.details.items == student.inventory, "首次真实发奖汇总与角色实际到账背包一致")
		ui._select_student(student_index)
		ui.inventory_entry_button.pressed.emit()
		_check(ui.inspector_tabs.current_tab == 4 and ui.inventory_owner_label.text.contains(String(student.name)), "真实上课后背包入口显示对应同学的库存")
		var content: String = ui.inventory_text.get_parsed_text()
		_check(not content.contains("暂无物品"), "已经真实到账的背包不沿用空态")
		var previous_position: int = -1
		for definition in ui.configuration.tables.items:
			if student.inventory.has(definition.id) and student.inventory[definition.id] > 0:
				var item_line: String = "%s × %d" % [definition.name, student.inventory[definition.id]]
				var item_position: int = content.find(item_line)
				_check(item_position > previous_position and content.contains(String(definition.description)), "真实到账物品按配表顺序显示实际数量与说明：%s" % definition.name)
				previous_position = item_position
		_check(ui.log_text.get_parsed_text().contains(String(receipt.message)), "班级记录显示执行器实际发奖日志，不生成领取成功假消息")
	ui._set_interaction_target(1)
	ui.note_input.text = "发奖后查看背包仍保留原收件人的草稿"
	ui._on_note_text_changed(ui.note_input.text)
	var target_before: int = ui.interaction_target_index
	var draft_before: String = ui.note_input.text
	var drafts_before: Dictionary = ui.note_drafts.duplicate(true)
	var before: Dictionary = _authoritative_snapshot(ui)
	for _round in 3:
		for student_index in ui.simulation.students.size():
			ui._select_student(student_index)
			ui.inventory_entry_button.pressed.emit()
			ui._refresh_interface()
			for tab_index in 6:
				ui.inspector_tabs.current_tab = tab_index
				ui._refresh_interface()
			ui._show_inventory()
	_check(_authoritative_snapshot(ui) == before, "到账后反复切对象、打开背包、刷新和切六页均不重领、不改权威状态或随机流")
	_check(ui.interaction_target_index == target_before and ui.note_input.text == draft_before and ui.note_drafts == drafts_before, "真实发奖后的只读查看仍保留原收件人与按人草稿")
	for student_index in ui.simulation.students.size():
		_check(_daily_item_entries(ui, student_index).size() == 1, "重复查看后同学%d仍只有首次上课的一条发奖记录" % student_index)


## 三件库存仅是展示前置夹具，不将测试赋值描述成每日领取或物品使用。
func _test_inventory_ownership_and_read_only(ui: Control) -> void:
	_reset_session(ui, 0.0)
	ui.simulation.students[0].inventory = {"eraser": 2, "snack": 1, "candy": 0}
	ui.simulation.students[1].inventory = {"comic": 3}
	ui._select_student(1)
	ui._show_interactions()
	ui.note_input.text = "背包切页后仍给原同学的草稿"
	ui._on_note_text_changed(ui.note_input.text)
	var draft_text: String = ui.note_input.text
	var drafts: Dictionary = ui.note_drafts.duplicate(true)
	var target_index: int = ui.interaction_target_index
	var before: Dictionary = _authoritative_snapshot(ui)
	ui._select_student(0)
	ui._show_inventory()
	var own_text: String = ui.inventory_text.get_parsed_text()
	_check(own_text.contains(String(ui.configuration.items.eraser.name) + " × 2") and own_text.contains(String(ui.configuration.items.snack.name) + " × 1"), "玩家背包按实际数量显示两块橡皮和一份零食")
	for item_id in ["eraser", "snack"]:
		_check(own_text.contains(String(ui.configuration.items[item_id].description)), "背包说明读取当前JSON：%s" % item_id)
	_check(not own_text.contains(String(ui.configuration.items.candy.name)), "零数量物品不冒充持有库存")
	_check(not own_text.contains(String(ui.configuration.items.comic.name)), "查看玩家时不混入同学的漫画")
	ui._select_student(1)
	ui._show_inventory()
	_check(ui.inventory_owner_label.text.contains(String(ui.simulation.students[1].name)), "切换同学后背包标题采用该同学姓名")
	var other_text: String = ui.inventory_text.get_parsed_text()
	_check(other_text.contains(String(ui.configuration.items.comic.name) + " × 3") and not other_text.contains(String(ui.configuration.items.eraser.name)), "同学背包采用该角色独立库存")
	ui._select_student(2)
	ui._show_inventory()
	_check(ui.inventory_text.get_parsed_text().contains("暂无物品"), "空背包同学不会沿用前一个人的库存内容")
	for index in 4:
		ui._select_student(index)
		ui._show_inventory()
		ui._refresh_interface()
	_check(ui.interaction_target_index == target_index and ui.note_input.text == draft_text and ui.note_drafts == drafts, "查看不同背包不转移收件人或改写各自草稿")
	_check(_authoritative_snapshot(ui) == before, "重复查看库存不改变角色、动作、资源、随机流和业务日志")
	ui._select_student(0)
	ui._show_inventory()


## 五页均在既定整数尺寸内排版，页面增多不能扩大根窗口或挤掉人物状态区。
func _test_layout(ui: Control, scale: int, expected_size: Vector2i) -> void:
	ui._set_window_scale(scale)
	ui._show_inventory()
	await process_frame
	await process_frame
	_check(ui._get_layout_size() == expected_size and Vector2i(ui.size) == expected_size, "%d倍六页详情保持既定窗口尺寸" % scale)
	var bounds := Rect2(ui.global_position, ui.size).grow(1.0)
	for index in 6:
		ui.inspector_tabs.current_tab = index
		await process_frame
		await process_frame
		_check(Vector2i(ui.size) == expected_size, "%d倍切换第%d页不改变窗口尺寸" % [scale, index])
		_check_control_bounds(ui, bounds, "%d倍第%d页" % [scale, index])
		if index == 0:
			_check(ui.status_effects_text.is_visible_in_tree() and ui.status_effects_text.size.y >= 40.0, "%d倍人物页保留至少40像素的状态滚动区域" % scale)
			# 新增宿舍附加内容允许滚动，但原有效属性和空态必须仍是首屏完整的前三行。
			var status_lines: PackedStringArray = ui.status_effects_text.get_parsed_text().split("\n")
			var required_order: bool = status_lines.size() >= 3 and status_lines[0].begins_with("有效 ") and status_lines[1].begins_with("健康 ") and status_lines[2] == "暂无生效状态"
			var third_line_bottom: float = ui.status_effects_text.get_line_offset(2) + ui.status_effects_text.get_line_height(2)
			_check(required_order and ui.status_effects_text.get_character_line(ui.status_effects_text.get_parsed_text().find("暂无生效状态")) == 2 and third_line_bottom <= ui.status_effects_text.size.y + 1.0 and ui.status_effects_text.get_v_scroll_bar().value == 0.0, "%d倍人物页可直接看到有效属性两行与空态第三行" % scale)
			# 按真实字体测量人数文字，防止控件虽在窗口内却被姓名挤成不可读的窄条。
			var caption: Label = ui.scene_caption
			var text_width: float = caption.get_theme_font("font").get_string_size(caption.text, HORIZONTAL_ALIGNMENT_LEFT, -1, caption.get_theme_font_size("font_size")).x
			_check(caption.is_visible_in_tree() and caption.size.x + 1.0 >= ceilf(text_width), "%d倍人物页人数文字完整可读，不被姓名挤压" % scale)
			print("INVENTORY_STATUS_UI_EMPTY_STATUS scale=%d rect=%s content_height=%d" % [scale, ui.status_effects_text.get_global_rect(), ui.status_effects_text.get_content_height()])
	ui._show_inventory()


## 扩展隔离配置内存中的描述以施加长文本压力，不修改真实配置文件或玩法状态。
func _test_long_inventory(ui: Control) -> void:
	var original_description: String = ui.configuration.items.eraser.description
	var long_description: String = original_description + "\n[b]这段文字应原样显示[/b]\n" + "用于验证长物品说明在固定背包区域内换行并滚动。".repeat(30)
	ui.configuration.items.eraser.description = long_description
	var before: Dictionary = _authoritative_snapshot(ui)
	for scale in [1, 2]:
		ui._set_window_scale(scale)
		ui._show_inventory()
		await process_frame
		await process_frame
		_check(ui.inventory_text.get_parsed_text().contains(long_description), "%d倍长物品描述完整显示且不解释文本标记" % scale)
		_check(ui.inventory_text.scroll_active and not ui.inventory_text.fit_content, "%d倍长描述在固定文本区域滚动" % scale)
		var scrollbar: VScrollBar = ui.inventory_text.get_v_scroll_bar()
		_check(scrollbar.max_value > scrollbar.page, "%d倍长物品描述产生真实滚动范围" % scale)
		_check_control_bounds(ui, Rect2(ui.global_position, ui.size).grow(1.0), "%d倍长库存描述" % scale)
	_check(_authoritative_snapshot(ui) == before, "长说明布局不修改库存、资源、随机流或日志")
	ui.configuration.items.eraser.description = original_description
	ui._refresh_interface()


## 课间操真实完成产生身体舒展，计时和有效健康随真实推进刷新并按时到期。
func _test_timed_status(ui: Control) -> void:
	_reset_session(ui)
	var exercise_period: Dictionary = {}
	for period in ui.configuration.periods:
		if period.default_action_id == "morning_exercise":
			exercise_period = period
	_check(not exercise_period.is_empty(), "正式课表包含课间操时段")
	if exercise_period.is_empty():
		return
	_check(ui.simulation.set_debug_time(1, roundf(exercise_period.start_time * 86400.0)) == OK, "真实时钟进入课间操起点")
	_check(ui.simulation.advance(0.0) == OK and ui.simulation.students[0].current_action.action_id == "morning_exercise", "行为树真实发动课间操")
	var duration: float = ui.simulation.students[0].current_action.duration_s
	_check(ui.simulation.advance(duration) == OK, "课间操通过真实时间积分正常完成")
	var buff: Dictionary = _find_buff(ui, 0, "stretched")
	_check(not buff.is_empty(), "完成型效果真实施加身体舒展")
	if buff.is_empty():
		return
	ui._set_window_scale(1)
	ui._select_student(0)
	await process_frame
	await process_frame
	var description: Dictionary = ui.configuration.buffs.stretched
	var text: String = ui.status_effects_text.get_parsed_text()
	_check(text.contains(String(description.name)) and text.contains(String(description.description)), "状态名称与说明直接读取当前JSON")
	_check(text.contains("健康 +1") and text.contains("健康 1") and ui.attributes_label.text.contains("健康 0"), "健康临时修正、基础0和有效1分别展示")
	_check(text.contains("剩余 " + _timer_text(buff.expires_at - ui.simulation.elapsed_s)), "定时状态显示真实到期时间减当前模拟时间")
	_check(is_equal_approx(ui.simulation.get_resource_max(0, "stamina"), 110.0), "真实健康状态已经进入体力上限计算")
	var scrollbar: VScrollBar = ui.status_effects_text.get_v_scroll_bar()
	_check(scrollbar.max_value > scrollbar.page, "1倍人物页的完整状态内容可在固定区域滚动")
	scrollbar.value = scrollbar.max_value
	await process_frame
	var position: float = scrollbar.value
	var before: Dictionary = _authoritative_snapshot(ui)
	ui._refresh_interface()
	await process_frame
	_check(is_equal_approx(scrollbar.value, position), "未变化的状态刷新保留人物状态滚动位置")
	_check(_authoritative_snapshot(ui) == before, "查看与滚动真实状态不修改任何权威玩法数据")
	_check(ui.simulation.advance(1.0) == OK, "状态计时真实经过一秒")
	ui._refresh_interface()
	await process_frame
	await process_frame
	_check(ui.status_effects_text.get_parsed_text().contains("剩余 " + _timer_text(buff.expires_at - ui.simulation.elapsed_s)), "状态剩余时间随真实模拟推进更新")
	_check(is_equal_approx(scrollbar.value, position), "倒计时内容变化后保留人物状态滚动位置")
	var remaining: float = buff.expires_at - ui.simulation.elapsed_s
	_check(ui.simulation.advance(remaining) == OK, "真实模拟推进到状态到期边界")
	ui._refresh_interface()
	_check(_find_buff(ui, 0, "stretched").is_empty(), "状态到期由真实核心移除")
	_check(not ui.status_effects_text.get_parsed_text().contains(String(description.name)) and ui.status_effects_text.get_parsed_text().contains("暂无生效状态"), "到期刷新后不显示陈旧状态")
	_check(ui.status_effects_text.get_parsed_text().contains("健康 0") and is_equal_approx(ui.simulation.get_resource_max(0, "stamina"), 100.0), "状态到期后有效属性与资源上限恢复真实值")


## 生产施加方法构造随动作状态的展示前置，不声称本轮已开放冲刺动作。
func _test_action_status(ui: Control) -> void:
	_reset_session(ui)
	var old_instance: int = ui.simulation.students[0].current_action.instance_id
	ui.simulation._apply_buff(0, "sprinting")
	ui._select_student(0)
	var buff: Dictionary = _find_buff(ui, 0, "sprinting")
	_check(not buff.is_empty() and buff.action_instance_id == old_instance and buff.expires_at == null, "展示前置状态真实绑定现有动作实例")
	_check(ui.status_effects_text.get_parsed_text().contains(String(ui.configuration.buffs.sprinting.name)) and ui.status_effects_text.get_parsed_text().contains("随当前动作结束"), "随动作状态显示生命周期而非伪造倒计时")
	_check(ui.status_effects_text.get_parsed_text().contains("专注力 +2") and ui.status_effects_text.get_parsed_text().contains("专注力 2"), "随动作状态修正与真实有效专注力一致")
	var before: Dictionary = _authoritative_snapshot(ui)
	ui._refresh_status_effects()
	ui._show_inventory()
	ui._select_student(1)
	_check(ui.status_effects_text.get_parsed_text().contains("暂无生效状态"), "查看其他同学不沿用玩家状态")
	ui._select_student(0)
	_check(_authoritative_snapshot(ui) == before, "切换状态查看对象不会延长状态或改写业务数据")
	ui._focus_player()
	_check(not ui.fatal_error and ui.simulation.students[0].current_action.instance_id != old_instance, "真实专注指令结束原学习实例")
	_check(_find_buff(ui, 0, "sprinting").is_empty(), "所属动作结束由真实核心清理动作状态")
	_check(not ui.status_effects_text.get_parsed_text().contains(String(ui.configuration.buffs.sprinting.name)) and ui.status_effects_text.get_parsed_text().contains("专注力 0"), "动作状态结束后界面恢复真实有效属性")


## 查找真实角色状态，仅供断言读取，不生成或替换缺失状态。
func _find_buff(ui: Control, student_index: int, buff_id: String) -> Dictionary:
	for buff in ui.simulation.students[student_index].buffs:
		if buff.buff_id == buff_id:
			return buff
	return {}


## 仅筛选真实执行器已有的每日物品日志，不创建奖励或补造领取凭据。
func _daily_item_entries(ui: Control, student_index: int) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for entry in ui.simulation.logs:
		if entry.type == "daily_items" and entry.student_index == student_index:
			entries.append(entry)
	return entries


## 复制权威状态与随机流，证明只读界面没有隐式发奖或执行动作。
func _authoritative_snapshot(ui: Control) -> Dictionary:
	var simulation: ClassroomSimulation = ui.simulation
	return {
		"students": simulation.students.duplicate(true), "logs": simulation.logs.duplicate(true),
		"interactions": simulation.interactions.duplicate(true), "notes": simulation.notes.duplicate(true),
		"violations": simulation.violations.duplicate(true), "day": simulation.day,
		"clock_seconds": simulation.clock_seconds, "elapsed_s": simulation.elapsed_s,
		"rng_seed": str(simulation.rng.seed), "rng_state": str(simulation.rng.state),
		"next_action_number": simulation.next_action_number,
		"next_interaction_number": simulation.next_interaction_number,
		"next_violation_number": simulation.next_violation_number,
	}


## 根据实际剩余秒数生成可独立核对的分秒文本。
func _timer_text(seconds: float) -> String:
	var total: int = int(ceil(seconds))
	return "%02d:%02d" % [total / 60, total % 60]


## 检查固定控件边界，滚动文本内部内容与隐藏页不被误作窗口扩张。
func _check_control_bounds(node: Node, bounds: Rect2, context: String = "") -> void:
	if node is Control and node.is_visible_in_tree() and node.size.x > 0.0 and node.size.y > 0.0:
		_check(bounds.encloses(node.get_global_rect()), "%s可见控件保持在桌面边界：%s %s" % [context, node.name, node.get_global_rect()])
	for child in node.get_children():
		if not child is Window:
			_check_control_bounds(child, bounds, context)


## 每个失败保留真实原因，最终由退出码报告整组结果。
func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)


## 汇总真实发奖接线与隔离展示检查，不把无头测试计为原生桌面功能验收。
func _finish() -> void:
	if failures.is_empty():
		print("INVENTORY_STATUS_UI_TEST_PASS checks=%s real_daily_items_tested native_tray_not_tested" % checks)
		quit(0)
	else:
		for message in failures:
			push_error(message)
		print("INVENTORY_STATUS_UI_TEST_FAIL checks=%s failures=%s" % [checks, failures.size()])
		quit(1)
