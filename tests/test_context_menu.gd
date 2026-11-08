extends SceneTree
## 在独立工程中检查真实右键互动面板、收件人草稿和过期举报，不接触正式进度。

# 每个断言都来自生产界面和真实执行器；原生鼠标、托盘由Windows回归另行验收。
var checks: int = 0
var failures: Array[String] = []


## 等待场景树建立，再准备隔离工程或执行真实交互。
func _initialize() -> void:
	call_deferred("_run")


## 双重核验独立应用名与用户目录，失败夹具只允许写入本次隔离环境。
func _run() -> void:
	if "--isolated-context-menu" not in OS.get_cmdline_user_args():
		_launch_isolated_project()
		return
	var marker: String = str(ProjectSettings.get_setting("application/config/name"))
	if not marker.begins_with("ClassroomContextMenuTest_") or marker not in OS.get_user_data_dir():
		push_error("右键面板测试用户目录未隔离，拒绝运行。")
		quit(1)
		return
	# 运行时脚本错误也必须结束子进程，避免同步启动它的父进程永久等待。
	create_timer(45.0).timeout.connect(func():
		_check(false, "右键面板验收超时，可能发生未处理脚本错误")
		_finish()
	)
	await _test_interface()
	_finish()


## 复制真实资源并设置专用应用名称，不修改正式工程配置或用户目录。
func _launch_isolated_project() -> void:
	var marker: String = "ClassroomContextMenuTest_%s_%s" % [OS.get_process_id(), Time.get_ticks_usec()]
	var isolated_root: String = OS.get_cache_dir().path_join(marker)
	for folder in ["scripts", "config", "assets", "addons", "scenes", "tests"]:
		var result: Error = _copy_directory(ProjectSettings.globalize_path("res://" + folder), isolated_root.path_join(folder))
		if result != OK:
			push_error("复制右键面板隔离工程失败：%s，错误码%s。" % [folder, result])
			quit(1)
			return
	var project := ConfigFile.new()
	if project.load("res://project.godot") != OK:
		push_error("无法读取右键面板测试所需的真实工程设置。")
		quit(1)
		return
	project.set_value("application", "config/name", marker)
	project.set_value("application", "config/use_custom_user_dir", true)
	project.set_value("application", "config/custom_user_dir_name", marker)
	if project.save(isolated_root.path_join("project.godot")) != OK:
		push_error("无法保存右键面板隔离工程设置。")
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
	exit_code = OS.execute(OS.get_executable_path(), ["--headless", "--path", isolated_root, "--script", "res://tests/test_context_menu.gd", "--", "--isolated-context-menu"], output, true)
	for line in output:
		print(line)
	print("CONTEXT_MENU_TEST_PROJECT=%s" % isolated_root)
	quit(exit_code)


## 必要资源逐项复制，任何缺失或写入失败都返回真实错误。
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


## 使用生产脚本与生命周期，只省略无头服务不支持的原生窗口初始化。
func _test_interface() -> void:
	var ui := Control.new()
	root.add_child(ui)
	ui.set_script(load("res://scripts/ui/main.gd"))
	ui.set_process(false)
	# 脚本在基类ready后挂载，显式补上生产ready前会自动启用的输入分发。
	ui.set_process_input(true)
	_check(ui.is_processing_input(), "测试恢复真实主界面的输入分发生命周期")
	for method in ["_show_student_context", "_close_student_context", "_refresh_student_context", "_on_context_note_pressed", "_on_context_eraser_pressed", "_on_context_report_pressed", "_on_context_overlay_input", "_set_interaction_target", "_input"]:
		if not ui.has_method(method):
			_check(false, "右键互动尚未接入真实主界面：" + method)
			ui.free()
			return
	ui._build_theme()
	ui._build_interface()
	var configuration := GameConfig.new()
	_check(configuration.load_file() == OK, "右键测试通过正式配置完整校验")
	ui.configuration = configuration
	_reset_session(ui)
	_test_open_and_cancel(ui)
	await _test_viewport_mouse_chain(ui)
	await _test_background_enter(ui)
	_test_forward_right_click(ui)
	await _test_note_drafts(ui)
	_test_eraser_target(ui)
	await _test_unavailable_action(ui)
	_test_report_target(ui)
	await _test_expired_report(ui)
	_test_partner_report(ui)
	for scale in [1, 2]:
		for panel_visible in [false, true]:
			await _test_layout(ui, scale, panel_visible)
	_test_lifecycle_closure(ui)
	_check(not FileAccess.file_exists("user://classroom_save.json") and not FileAccess.file_exists("user://classroom_debug_save.json"), "右键测试未创建正式局或开发局存档")
	_test_fatal_closure(ui)
	print("CONTEXT_MENU_TEST_USER_DIR=%s" % OS.get_user_data_dir())
	ui.free()


## 每个动作场景重新建立四人真实局，资源和动作都通过正式规则运行。
func _reset_session(ui: Control) -> void:
	ui._start_session(false)
	_check(not ui.fatal_error and ui.simulation != null, "右键界面绑定真实模拟器")
	_check(ui.simulation.set_debug_time(1, 28800.0) == OK, "右键测试进入第一天早课")
	_check(ui.simulation.advance(0.0) == OK, "共享行为树安排四人真实课程动作")
	for student in ui.simulation.students:
		student.focus = 80.0
	ui._refresh_interface()


## 开菜单和取消只影响呈现，不能移动草稿、打开侧栏、改变查看对象或结算动作。
func _test_open_and_cancel(ui: Control) -> void:
	_reset_session(ui)
	ui._set_interaction_target(1)
	ui.note_input.text = "留给小林的原草稿"
	ui._select_student(3)
	ui._set_panel_visible(false)
	var before: Dictionary = _snapshot(ui.simulation)
	var tab_before: int = ui.inspector_tabs.current_tab
	_right_click_student(ui, 2)
	_check(ui.context_overlay.visible and ui.context_target_index == 2, "真实教室右键信号打开对应同学的面板")
	_check(ui.context_title.text.contains(String(ui.simulation.students[2].name)), "小面板明确显示右键对象姓名")
	_check(ui.selected_index == 3 and not ui.inspector_panel.visible and ui.inspector_tabs.current_tab == tab_before, "仅右键不改变查看对象或详情展开状态")
	_check(ui.interaction_target_index == 1 and ui.note_input.text == "留给小林的原草稿", "只打开菜单不转移或覆盖原收件人草稿")
	_check(_snapshot(ui.simulation) == before, "打开菜单不收费、不抽随机数、不改动作或日志")
	ui._close_student_context()
	_check(not ui.context_overlay.visible and _snapshot(ui.simulation) == before, "取消菜单不改变任何玩法状态")
	ui.room._gui_input(_mouse_button(MOUSE_BUTTON_RIGHT, _student_point(ui, 0)))
	_check(not ui.context_overlay.visible, "右键自己不弹同学互动面板")
	ui.room._gui_input(_mouse_button(MOUSE_BUTTON_RIGHT, Vector2(12, 12)))
	_check(not ui.context_overlay.visible, "右键教室空地不伪造互动目标")
	_right_click_student(ui, 1)
	ui._on_context_overlay_input(_mouse_button(MOUSE_BUTTON_LEFT, Vector2.ZERO))
	_check(not ui.context_overlay.visible and ui.note_input.text == "留给小林的原草稿", "外侧点击关闭小面板且保留草稿")
	_right_click_student(ui, 1)
	_push_key(ui, KEY_ESCAPE)
	_check(not ui.context_overlay.visible and _snapshot(ui.simulation) == before, "真实视口Esc输入关闭菜单且不发出游戏指令")
	ui.room._gui_input(_mouse_button(MOUSE_BUTTON_LEFT, _student_point(ui, 1)))
	_check(ui.selected_index == 1 and ui.inspector_panel.visible and ui.inspector_tabs.current_tab == 0, "原左键查看同学入口继续可用")


## 等真实布局后从视口派发鼠标，验证遮罩覆盖主窗口且外侧点击不会穿透到教室。
func _test_viewport_mouse_chain(ui: Control) -> void:
	_reset_session(ui)
	ui._set_window_scale(1)
	ui._set_interaction_target(1)
	ui.note_input.text = "真实鼠标取消后保留的草稿"
	ui._select_student(3)
	ui._set_panel_visible(false)
	await process_frame
	await process_frame
	var before: Dictionary = _snapshot(ui.simulation)
	var recipient_before: int = ui.interaction_target_index
	var open_point: Vector2 = ui.room.get_global_transform() * _student_point(ui, 2)
	_push_mouse(ui, MOUSE_BUTTON_RIGHT, open_point)
	await process_frame
	await process_frame
	_check(ui.context_overlay.is_visible_in_tree() and ui.context_target_index == 2, "真实视口右键角色身体打开对应小面板")
	_check(ui.context_overlay.get_global_rect().is_equal_approx(ui.get_global_rect()), "透明遮罩实际覆盖完整主窗口")
	_check(ui.selected_index == 3 and not ui.inspector_panel.visible and ui.interaction_target_index == recipient_before and ui.note_input.text == "真实鼠标取消后保留的草稿" and _snapshot(ui.simulation) == before, "真实右键入口不改变查看对象、草稿、资源或动作")
	# 选择面板外另一角色身体，若点击穿透，原左键入口会改变选中对象或展开详情。
	var outside_index: int = -1
	var outside_point := Vector2.ZERO
	for candidate in [0, 1, 2]:
		var candidate_point: Vector2 = ui.room.get_global_transform() * _student_point(ui, candidate)
		if not ui.context_panel.get_global_rect().has_point(candidate_point):
			outside_index = candidate
			outside_point = candidate_point
			break
	_check(outside_index >= 0, "真实取消点击位于菜单外的另一角色身体")
	if outside_index < 0:
		ui._close_student_context()
		return
	_push_mouse(ui, MOUSE_BUTTON_LEFT, outside_point)
	await process_frame
	_check(not ui.context_overlay.visible, "真实视口外侧左键关闭小面板")
	_check(ui.selected_index == 3 and not ui.inspector_panel.visible, "遮罩消费外侧点击，不穿透选择背后角色")
	_check(ui.interaction_target_index == recipient_before and ui.note_input.text == "真实鼠标取消后保留的草稿" and _snapshot(ui.simulation) == before, "真实外侧取消保留收件人草稿与全部游戏状态")


## 遮罩接管真实键盘焦点，回车不能越过小面板发送另一位同学的后台草稿。
func _test_background_enter(ui: Control) -> void:
	_reset_session(ui)
	ui._set_interaction_target(1)
	ui.inspector_tabs.current_tab = 3
	ui._set_panel_visible(true)
	ui.note_input.text = "回车不能越过右键面板发送给小林"
	ui.note_input.grab_focus()
	await process_frame
	_check(ui.note_input.has_focus(), "右键前旧收件人的输入框真实持有焦点")
	var before: Dictionary = _snapshot(ui.simulation)
	_right_click_student(ui, 2)
	for shifted in [false, true]:
		for _step in 12:
			_push_key(ui, KEY_TAB, shifted)
			await process_frame
			var owner: Control = ui.get_viewport().gui_get_focus_owner()
			_check(owner != null and ui.context_panel.is_ancestor_of(owner) and owner is BaseButton and not owner.disabled, "多次%sTab焦点仅在小面板已启用按钮中循环" % ("Shift+" if shifted else ""))
	_check(ui.context_note_button.has_focus(), "正向再反向Tab循环回到原菜单按钮，不进入后台输入框")
	for direction in [KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT]:
		for _step in 4:
			_push_key(ui, direction)
			await process_frame
			var owner: Control = ui.get_viewport().gui_get_focus_owner()
			_check(owner != null and ui.context_panel.is_ancestor_of(owner) and owner is BaseButton and not owner.disabled, "多次方向键%s焦点留在小面板已启用按钮中" % direction)
	ui.context_note_button.grab_focus()
	_check(ui.context_note_button.has_focus(), "方向键验证后显式聚焦当前对象的纸条按钮")
	_push_key(ui, KEY_ENTER)
	await process_frame
	_check(_snapshot(ui.simulation) == before, "真实回车事件不会发送遮罩背后的旧草稿或扣除资源")
	_check(not ui.context_overlay.visible and ui.inspector_tabs.current_tab == 3 and ui.interaction_target_index == 2, "真实回车只打开当前菜单对象的纸条编辑入口")
	ui._close_student_context()
	ui._set_interaction_target(1)
	_check(ui.note_input.text == "回车不能越过右键面板发送给小林", "菜单键盘操作后原收件人草稿仍可完整恢复")


## 遮罩上的下一次右键继续请求真实座位，不能被旧菜单吞掉或改成玩家指令。
func _test_forward_right_click(ui: Control) -> void:
	_reset_session(ui)
	ui._set_window_scale(1)
	ui._set_panel_visible(false)
	_right_click_student(ui, 1)
	var point_in_ui: Vector2 = ui.room.global_position + _student_point(ui, 2)
	_check(not ui.context_panel.get_global_rect().has_point(point_in_ui), "下一位同学位于旧小面板之外")
	var before: Dictionary = _snapshot(ui.simulation)
	var overlay_position: Vector2 = point_in_ui - ui.context_overlay.global_position
	ui._on_context_overlay_input(_mouse_button(MOUSE_BUTTON_RIGHT, overlay_position))
	_check(ui.context_overlay.visible and ui.context_target_index == 2 and ui.context_title.text.contains(String(ui.simulation.students[2].name)), "遮罩外侧右键能直接切换到另一位真实同学")
	_check(_snapshot(ui.simulation) == before, "连续打开不同同学菜单仍不启动任何互动")
	ui._close_student_context()


## 点发纸条只切换会话与输入焦点，旧草稿按收件人保留，成功只清当前草稿。
func _test_note_drafts(ui: Control) -> void:
	_reset_session(ui)
	ui._set_interaction_target(1)
	ui.note_input.text = "给小林：保持原样 [b]草稿[/b]"
	var before: Dictionary = _snapshot(ui.simulation)
	_right_click_student(ui, 2)
	ui.context_note_button.pressed.emit()
	await process_frame
	_check(not ui.context_overlay.visible and ui.inspector_panel.visible and ui.inspector_tabs.current_tab == 3, "点纸条先关闭小菜单再打开真实互动页")
	_check(ui.interaction_target_index == 2 and ui.interaction_target_picker.get_selected_id() == 2 and ui.note_input.text.is_empty(), "新收件人从自己的空草稿开始，不继承别人的文字")
	_check(ui.note_input.has_focus(), "纸条入口聚焦真实输入框")
	_check(_snapshot(ui.simulation) == before, "只打开写纸条入口不扣费用、不建立动作或伪造送达")
	ui.note_input.text = "给小陈：下课一起讨论。"
	ui.interaction_target_picker.select(0)
	ui.interaction_target_picker.item_selected.emit(0)
	_check(ui.interaction_target_index == 1 and ui.note_input.text == "给小林：保持原样 [b]草稿[/b]", "显式下拉切回旧同学能无损恢复原草稿")
	ui._set_interaction_target(2)
	_check(ui.note_input.text == "给小陈：下课一起讨论。", "再次切换恢复第二位同学的独立草稿")
	var untouched_action: Dictionary = ui.simulation.students[1].current_action.duplicate(true)
	ui.send_note_button.pressed.emit()
	_check(not ui.fatal_error and ui.note_input.text.is_empty(), "真实发送成功只清当前收件人输入")
	_check(ui.simulation.students[0].current_action.action_id == "send_note" and ui.simulation.students[2].current_action.action_id == "send_note", "纸条仍由玩家向右键选定的同学真实发起")
	_check(ui.simulation.students[1].current_action == untouched_action, "旧草稿的同学不被新收件人的纸条控制")
	ui._set_interaction_target(1)
	_check(ui.note_input.text == "给小林：保持原样 [b]草稿[/b]", "发送另一人的纸条不会清除原收件人的草稿")
	ui._set_interaction_target(2)
	_check(ui.note_input.text.is_empty(), "发送后的当前草稿不会在切换回来时复活")
	_check(ui.simulation.advance(20.0) == OK, "右键入口发起的纸条通过真实时间完成")
	ui._refresh_interface()
	_check(ui.simulation.notes.size() == 1 and ui.notes_text.text.contains("给小陈：下课一起讨论。"), "完成后仅在对应会话出现真实送达文字")


## 右键橡皮目标独立于查看对象和纸条收件人，不会重定向已有草稿。
func _test_eraser_target(ui: Control) -> void:
	_reset_session(ui)
	ui._set_interaction_target(1)
	ui.note_input.text = "橡皮操作不能移动这张草稿"
	ui._select_student(3)
	var untouched: Dictionary = ui.simulation.students[1].current_action.duplicate(true)
	_right_click_student(ui, 2)
	ui.context_eraser_button.pressed.emit()
	_check(not ui.context_overlay.visible and not ui.fatal_error, "右键橡皮实际发动后关闭小面板")
	_check(ui.simulation.students[0].current_action.action_id == "eraser_prank" and ui.simulation.students[2].current_action.action_id == "eraser_prank", "右键橡皮由玩家控制真实右键目标")
	_check(ui.simulation.students[1].current_action == untouched and ui.selected_index == 3, "右键目标与查看对象、侧栏收件人相互独立")
	_check(ui.interaction_target_index == 1 and ui.note_input.text == "橡皮操作不能移动这张草稿", "快捷橡皮保留原收件人与未发文字")
	_check(is_equal_approx(ui.simulation.students[0].focus, 76.0) and is_equal_approx(ui.simulation.students[2].focus, 80.0), "快捷橡皮只扣真实发起者启动费，不提前结算完成型效果")
	_check(ui.simulation.advance(30.0) == OK, "右键橡皮真实完成")
	_check(is_equal_approx(ui.simulation.students[0].focus, 77.0) and is_equal_approx(ui.simulation.students[2].focus, 73.0), "快捷橡皮完成奖惩只作用于真实双方")


## 核心前置失败在菜单可见，直接调用回调也必须真实拒绝且保留旧动作和草稿。
func _test_unavailable_action(ui: Control) -> void:
	_reset_session(ui)
	ui._set_interaction_target(1)
	ui.note_input.text = "拒绝后继续写"
	ui.simulation.students[0].focus = 1.0
	_right_click_student(ui, 2)
	var reason: String = ui.simulation.interaction_unavailable_reason(0, 2, "eraser_prank")
	_check(ui.context_eraser_button.disabled and not reason.is_empty() and _menu_explains(ui, ui.context_eraser_button, reason), "资源不足时小面板显示来自真实核心的禁用原因")
	var before: Dictionary = _snapshot(ui.simulation)
	ui._on_context_eraser_pressed()
	await process_frame
	_check(not ui.fatal_error and _snapshot(ui.simulation) == before, "失效菜单指令明确拒绝，不扣费、不打断旧动作")
	_check(ui.note_input.text == "拒绝后继续写" and ui.error_dialog.dialog_text.contains(reason), "真实拒绝可见且保留未发草稿")
	ui.error_dialog.hide()


## 举报使用右键事件而非侧栏事件，玩家不在该互动时仍保持自己的原动作。
func _test_report_target(ui: Control) -> void:
	_reset_session(ui)
	ui._set_interaction_target(1)
	ui.note_input.text = "举报不转移草稿"
	ui._select_student(3)
	_check(ui.simulation.start_action(2, "daydream") == OK, "右键目标真实开小差形成事件")
	var violation: Dictionary = ui.simulation.get_open_violation(2)
	_right_click_student(ui, 2)
	_check(not violation.is_empty() and ui.context_violation_id == int(violation.violation_id) and not ui.context_report_button.disabled, "菜单绑定右键对象真实可举报事件编号")
	var own_action: Dictionary = ui.simulation.students[0].current_action.duplicate(true)
	var other_action: Dictionary = ui.simulation.students[1].current_action.duplicate(true)
	var own_focus: float = ui.simulation.students[0].focus
	var target_focus: float = ui.simulation.students[2].focus
	ui.context_report_button.pressed.emit()
	_check(not ui.fatal_error and not ui.context_overlay.visible, "右键举报真实结算后关闭面板")
	_check(ui.simulation.students[0].current_action == own_action and ui.simulation.students[1].current_action == other_action, "举报保持玩家动作且不错误控制侧栏收件人")
	_check(is_equal_approx(ui.simulation.students[0].focus, own_focus + 3.0) and is_equal_approx(ui.simulation.students[2].focus, target_focus - 5.0), "举报奖惩来自真实右键目标，不重收强制入段费用")
	_check(ui.simulation.get_open_violation(2).is_empty() and ui.simulation.students[2].current_action.action_id == "study", "真实事件关闭并让右键目标回到当前课程")
	_check(ui.interaction_target_index == 1 and ui.note_input.text == "举报不转移草稿" and ui.selected_index == 3, "快捷举报不影响原草稿收件人和查看对象")


## 旧事件结束后出现新事件，刷新不能静默把旧菜单请求改成举报新一次违纪。
func _test_expired_report(ui: Control) -> void:
	_reset_session(ui)
	_check(ui.simulation.start_action(2, "daydream") == OK, "建立即将过期的真实举报事件")
	_right_click_student(ui, 2)
	var captured_id: int = ui.context_violation_id
	_check(captured_id > 0, "打开菜单时已取得有效事件编号")
	_check(ui.simulation.start_action(2, "study", false) == OK and ui.simulation.start_action(2, "daydream") == OK, "目标先恢复学习再形成新的独立违纪")
	var new_violation: Dictionary = ui.simulation.get_open_violation(2)
	_check(not new_violation.is_empty() and int(new_violation.violation_id) != captured_id, "后续违纪具有另一真实事件编号")
	ui._refresh_student_context()
	var reason: String = ui.simulation.report_unavailable_reason(2, captured_id)
	_check(ui.context_violation_id == captured_id and ui.context_report_button.disabled and _menu_explains(ui, ui.context_report_button, reason), "刷新保留原事件快照并明确显示失效原因")
	var before: Dictionary = _snapshot(ui.simulation)
	ui._on_context_report_pressed()
	await process_frame
	_check(not ui.fatal_error and _snapshot(ui.simulation) == before, "过期菜单点击不会惩罚新事件或重复奖励自己")
	_check(not reason.is_empty() and ui.error_dialog.dialog_text.contains(reason), "失效举报直接提交仍通过真实核心可见拒绝")
	ui.error_dialog.hide()


## 当前搭档举报的特殊后果须在小面板中明确，执行仍走统一整体打断链。
func _test_partner_report(ui: Control) -> void:
	_reset_session(ui)
	_check(ui.simulation.start_interaction(0, 1, "send_note", "右键举报前尚未送达") == OK, "建立真实的当前纸条搭档")
	ui._set_interaction_target(2)
	ui.note_input.text = "另一位同学的草稿"
	_right_click_student(ui, 1)
	var explanation: String = ui.context_reason_label.text + "\n" + ui.context_reason_label.tooltip_text + "\n" + ui.context_report_button.tooltip_text
	_check(not ui.context_report_button.disabled and explanation.contains("举报当前搭档") and explanation.contains("结束"), "小面板按右键对象提示同组举报后果，不误用侧栏对象")
	var own_instance: int = ui.simulation.students[0].current_action.instance_id
	ui.context_report_button.pressed.emit()
	_check(not ui.fatal_error and ui.simulation.students[0].current_action.instance_id != own_instance, "当前搭档举报真实结束玩家原互动")
	_check(ui.simulation.students[0].current_action.action_id == "study" and ui.simulation.students[1].current_action.action_id == "study", "当前搭档举报后双方走确认的课表路径")
	_check(ui.simulation.advance(20.0) == OK and ui.simulation.notes.is_empty(), "旧纸条结束时刻到达后仍不送达被举报打断的文字")
	_check(ui.interaction_target_index == 2 and ui.note_input.text == "另一位同学的草稿", "同组举报也不破坏其他收件人的草稿")


## 四种桌面尺寸与三位同学均检查真实排版，展开小面板不改变主窗口尺寸。
func _test_layout(ui: Control, scale: int, panel_visible: bool) -> void:
	_reset_session(ui)
	ui._set_window_scale(scale)
	ui._set_panel_visible(panel_visible)
	var expected_size: Vector2i = ui._get_layout_size()
	for target_index in [1, 2, 3]:
		_right_click_student(ui, target_index)
		await process_frame
		await process_frame
		var bounds := Rect2(ui.global_position, ui.size).grow(1.0)
		_check(ui._get_layout_size() == expected_size and Vector2i(ui.size) == expected_size, "%d倍详情%s的右键面板不撑大主窗口" % [scale, panel_visible])
		_check(ui.context_overlay.is_visible_in_tree() and ui.context_panel.is_visible_in_tree(), "对应尺寸下小面板真实可见")
		_check(bounds.encloses(ui.context_panel.get_global_rect()), "%d倍详情%s目标%d的小面板不超出窗口边界" % [scale, panel_visible, target_index])
		_check_context_bounds(ui.context_panel, bounds)
		ui._close_student_context()


## 对当前可见的小面板内容逐项检查，内部文字和按钮不得跑出面板或主窗口。
func _check_context_bounds(node: Node, bounds: Rect2) -> void:
	if node is Control and node.is_visible_in_tree() and node.size.x > 0.0 and node.size.y > 0.0:
		_check(bounds.encloses(node.get_global_rect()), "右键面板控件保持在窗口内：%s %s" % [node.name, node.get_global_rect()])
	for child in node.get_children():
		if not child is Window:
			_check_context_bounds(child, bounds)


## 尺寸、侧栏、隐藏和换局使旧坐标失效时关闭小面板，不暂停真实玩法。
func _test_lifecycle_closure(ui: Control) -> void:
	_reset_session(ui)
	ui._set_window_scale(1)
	ui._set_panel_visible(false)
	_right_click_student(ui, 2)
	ui._set_window_scale(2)
	_check(not ui.context_overlay.visible, "缩放改变后关闭旧坐标的小面板")
	_right_click_student(ui, 2)
	ui._set_panel_visible(true)
	_check(not ui.context_overlay.visible, "侧栏展开导致布局改变时关闭小面板")
	_right_click_student(ui, 2)
	ui._on_window_hidden()
	_check(not ui.context_overlay.visible and not ui.room.animation_enabled, "隐藏窗口时关闭小面板并沿用视觉暂停链")
	var before_elapsed: float = ui.simulation.elapsed_s
	_check(ui.simulation.advance(1.0) == OK and ui.simulation.elapsed_s > before_elapsed, "隐藏回调不暂停唯一权威执行器")
	ui._on_window_restored()
	_check(not ui.context_overlay.visible and ui.room.animation_enabled, "恢复窗口不重新弹出已关闭的小面板")
	ui._set_interaction_target(1)
	ui.note_input.text = "不应带入新局的草稿"
	_right_click_student(ui, 2)
	ui._start_session(false)
	_check(not ui.fatal_error and not ui.context_overlay.visible, "新局关闭旧菜单并保留正常初始化")
	ui._set_interaction_target(1)
	_check(ui.note_input.text.is_empty(), "新局不继承上一局同学的草稿")


## 致命错误的关闭链用真实_fail验证，预期日志仅限这一条显式测试错误。
func _test_fatal_closure(ui: Control) -> void:
	_right_click_student(ui, 1)
	print("EXPECTED_CONTEXT_FAILURE explicit_stop")
	ui._fail("右键面板隔离测试：验证致命失败关闭旧菜单。")
	_check(ui.fatal_error and not ui.context_overlay.visible, "致命错误关闭小面板，不能继续提交旧指令")
	ui.error_dialog.hide()


## 以生产座位几何得到角色身体内点击点，实际信号仍由ClassroomView负责发出。
func _student_point(ui: Control, student_index: int) -> Vector2:
	ui.room._update_geometry()
	return ui.room.room_origin + (ClassroomView.SEATS[student_index] - Vector2(0, 12)) * ui.room.pixel_scale


## 所有右键入口都经过真实教室输入回调，不直接替代为菜单内部状态赋值。
func _right_click_student(ui: Control, student_index: int) -> void:
	ui.room._gui_input(_mouse_button(MOUSE_BUTTON_RIGHT, _student_point(ui, student_index)))


## 构造实际输入事件交给生产接线，测试本身不直接结算任何资源或结果。
func _mouse_button(button_index: MouseButton, position_value: Vector2) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = button_index
	event.pressed = true
	event.position = position_value
	return event


## 鼠标按下和释放均走视口命中与GUI分发，验证真实遮罩而非手动调用回调。
func _push_mouse(ui: Control, button_index: MouseButton, global_point: Vector2) -> void:
	var pressed := _mouse_button(button_index, global_point)
	pressed.global_position = global_point
	pressed.button_mask = MOUSE_BUTTON_MASK_LEFT if button_index == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT
	ui.get_viewport().push_input(pressed)
	var released: InputEventMouseButton = pressed.duplicate()
	released.pressed = false
	released.button_mask = 0
	ui.get_viewport().push_input(released)


## 向真实视口提交按下和释放，键盘焦点与按钮行为交给生产输入分发。
func _push_key(ui: Control, keycode: Key, shifted: bool = false) -> void:
	var pressed := InputEventKey.new()
	pressed.keycode = keycode
	pressed.physical_keycode = keycode
	pressed.shift_pressed = shifted
	pressed.pressed = true
	ui.get_viewport().push_input(pressed)
	var released: InputEventKey = pressed.duplicate()
	released.pressed = false
	ui.get_viewport().push_input(released)


## 允许原因显示在按钮提示或共用说明中，但必须保留核心给出的实际内容。
func _menu_explains(ui: Control, button: Button, reason: String) -> bool:
	return not reason.is_empty() and (button.tooltip_text + "\n" + ui.context_reason_label.text + "\n" + ui.context_reason_label.tooltip_text).contains(reason)


## 用真实内存状态快照核验纯界面动作没有改玩法，避免为比较而写入存档。
func _snapshot(simulation: ClassroomSimulation) -> Dictionary:
	return {
		"students": simulation.students.duplicate(true), "interactions": simulation.interactions.duplicate(true),
		"notes": simulation.notes.duplicate(true), "violations": simulation.violations.duplicate(true),
		"logs": simulation.logs.duplicate(true), "elapsed_s": simulation.elapsed_s,
		"rng_state": simulation.rng.state,
	}


## 累积真实断言失败，最终由测试进程退出码反映实际结果。
func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)


## 汇总界面接线检查，不把无头事件调用算作真实鼠标或系统托盘验收。
func _finish() -> void:
	if failures.is_empty():
		print("CONTEXT_MENU_TEST_PASS checks=%s expected_failures=1 native_mouse_not_tested" % checks)
		quit(0)
	else:
		for message in failures:
			push_error(message)
		print("CONTEXT_MENU_TEST_FAIL checks=%s failures=%s" % [checks, failures.size()])
		quit(1)
