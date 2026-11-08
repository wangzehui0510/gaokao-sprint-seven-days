extends SceneTree
## 在隔离工程中用生产界面和真实执行器检查玩家互动，不读写正式存档。

# 断言只统计实际执行结果，原生托盘由独立Windows测试检查。
var checks: int = 0
var failures: Array[String] = []


## 等待场景树建立后，启动隔离子进程或执行真实界面检查。
func _initialize() -> void:
	call_deferred("_run")


## 子进程双重确认专用用户目录，测试夹具不得进入正式玩家目录。
func _run() -> void:
	if "--isolated-interaction-ui" not in OS.get_cmdline_user_args():
		_launch_isolated_project()
		return
	var marker: String = str(ProjectSettings.get_setting("application/config/name"))
	if not marker.begins_with("ClassroomInteractionUiTest_") or marker not in OS.get_user_data_dir():
		push_error("互动界面测试用户目录未隔离，拒绝运行。")
		quit(1)
		return
	# 运行时脚本错误必须结束隔离子进程，不能让同步启动它的父进程永久等待。
	create_timer(45.0).timeout.connect(func():
		_check(false, "互动界面验收超时，可能发生未处理脚本错误")
		_finish()
	)
	await _test_interface()
	_finish()


## 复制真实源文件并使用独立应用名称，所有资源导入和存档仅发生在隔离工程。
func _launch_isolated_project() -> void:
	var marker: String = "ClassroomInteractionUiTest_%s_%s" % [OS.get_process_id(), Time.get_ticks_usec()]
	var isolated_root: String = OS.get_cache_dir().path_join(marker)
	for folder in ["scripts", "config", "assets", "addons", "scenes", "tests"]:
		var result: Error = _copy_directory(ProjectSettings.globalize_path("res://" + folder), isolated_root.path_join(folder))
		if result != OK:
			push_error("复制互动界面隔离工程失败：%s，错误码%s。" % [folder, result])
			quit(1)
			return
	var project := ConfigFile.new()
	if project.load("res://project.godot") != OK:
		push_error("无法读取互动界面测试所需的真实工程设置。")
		quit(1)
		return
	project.set_value("application", "config/name", marker)
	project.set_value("application", "config/use_custom_user_dir", true)
	project.set_value("application", "config/custom_user_dir_name", marker)
	if project.save(isolated_root.path_join("project.godot")) != OK:
		push_error("无法保存互动界面隔离工程设置。")
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
	exit_code = OS.execute(OS.get_executable_path(), ["--headless", "--path", isolated_root, "--script", "res://tests/test_interaction_ui.gd", "--", "--isolated-interaction-ui"], output, true)
	for line in output:
		print(line)
	print("INTERACTION_UI_TEST_PROJECT=%s" % isolated_root)
	quit(exit_code)


## 所需目录逐项复制，资源缺失或写入失败直接返回真实错误。
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


## 真实界面使用生产生命周期，只省略无头服务不支持的原生桌面初始化。
func _test_interface() -> void:
	var ui := Control.new()
	root.add_child(ui)
	ui.set_script(load("res://scripts/ui/main.gd"))
	ui.set_process(false)
	ui._build_theme()
	ui._build_interface()
	var configuration := GameConfig.new()
	_check(configuration.load_file() == OK, "界面通过正式配置完整校验")
	ui.configuration = configuration
	_reset_session(ui)
	_check(ui.inspector_tabs.get_tab_count() == 6, "榜单追加第六页，人物课表记录互动背包的前五页索引保持不变")
	_check(ui.inspector_tabs.get_tab_title(0) == "人物" and ui.inspector_tabs.get_tab_title(1) == "课表" and ui.inspector_tabs.get_tab_title(2) == "记录", "人物课表记录索引保持不变")
	ui._select_student(1)
	ui._show_interactions()
	await _test_layout(ui, 1, Vector2i(684, 320))
	await _test_layout(ui, 2, Vector2i(1068, 576))
	_test_note_recipient_and_delivery(ui)
	_test_incoming_reply(ui)
	_test_interrupted_note(ui)
	_test_eraser(ui)
	await _test_rejection(ui)
	await _test_report(ui)
	_test_report_current_partner(ui)
	_test_configuration_display(ui)
	_check(not FileAccess.file_exists("user://classroom_save.json") and not FileAccess.file_exists("user://classroom_debug_save.json"), "界面互动测试没有写入任何正式局或开发局文件")
	print("INTERACTION_UI_TEST_USER_DIR=%s" % OS.get_user_data_dir())
	ui.free()


## 每个行为场景重建真实四人局，避免前一个场景费用和时间影响后一个断言。
func _reset_session(ui: Control) -> void:
	ui._start_session(false)
	_check(not ui.fatal_error and ui.simulation != null, "互动界面成功绑定真实模拟器")
	_check(ui.simulation.set_debug_time(1, 28800.0) == OK, "互动界面使用明确的第一天早课")
	_check(ui.simulation.advance(0.0) == OK, "真实共享行为树安排四人课程动作")
	for student in ui.simulation.students:
		student.focus = 80.0
	ui._refresh_interface()


## 等待容器真实排版后，检查两种整数尺寸下互动输入、按钮和记录均在窗口内。
func _test_layout(ui: Control, scale: int, expected_size: Vector2i) -> void:
	ui._set_window_scale(scale)
	ui._show_interactions()
	await process_frame
	await process_frame
	_check(ui._get_layout_size() == expected_size and Vector2i(ui.size) == expected_size, "%d倍互动面板保持既定桌面尺寸" % scale)
	_check(ui.inspector_tabs.current_tab == 3 and ui.note_input.is_visible_in_tree(), "互动页和输入框真实可见")
	var bounds := Rect2(ui.global_position, ui.size).grow(1.0)
	_check_control_bounds(ui, bounds)
	var input_bounds: Rect2 = ui.note_input.get_global_rect()
	var history_bounds: Rect2 = ui.notes_text.get_global_rect()
	_check(input_bounds.position.y >= history_bounds.end.y, "%d倍纸条输入框没有与聊天记录重叠" % scale)
	_check(ui.note_input.max_length == 0, "输入框不擅自增加纸条字数上限")


## 隐藏页面和独立弹窗不参与主窗口边界，当前可见控件逐项验证。
func _check_control_bounds(node: Node, bounds: Rect2) -> void:
	if node is Control and node.is_visible_in_tree() and node.size.x > 0.0 and node.size.y > 0.0:
		_check(bounds.encloses(node.get_global_rect()), "互动可见控件保持在桌面边界：%s %s" % [node.name, node.get_global_rect()])
	for child in node.get_children():
		if not child is Window:
			_check_control_bounds(child, bounds)


## 草稿锁定已选收件人；发送按钮只控制玩家，真实完成之前不会显示送达。
func _test_note_recipient_and_delivery(ui: Control) -> void:
	_reset_session(ui)
	ui._select_student(1)
	ui._show_interactions()
	ui.note_input.text = "保留原收件人 [b]文字[/b]"
	ui._on_note_text_changed(ui.note_input.text)
	ui._select_student(2)
	ui._show_interactions()
	_check(ui.interaction_target_index == 1 and ui.interaction_target_picker.get_selected_id() == 1, "切换查看对象不会转移已有草稿")
	var untouched: Dictionary = ui.simulation.students[2].current_action.duplicate(true)
	ui.send_note_button.pressed.emit()
	_check(not ui.fatal_error and ui.note_input.text.is_empty(), "纸条真实发动成功后才清空输入")
	_check(ui.simulation.students[0].current_action.action_id == "send_note" and ui.simulation.students[1].current_action.action_id == "send_note", "按钮发起者固定为玩家且目标仍为原收件人")
	_check(ui.simulation.students[2].current_action == untouched, "查看对象不是收件人时不被指令控制")
	_check(ui.simulation.notes.is_empty() and not ui.notes_text.text.contains("保留原收件人"), "发动时不把纸条草稿显示为已送达")
	_check(is_equal_approx(ui.simulation.students[0].focus, 78.0) and is_equal_approx(ui.simulation.students[1].focus, 80.0), "UI纸条只向真实发起者扣当前启动费")
	_check(ui.interaction_summary.text.contains(String(ui.simulation.students[1].name)) and ui.interaction_summary.text.contains("→"), "互动页显示真实双方搭档和方向")
	_check(ui.simulation.advance(20.0) == OK, "通过真实模拟时钟完成纸条")
	ui._refresh_interface()
	_check(ui.simulation.notes.size() == 1 and ui.notes_text.get_parsed_text().contains("保留原收件人 [b]文字[/b]"), "真实完成后出现原样文字且不解释聊天标记")
	ui._select_student(3)
	ui._show_interactions()
	_check(ui.interaction_target_index == 3, "没有草稿时互动入口沿用正在查看的同学")
	_check(not ui.notes_text.text.contains("保留原收件人"), "切换聊天对象不混入其他同学的纸条")


## 同学已送达的文字出现在对应会话，回复仍由玩家走相同纸条入口。
func _test_incoming_reply(ui: Control) -> void:
	_reset_session(ui)
	_check(ui.simulation.start_interaction(1, 0, "send_note", "这道题你会吗？") == OK, "真实同学向玩家传入纸条")
	_check(ui.simulation.advance(20.0) == OK, "传入纸条真实完成")
	ui._select_student(1)
	ui._show_interactions()
	_check(ui.notes_text.text.contains("→ 我：这道题你会吗？"), "聊天记录显示真实来信方向和文字")
	ui.note_input.text = "我们下课讨论。"
	ui.note_input.text_submitted.emit(ui.note_input.text)
	_check(ui.simulation.students[0].current_action.action_id == "send_note", "回车回复通过玩家的真实持续动作发动")
	_check(ui.simulation.advance(20.0) == OK, "真实回复完成")
	ui._refresh_interface()
	_check(ui.notes_text.text.contains("这道题你会吗？") and ui.notes_text.text.contains("我们下课讨论。") and ui.simulation.notes.size() == 2, "会话同时保留真实来信和已送达回复")


## 玩家离开互动会真实取消未完成纸条，界面不能保留假送达消息。
func _test_interrupted_note(ui: Control) -> void:
	_reset_session(ui)
	ui.note_input.text = "被专注打断的纸条"
	ui._send_note()
	_check(ui.simulation.advance(5.0) == OK, "纸条实际进行五秒")
	ui._focus_player()
	_check(ui.simulation.advance(20.0) == OK, "越过原纸条结束时刻")
	ui._refresh_interface()
	_check(ui.simulation.notes.is_empty() and not ui.notes_text.text.contains("被专注打断"), "被打断纸条既不写入聊天也不延迟送达")
	_check(ui.simulation.students[0].current_action.action_id == "study" and ui.simulation.students[1].current_action.action_id == "study", "界面专注打断后双方恢复真实课表状态")


## 基础橡皮不要求物品；按钮完成效果与真实配置一致，目标不是正在查看的别人。
func _test_eraser(ui: Control) -> void:
	_reset_session(ui)
	ui._on_interaction_target_selected(0)
	ui.eraser_button.pressed.emit()
	_check(not ui.fatal_error and ui.simulation.students[0].current_action.action_id == "eraser_prank", "基础橡皮按钮发动真实双人动作")
	_check(is_equal_approx(ui.simulation.students[0].focus, 76.0) and is_equal_approx(ui.simulation.students[1].focus, 80.0), "橡皮发动扣四点且不提前发放完成型效果")
	_check(ui.simulation.advance(30.0) == OK, "真实橡皮动作完成")
	ui._refresh_interface()
	_check(is_equal_approx(ui.simulation.students[0].focus, 77.0) and is_equal_approx(ui.simulation.students[1].focus, 73.0), "橡皮完成后真实加二减六并仅各收一次自然学习费用")


## 禁用原因采用核心前置检查；绕过按钮的失败请求仍可见并保留草稿和旧动作。
func _test_rejection(ui: Control) -> void:
	_reset_session(ui)
	_check(ui.send_note_button.disabled and ui.send_note_button.tooltip_text.contains("请输入纸条内容"), "空白纸条明确提示填写内容")
	ui.note_input.text = "资源不足时保留"
	ui.simulation.students[0].focus = 1.0
	ui._refresh_interface()
	var reason: String = ui.simulation.interaction_unavailable_reason(0, 1, "send_note")
	_check(not reason.is_empty() and ui.send_note_button.disabled and ui.send_note_button.tooltip_text.contains(reason), "资源不足的禁用原因直接显示核心查询结果")
	var old_action: Dictionary = ui.simulation.students[0].current_action.duplicate(true)
	ui._send_note()
	await process_frame
	_check(not ui.fatal_error and ui.simulation.students[0].current_action == old_action, "普通指令拒绝保持健康模拟器和原动作")
	_check(ui.note_input.text == "资源不足时保留" and ui.error_dialog.dialog_text.contains(reason), "真实失败可见且不丢失未发草稿")
	ui.error_dialog.hide()


## 第三人举报采用真实违纪编号；重复旧事件只显示失败，不重复奖惩或停止游戏。
func _test_report(ui: Control) -> void:
	_reset_session(ui)
	_check(ui.simulation.start_action(1, "daydream") == OK, "目标真实开小差形成违纪")
	ui._refresh_interface()
	var violation: Dictionary = ui.current_report_violation.duplicate(true)
	_check(not violation.is_empty() and not ui.report_button.disabled, "界面发现真实事件后启用举报")
	if violation.is_empty():
		return
	var before_action: Dictionary = ui.simulation.students[0].current_action.duplicate(true)
	var own_focus: float = ui.simulation.students[0].focus
	var target_focus: float = ui.simulation.students[1].focus
	ui.report_button.pressed.emit()
	_check(not ui.fatal_error and ui.simulation.students[0].current_action == before_action, "举报按钮保持玩家真实持续动作")
	_check(is_equal_approx(ui.simulation.students[0].focus, own_focus + 3.0) and is_equal_approx(ui.simulation.students[1].focus, target_focus - 5.0), "举报通过核心立即真实结算且不加自然启动费")
	_check(ui.report_button.disabled and ui.current_report_violation.is_empty() and ui.simulation.students[1].current_action.action_id == "study", "已处理事件关闭并刷新为不可重复举报")
	own_focus = ui.simulation.students[0].focus
	target_focus = ui.simulation.students[1].focus
	ui.current_report_violation = violation
	ui._report_selected_violation()
	await process_frame
	_check(not ui.fatal_error and not ui.error_dialog.dialog_text.is_empty(), "陈旧举报请求明确可见但不停止模拟器")
	_check(is_equal_approx(ui.simulation.students[0].focus, own_focus) and is_equal_approx(ui.simulation.students[1].focus, target_focus), "重复同一事件不会产生第二次界面奖惩")
	ui.error_dialog.hide()


## 同组举报遵循已确认例外：双方旧互动结束，举报者自然回课表且未完成纸条取消。
func _test_report_current_partner(ui: Control) -> void:
	_reset_session(ui)
	ui.note_input.text = "举报当前搭档前尚未送达"
	ui._send_note()
	_check(ui.simulation.advance(5.0) == OK, "同组举报前纸条真实执行五秒")
	ui._refresh_interface()
	_check(not ui.report_button.disabled and ui.report_button.tooltip_text.contains("结束双方旧互动") and ui.interaction_reason_label.text.contains("结束互动"), "点击前明确显示举报当前搭档的中断后果")
	var old_instance: int = ui.simulation.students[0].current_action.instance_id
	ui.report_button.pressed.emit()
	_check(not ui.fatal_error and ui.simulation.students[0].current_action.instance_id != old_instance, "举报当前搭档结束举报者原互动")
	_check(ui.simulation.students[0].current_action.action_id == "study" and ui.simulation.students[1].current_action.action_id == "study", "同组举报后双方分别按确认的课表路径进入学习")
	_check(ui.simulation.interactions[-1].status == "interrupted", "同组举报把旧互动明确记录为中断")
	_check(ui.simulation.advance(20.0) == OK, "同组举报后跨过原纸条完成时刻")
	ui._refresh_interface()
	_check(ui.simulation.notes.is_empty() and not ui.notes_text.text.contains("尚未送达"), "同组举报取消未完成纸条的真实送达")


## 修改内存中的正式配置副本，验证费用和时长显示没有硬编码策划摘要。
func _test_configuration_display(ui: Control) -> void:
	_reset_session(ui)
	_check(ui.interaction_cost_label.text.contains("20秒") and ui.interaction_cost_label.text.contains("专注-2") and ui.interaction_cost_label.text.contains("30秒") and ui.interaction_cost_label.text.contains("专注-4"), "当前费用和持续时间来自正式JSON")
	_check(ui.send_note_button.tooltip_text.contains("+2%各自当前上限") and ui.send_note_button.tooltip_text.contains("60秒"), "纸条说明显示双方各自当前上限与真实周期")
	_check(ui.eraser_button.tooltip_text.contains("对方专注-6") and ui.eraser_button.tooltip_text.contains("我专注+2"), "橡皮说明显示真实完成型资源变化")
	var replacement := GameConfig.new()
	_check(replacement.load_file() == OK, "界面调表检查加载独立正式配置副本")
	replacement.actions.send_note.duration_min_s = 47.0
	replacement.actions.send_note.duration_max_s = 47.0
	replacement.phase_effects("send_note", "start")[0].value = -7.0
	ui.configuration = replacement
	ui._refresh_interaction_interface()
	_check(ui.interaction_cost_label.text.contains("47秒") and ui.interaction_cost_label.text.contains("专注-7"), "费用和时长随配置副本变化而更新")


## 每个失败记录实际断言，最终退出码反映整个隔离检查结果。
func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)


## 输出可复核的真实结果，不将无头布局检查当作原生桌面验收。
func _finish() -> void:
	if failures.is_empty():
		print("INTERACTION_UI_TEST_PASS checks=%s" % checks)
		quit(0)
	else:
		for message in failures:
			push_error(message)
		print("INTERACTION_UI_TEST_FAIL checks=%s failures=%s" % [checks, failures.size()])
		quit(1)
