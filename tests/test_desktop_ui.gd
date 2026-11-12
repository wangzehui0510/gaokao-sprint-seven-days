extends SceneTree
## 在独立工程和用户目录中检查真实桌面界面的布局与命令接线。

# 仅统计实际断言，正式存档和原生托盘不参与无头布局测试。
var checks: int = 0
var failures: Array[String] = []


## 等待场景树可用，再进入隔离子进程或建立隔离环境。
func _initialize() -> void:
	call_deferred("_run")


## 子进程先确认独立用户目录，再允许真实界面和执行器运行。
func _run() -> void:
	if "--isolated-desktop-ui" not in OS.get_cmdline_user_args():
		_launch_isolated_project()
		return
	var marker: String = str(ProjectSettings.get_setting("application/config/name"))
	if not marker.begins_with("ClassroomDesktopUiTest_") or marker not in OS.get_user_data_dir():
		push_error("桌面界面测试用户目录未隔离，拒绝运行")
		quit(1)
		return
	await _test_desktop_interface()
	_finish()


## 复制真实源文件并设置独立应用名称，不修改正式工程设置或用户文件。
func _launch_isolated_project() -> void:
	var marker: String = "ClassroomDesktopUiTest_%s_%s" % [OS.get_process_id(), Time.get_ticks_usec()]
	var isolated_root: String = OS.get_cache_dir().path_join(marker)
	var result: Error = DirAccess.make_dir_recursive_absolute(isolated_root)
	if result != OK:
		push_error("无法创建桌面测试隔离目录：%s" % result)
		quit(1)
		return
	for folder in ["scripts", "config", "assets", "addons", "scenes", "tests"]:
		result = _copy_directory(ProjectSettings.globalize_path("res://" + folder), isolated_root.path_join(folder))
		if result != OK:
			push_error("复制桌面测试目录失败：%s，错误码%s" % [folder, result])
			quit(1)
			return
	var project := ConfigFile.new()
	result = project.load("res://project.godot")
	if result != OK:
		push_error("读取真实工程设置失败：%s" % result)
		quit(1)
		return
	project.set_value("application", "config/name", marker)
	project.set_value("application", "config/use_custom_user_dir", true)
	project.set_value("application", "config/custom_user_dir_name", marker)
	result = project.save(isolated_root.path_join("project.godot"))
	if result != OK:
		push_error("保存隔离工程设置失败：%s" % result)
		quit(1)
		return
	var output: Array = []
	var exit_code: int = OS.execute(OS.get_executable_path(), ["--headless", "--path", isolated_root, "--editor", "--import"], output, true)
	if exit_code != 0:
		for line in output:
			print(line)
		push_error("桌面测试隔离导入失败：%s" % exit_code)
		quit(exit_code)
		return
	output.clear()
	exit_code = OS.execute(OS.get_executable_path(), ["--headless", "--path", isolated_root, "--script", "res://tests/test_desktop_ui.gd", "--", "--isolated-desktop-ui"], output, true)
	for line in output:
		print(line)
	print("DESKTOP_UI_TEST_PROJECT=%s" % isolated_root)
	quit(exit_code)


## 准备隔离工程时逐项复制；资源缺失或写入失败直接返回真实错误。
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


## 挂载生产界面脚本并手动安排生命周期，不以窗口或执行器替身替代真实逻辑。
func _test_desktop_interface() -> void:
	var main_script: Script = load("res://scripts/ui/main.gd")
	var ui := Control.new()
	root.add_child(ui)
	# 先完成基类ready再挂脚本，只省略不受无头显示服务支持的原生窗口初始化。
	ui.set_script(main_script)
	ui.set_process(false)
	# 桌面改造尚未接入时在统一入口明确失败，不让缺失方法变成中途脚本错误或假通过。
	var missing_methods: Array[String] = []
	for method in ["_get_layout_size", "_set_window_scale", "_set_panel_visible", "_show_timetable"]:
		if not ui.has_method(method):
			missing_methods.append(method)
	if not missing_methods.is_empty():
		_check(false, "桌面主界面尚未接入，缺少方法：" + ", ".join(missing_methods))
		ui.free()
		return
	ui._build_theme()
	ui._build_interface()
	var game_config := GameConfig.new()
	_check(game_config.load_file() == OK, "正式配置通过完整入口校验")
	# 事件是独立内容：桌面基线组显式关闭，保持既有数值契约。
	game_config.globals["events_enabled"] = false
	ui.configuration = game_config
	ui._start_session(false)
	_check(not ui.fatal_error and ui.simulation != null, "桌面界面绑定真实模拟器")
	_check(ui.behavior.trees.size() == 4, "桌面界面仍绑定四棵共享蓝图实例")
	_check(ui.simulation.set_debug_time(1, 28800.0) == OK, "真实开发时钟进入第一天早课")
	_check(ui.simulation.advance(0.0) == OK, "四人根据实际课表重新选择课程动作")
	ui._refresh_interface()
	_check(not ui.inspector_panel.visible, "初始迷你教室不常驻详细侧栏")
	await _test_layout(ui, 1, false, Vector2i(384, 320))
	await _test_layout(ui, 1, true, Vector2i(684, 320))
	await _test_layout(ui, 2, false, Vector2i(768, 576))
	await _test_layout(ui, 2, true, Vector2i(1068, 576))
	_test_player_commands(ui)
	_test_timetable(ui)
	ui._set_panel_visible(false)
	_check(not ui.inspector_panel.visible, "详情关闭后恢复只有教室的常驻形态")
	_check(not FileAccess.file_exists("user://classroom_save.json"), "布局和命令检查不会写入正式局文件")
	print("DESKTOP_UI_TEST_USER_DIR=%s" % OS.get_user_data_dir())
	ui.free()


## 等待真实容器完成排版，再验证每种缩放和展开状态的内容边界。
func _test_layout(ui: Control, scale: int, panel_visible: bool, expected_size: Vector2i) -> void:
	ui._set_window_scale(scale)
	ui._set_panel_visible(panel_visible)
	var layout_size: Vector2i = ui._get_layout_size()
	_check(layout_size == expected_size, "%d倍、详情%s的目标尺寸正确" % [scale, panel_visible])
	ui.size = Vector2(layout_size)
	await process_frame
	await process_frame
	_check(ui.room.size == Vector2(384, 256) * scale, "%d倍场景使用整数倍原生尺寸" % scale)
	_check(ui.inspector_panel.visible == panel_visible, "详情可见性与布局状态一致")
	var bounds := Rect2(ui.global_position, ui.size).grow(1.0)
	_check_control_bounds(ui, bounds)


## 只检查当前真正显示的控件，弹窗和隐藏选项卡由各自窗口负责边界。
func _check_control_bounds(node: Node, bounds: Rect2) -> void:
	if node is Control and node.is_visible_in_tree() and node.size.x > 0.0 and node.size.y > 0.0:
		var rectangle: Rect2 = node.get_global_rect()
		_check(bounds.encloses(rectangle), "可见控件未超出桌面内容边界：%s %s" % [node.name, rectangle])
	for child in node.get_children():
		if not child is Window:
			_check_control_bounds(child, bounds)


## 查看同学后仍通过生产命令只控制自己，并验证重复专注与免费休息。
func _test_player_commands(ui: Control) -> void:
	ui._select_student(1)
	_check(ui.selected_index == 1 and ui.room.selected_index == 1, "选择同学仅改变查看对象")
	_check(ui.inspector_panel.visible and ui.inspector_tabs.current_tab == 0, "选择同学打开人物详情")
	var simulation: ClassroomSimulation = ui.simulation
	simulation.students[0].focus = 40.0
	var other_focus: float = simulation.students[1].focus
	var other_action: int = simulation.students[1].current_action.instance_id
	var first_action: int = simulation.students[0].current_action.instance_id
	ui._focus_player()
	_check(not ui.fatal_error, "查看同学时专注按钮仍能对自己生效")
	_check(is_equal_approx(simulation.students[0].focus, 45.0), "第一次专注按当前正式配表增加5点")
	var second_action: int = simulation.students[0].current_action.instance_id
	ui._focus_player()
	_check(is_equal_approx(simulation.students[0].focus, 50.0), "学习中再次点击仍立即增加专注")
	_check(first_action != second_action and second_action != simulation.students[0].current_action.instance_id, "每次专注都重新建立自己的学习段")
	_check(is_equal_approx(simulation.students[1].focus, other_focus) and simulation.students[1].current_action.instance_id == other_action, "查看对象的资源与动作没有被自己按钮改变")
	_check(ui.selected_index == 1, "主动命令不会擅自切换查看对象")
	simulation.students[0].focus = 0.0
	simulation.students[0].stamina = 1.0
	ui._manual_action("rest")
	_check(not ui.fatal_error and simulation.students[0].current_action.action_id == "rest", "零专注时仍可从界面发动自己的基础休息")
	_check(is_zero_approx(simulation.students[0].focus) and is_equal_approx(simulation.students[0].stamina, 1.0), "基础休息启动不收费或提前赠送持续收益")
	_check(simulation.students[1].current_action.instance_id == other_action, "休息按钮不改变正在查看的同学")


## 黑板入口必须显示真实当天课表，不能以固定模板代替配置。
func _test_timetable(ui: Control) -> void:
	ui.room.blackboard_selected.emit()
	_check(ui.inspector_panel.visible and ui.inspector_tabs.current_tab == 1, "点击黑板信号打开课表选项卡")
	var timetable: String = ui.timetable_text.get_parsed_text()
	for period in ui.configuration.periods:
		_check(timetable.contains(String(period.name)), "课表包含正式时段：%s" % period.name)
		var seconds: int = int(round(float(period.start_time) * 86400.0))
		var start_text: String = "%02d:%02d" % [seconds / 3600, (seconds % 3600) / 60]
		_check(timetable.contains(start_text), "课表起始时间来自正式时段：%s" % start_text)
	for row in ui.configuration.tables.schedule:
		if int(row.day) == ui.simulation.day:
			var subject: String = String(ui.configuration.subjects[row.subject_id].name)
			_check(timetable.contains(subject), "课表科目来自当前天数配置：%s" % subject)


## 每个失败都记录实际断言原因，最终由进程退出码反映检查结果。
func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)


## 汇总真实界面检查，不把原生托盘或系统窗口验收计为无头测试通过。
func _finish() -> void:
	if failures.is_empty():
		print("DESKTOP_UI_TEST_PASS checks=%s native_tray_not_tested" % checks)
		quit(0)
	else:
		for message in failures:
			push_error(message)
		print("DESKTOP_UI_TEST_FAIL checks=%s failures=%s" % [checks, failures.size()])
		quit(1)
