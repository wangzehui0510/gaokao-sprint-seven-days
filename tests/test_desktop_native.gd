extends SceneTree
## 使用隔离工程中的真实Windows窗口、托盘和主循环验收桌面模式。

const BRIDGE = "res://tools/native/bin/DesktopWindowBridge.exe"
const CHECKPOINT = "res://native_test_checkpoint.json"

# 只记录实际断言；原生子进程退出后，父进程还会复核真实存档。
var checks: int = 0
var failures: Array[String] = []
var hidden_signals: int = 0
var restored_signals: int = 0


## 场景树可用后先准备隔离工程，测试从不使用正式应用目录。
func _initialize() -> void:
	call_deferred("_run")


## 只有明确隔离的Windows子进程才能创建真实界面并写入测试存档。
func _run() -> void:
	if "--isolated-native-desktop" not in OS.get_cmdline_user_args():
		_launch_isolated_project()
		return
	var marker: String = str(ProjectSettings.get_setting("application/config/name"))
	if not marker.begins_with("ClassroomDesktopNativeTest_") or marker not in OS.get_user_data_dir():
		push_error("原生桌面验收的用户目录未隔离，拒绝运行。")
		quit(1)
		return
	if OS.get_name() != "Windows" or DisplayServer.get_name() == "headless":
		push_error("原生桌面验收必须使用真实Windows显示服务。")
		quit(1)
		return
	if "--visual-review" not in OS.get_cmdline_user_args():
		# 脚本运行时错误也必须结束测试子进程，避免父进程永久等待。
		create_timer(45.0).timeout.connect(func():
			_check(false, "原生验收超过45秒，可能发生脚本错误或窗口操作阻塞")
			_finish()
		)
	await _test_native_desktop()


## 复制真实工程与已编译桥接，独立导入后启动有窗口的实际游戏验收。
func _launch_isolated_project() -> void:
	if not FileAccess.file_exists(BRIDGE):
		push_error("请先运行 tools/native/build_bridge.ps1 构建原生辅助程序。")
		quit(1)
		return
	var marker: String = "ClassroomDesktopNativeTest_%s_%s" % [OS.get_process_id(), Time.get_ticks_usec()]
	var isolated_root: String = OS.get_cache_dir().path_join(marker)
	for folder in ["scripts", "config", "assets", "addons", "scenes", "tests", "tools/native"]:
		var copy_result: Error = _copy_directory(ProjectSettings.globalize_path("res://" + folder), isolated_root.path_join(folder))
		if copy_result != OK:
			push_error("复制原生验收工程失败：%s，错误码%d。" % [folder, copy_result])
			quit(1)
			return
	if not _disable_isolated_social(isolated_root):
		quit(1)
		return
	var settings := ConfigFile.new()
	if settings.load("res://project.godot") != OK:
		quit(1)
		return
	settings.set_value("application", "config/name", marker)
	settings.set_value("application", "config/use_custom_user_dir", true)
	settings.set_value("application", "config/custom_user_dir_name", marker)
	if settings.save(isolated_root.path_join("project.godot")) != OK:
		quit(1)
		return
	var output: Array = []
	var exit_code: int = OS.execute(OS.get_executable_path(), ["--headless", "--editor", "--path", isolated_root, "--import"], output, true)
	if exit_code != 0:
		for line in output:
			print(line)
		quit(1)
		return
	output.clear()
	var arguments: PackedStringArray = ["--path", isolated_root, "--script", "res://tests/test_desktop_native.gd", "--", "--isolated-native-desktop"]
	if "--visual-review" in OS.get_cmdline_user_args():
		arguments.append("--visual-review")
	exit_code = OS.execute(OS.get_executable_path(), arguments, output, true, false)
	for line in output:
		print(line)
	_check(exit_code == 0, "真实窗口子进程通过托盘退出请求正常退出")
	_check(FileAccess.file_exists(isolated_root.path_join("native_exit_hidden")), "在途隐藏先真实完成，退出流程随后保存并结束")
	var checkpoint_path: String = isolated_root.path_join("native_test_checkpoint.json")
	_check(FileAccess.file_exists(checkpoint_path), "原生子进程完成全部验收并写入退出前检查点")
	if FileAccess.file_exists(checkpoint_path):
		var data = JSON.parse_string(FileAccess.get_file_as_string(checkpoint_path))
		_check(data is Dictionary, "退出检查点是完整JSON")
		if data is Dictionary:
			var test_user_dir: String = String(data.user_dir)
			_check(marker in test_user_dir, "父进程复核检查点仍指向本次隔离用户目录")
			if marker not in test_user_dir:
				_finish()
				return
			var saved = JSON.parse_string(FileAccess.get_file_as_string(String(data.user_dir).path_join("classroom_debug_save.json")))
			_check(saved is Dictionary, "真正退出已经写入开发局存档")
			if saved is Dictionary:
				_check(float(saved.elapsed_s) >= float(data.elapsed_s), "退出保存包含退出前已经结算的进度")
				_check(saved.students.size() == 4, "退出保存包含四名真实角色")
			_check(FileAccess.get_file_as_string(String(data.user_dir).path_join("classroom_save.json")) == String(data.formal_save), "开发局验收和退出未覆盖隔离的正式局存档")
			var preferences = JSON.parse_string(FileAccess.get_file_as_string(String(data.user_dir).path_join("desktop_settings.json")))
			_check(preferences is Dictionary and preferences.pixel_scale == 1, "退出前窗口偏好已成功落盘")
			checks += int(data.checks)
	print("DESKTOP_NATIVE_TEST_PROJECT=%s" % isolated_root)
	_finish()


## 只关闭本次隔离副本的自主竞争，专门验收后台纸条、窗口和保存生命周期。
func _disable_isolated_social(isolated_root: String) -> bool:
	var path: String = isolated_root.path_join("config/phase_scope.json")
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not data is Dictionary:
		push_error("原生验收隔离副本的阶段配置无效：" + path)
		return false
	data.social_auto_actions = []
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("无法写入原生验收的隔离阶段配置：" + path)
		return false
	file.store_string(JSON.stringify(data, "\t", true, true))
	file.close()
	return true


## 测试准备遇到任何真实复制失败都中止，不跳过缺失的源码或素材。
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


## 直接加载主场景，原生托盘、唯一模拟器、指令与保存均运行生产代码。
func _test_native_desktop() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn")
	var ui: Control = scene.instantiate()
	root.add_child(ui)
	await process_frame
	await process_frame
	_check(ui.desktop != null and ui.desktop.is_initialized(), "主界面实际初始化了Windows托盘")
	_check(not ui.fatal_error and ui.simulation != null, "原生主场景完整初始化真实游戏")
	if ui.desktop == null or not ui.desktop.is_initialized() or ui.simulation == null:
		_finish()
		return
	var desktop: DesktopWindowController = ui.desktop
	desktop.hide_requested.connect(func(): hidden_signals += 1)
	desktop.restore_requested.connect(func(): restored_signals += 1)
	_check(ui.behavior.trees.size() == 4, "原生界面运行四棵真实行为树")
	_check(root.size == Vector2i(384, 320), "真实原生窗口初始为384×320")
	_check(root.borderless and root.transparent and root.transparent_bg, "真实主窗口启用无边框和透明")
	_check(_query_window().get("visible") == true, "Win32确认初始窗口可见")
	_check(ui._save_session(false), "真实保存器生成隔离正式局夹具")
	var formal_save: String = FileAccess.get_file_as_string("user://classroom_save.json")
	await _test_native_window_state(ui, desktop)
	await _test_preferences_round_trip(ui, desktop)
	await _test_background_progress(ui, desktop)
	await _test_exit_failure(ui, desktop)
	if not failures.is_empty():
		_finish()
		return
	if "--visual-review" in OS.get_cmdline_user_args():
		print("DESKTOP_NATIVE_VISUAL_REVIEW_READY project=%s" % ProjectSettings.globalize_path("res://"))
		# 人工界面复核仅在显式模式等待外部完成标记，不改变任何生产游戏逻辑。
		while not FileAccess.file_exists("res://native_visual_review_done"):
			await create_timer(0.2).timeout
	_check(await desktop.restore_window() == OK, "退出竞态验收先确保窗口真实可见")
	var checkpoint: Dictionary = {
		"checks": checks,
		"user_dir": OS.get_user_data_dir(),
		"elapsed_s": ui.simulation.elapsed_s,
		"formal_save": formal_save,
	}
	var file := FileAccess.open(CHECKPOINT, FileAccess.WRITE)
	_check(file != null, "写入真实退出验收检查点")
	if file == null:
		_finish()
		return
	file.store_string(JSON.stringify(checkpoint))
	file.close()
	# 先发起在途隐藏再点击退出，验证退出等待不会阻塞主窗口消息泵。
	desktop.hide_requested.connect(_mark_exit_hide_completed, CONNECT_ONE_SHOT)
	desktop.hide_to_tray()
	# 托盘回调使用真实退出入口；父进程在真正退出后再复核落盘结果。
	desktop._on_menu_action("quit")
	await create_timer(5.0).timeout
	_check(false, "托盘真正退出请求未结束进程")
	_finish()


## 只有真正隐藏成功的生产信号才能写入退出竞态验收标记。
func _mark_exit_hide_completed() -> void:
	var file := FileAccess.open("res://native_exit_hidden", FileAccess.WRITE)
	if file == null:
		_check(false, "无法写入退出前隐藏完成标记")
		return
	file.store_string("verified hidden before shutdown")
	file.close()


## 用真实HWND验证隐藏、恢复和进程归属，成功信号必须与操作结果一致。
func _test_native_window_state(ui: Control, desktop: DesktopWindowController) -> void:
	var hwnd: int = DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE)
	var output: Array = []
	var exit_code: int = OS.execute(ProjectSettings.globalize_path(BRIDGE), ["hide", str(hwnd), str(OS.get_process_id() + 1000000)], output, true, false)
	_check(exit_code != 0 and _query_window().get("visible") == true, "错误进程归属被拒绝且没有隐藏其他窗口")
	output.clear()
	exit_code = OS.execute(ProjectSettings.globalize_path(BRIDGE), ["hide", "0", str(OS.get_process_id())], output, true, false)
	_check(exit_code != 0, "无效HWND明确失败")
	var hidden_before: int = hidden_signals
	var restored_before: int = restored_signals
	_check(await desktop.hide_to_tray() == OK, "生产窗口控制器真实隐藏成功")
	_check(desktop.hidden_to_tray and _query_window().get("visible") == false, "Win32确认主窗口实际不可见")
	_check(hidden_signals == hidden_before + 1 and not ui.room.animation_enabled, "确认隐藏后才发送信号并停止视觉动画")
	_check(await desktop.restore_window() == OK, "生产窗口控制器真实恢复成功")
	_check(not desktop.hidden_to_tray and _query_window().get("visible") == true, "Win32确认主窗口实际恢复可见")
	_check(restored_signals == restored_before + 1 and ui.room.animation_enabled, "确认恢复后才恢复视觉动画")
	root.mode = Window.MODE_MINIMIZED
	await process_frame
	_check(await desktop.restore_window() == OK, "最小化窗口能够通过同一恢复入口找回")
	_check(_query_window().get("minimized") == false, "Win32确认恢复后不再最小化")
	var anchor: Vector2i = root.position + root.size
	desktop.request_zoom(2)
	await process_frame
	await process_frame
	_check(root.size == Vector2i(768, 576) and ui.room.size == Vector2(768, 512), "原生窗口和教室真实切换2倍")
	ui._set_panel_visible(true)
	await process_frame
	await process_frame
	_check(root.size == Vector2i(1068, 576), "原生2倍窗口向左展开详情")
	var work_area: Rect2i = DisplayServer.screen_get_usable_rect(desktop._screen_for_anchor(anchor))
	var destination: Vector2i = anchor - root.size
	destination.x = clampi(destination.x, work_area.position.x, maxi(work_area.position.x, work_area.end.x - root.size.x))
	destination.y = clampi(destination.y, work_area.position.y, maxi(work_area.position.y, work_area.end.y - root.size.y))
	_check(root.position == destination, "缩放和展开保留锚点，并在屏幕空间不足时约束在工作区")
	ui._set_panel_visible(false)
	desktop.request_zoom(1)
	await process_frame
	await process_frame
	_check(root.size == Vector2i(384, 320), "原生窗口收起后恢复1倍尺寸")
	desktop.set_pinned(false)
	_check(not root.always_on_top, "取消置顶修改真实窗口标志")
	desktop.set_pinned(true)
	_check(root.always_on_top, "置顶恢复真实窗口标志")


## 清理并重新初始化同一控制器，检查偏好确实来自已保存文件。
func _test_preferences_round_trip(ui: Control, desktop: DesktopWindowController) -> void:
	desktop.request_zoom(2)
	desktop.set_pinned(false)
	await process_frame
	await process_frame
	_check(desktop.persist_preferences() == OK, "真实窗口偏好可保存")
	var anchor: Vector2i = root.position + root.size
	var path: String = desktop.preferences_path
	desktop.shutdown()
	_check(not desktop.is_initialized(), "释放托盘后控制器明确结束初始化状态")
	root.position -= Vector2i(37, 29)
	root.always_on_top = true
	_check(desktop.initialize(root, path) == OK, "同一控制器能够再次创建真实托盘")
	ui.window_scale = desktop.pixel_scale
	ui._apply_layout()
	desktop.configure_layout(ui._get_layout_size())
	_check(root.position + root.size == anchor, "重新初始化读取保存锚点而非遗留位置")
	_check(desktop.pixel_scale == 2 and not desktop.pinned and not root.always_on_top, "重新初始化实际读取保存的2倍与非置顶，不能靠默认值通过")
	desktop.request_zoom(1)
	desktop.set_pinned(true)
	await process_frame
	await process_frame


## 在托盘隐藏期间等待真实墙钟时间，检查四人结算和30秒自动保存链。
func _test_background_progress(ui: Control, desktop: DesktopWindowController) -> void:
	_check(ui.simulation.set_debug_time(1, 28800.0) == OK, "原生验收进入独立开发局时钟")
	_check(ui.simulation.advance(0.0) == OK, "四人通过真实课表选择学习动作")
	var knowledge_before: Array[float] = []
	for student in ui.simulation.students:
		knowledge_before.append(student.knowledge.chinese)
	ui.save_elapsed = 29.7
	_check(await desktop.hide_to_tray() == OK, "后台进度验收真实隐藏窗口")
	var before_elapsed: float = ui.simulation.elapsed_s
	await create_timer(1.25).timeout
	_check(_query_window().get("visible") == false, "等待期间窗口始终保持真实隐藏")
	_check(ui.simulation.elapsed_s - before_elapsed >= 1.0, "隐藏期间唯一主循环按真实经过秒数推进")
	for index in 4:
		_check(ui.simulation.students[index].knowledge.chinese > knowledge_before[index], "隐藏期间第%d名角色真实获得学习收益" % index)
	_check(FileAccess.file_exists("user://classroom_debug_save.json"), "隐藏期间原生产自动保存链仍然写入开发局")
	var saved = JSON.parse_string(FileAccess.get_file_as_string("user://classroom_debug_save.json"))
	_check(saved is Dictionary and float(saved.elapsed_s) >= before_elapsed, "后台自动保存包含隐藏后真实结算的进度")
	_check(await desktop.restore_window() == OK, "后台验收后恢复真实教室")
	# 通过正常执行器推进到剩余两秒，再验证真实隐藏期间跨过互动完成边界。
	_check(ui.simulation.start_interaction(0, 1, "send_note", "托盘隐藏期间真实送达") == OK, "后台互动由生产入口建立双人纸条")
	var duration: float = ui.simulation.students[0].current_action.duration_s
	_check(ui.simulation.advance(duration - 2.0) == OK and ui.simulation.notes.is_empty(), "隐藏前纸条只执行实际部分且尚未送达")
	_check(await desktop.hide_to_tray() == OK, "在途纸条验收真实隐藏窗口")
	await create_timer(2.5).timeout
	_check(_query_window().get("visible") == false, "纸条完成时主窗口仍真实隐藏")
	_check(ui.simulation.notes.size() == 1 and ui.simulation.notes[0].text == "托盘隐藏期间真实送达", "后台唯一模拟器真实完成纸条且只送达一次")
	_check(ui.simulation.students[0].current_action.action_id == "study" and ui.simulation.students[1].current_action.action_id == "study", "后台完成后双方都按真实课表继续学习")
	_check(ui._save_session(false), "隐藏期间可保存当前版本互动、已送达聊天和领取记录")
	var interaction_save = JSON.parse_string(FileAccess.get_file_as_string("user://classroom_debug_save.json"))
	_check(interaction_save is Dictionary and interaction_save.save_version == ClassroomSimulation.SAVE_VERSION and interaction_save.notes.size() == 1 and interaction_save.students.all(func(student: Dictionary): return student.daily_item_claim_days.size() == 1 and student.daily_item_claim_days[0] == 1), "后台落盘包含当前版本真实送达结果和四人当日领取记录")
	_check(await desktop.restore_window() == OK, "后台互动验收后恢复窗口")


## 制造真实文件写入失败，确认退出失败会找回窗口且不清理托盘或退出。
func _test_exit_failure(ui: Control, desktop: DesktopWindowController) -> void:
	var blocked_save: String = ProjectSettings.globalize_path("user://classroom_debug_save.json.tmp")
	_check(DirAccess.make_dir_recursive_absolute(blocked_save) == OK, "在隔离目录建立真实存档写入失败夹具")
	_check(await desktop.hide_to_tray() == OK, "保存失败验收前真实隐藏窗口")
	print("EXPECTED_NATIVE_FAILURE save_write")
	await ui._request_exit()
	await create_timer(0.3).timeout
	_check(ui.is_inside_tree() and desktop.is_initialized(), "保存失败保留进程和真实托盘")
	_check(ui.fatal_error and ui.error_dialog.visible, "真实存档失败保留现场并显示错误")
	_check(_query_window().get("visible") == true and not desktop.hidden_to_tray, "隐藏时退出保存失败实际找回可见窗口")
	_check(DirAccess.remove_absolute(blocked_save) == OK, "移除当前测试自建的空失败夹具目录")
	ui.error_dialog.hide()
	ui._reload_configuration()
	_check(not ui.fatal_error and ui._save_session(false), "修复写入路径后可从真实重载入口恢复保存")
	var preferences_path: String = desktop.preferences_path
	var blocker := FileAccess.open("user://native_preferences_blocker", FileAccess.WRITE)
	_check(blocker != null, "创建偏好目录冲突的真实文件夹具")
	if blocker == null:
		return
	blocker.store_string("test directory conflict")
	blocker.close()
	_check(await desktop.hide_to_tray() == OK, "偏好保存失败验收前使用正常路径真实隐藏")
	desktop.preferences_path = "user://native_preferences_blocker/settings.json"
	print("EXPECTED_NATIVE_FAILURE preferences_write")
	await ui._request_exit()
	await create_timer(0.3).timeout
	_check(ui.is_inside_tree() and desktop.is_initialized(), "窗口偏好保存失败不能假退出或释放托盘")
	_check(ui.error_dialog.visible and _query_window().get("visible") == true, "偏好保存错误在真实窗口中可见")
	_check(not ui.fatal_error, "窗口偏好写入失败不停止权威模拟器")
	desktop.preferences_path = preferences_path
	ui.error_dialog.hide()
	_check(desktop.persist_preferences() == OK, "修复偏好路径后真实保存成功")


## 只读辅助查询直接核验当前主窗口，不用引擎visible字段代替Win32结果。
func _query_window() -> Dictionary:
	var output: Array = []
	var handle: int = DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE)
	var exit_code: int = OS.execute(ProjectSettings.globalize_path(BRIDGE), ["query", str(handle), str(OS.get_process_id())], output, true, false)
	_check(exit_code == 0 and not output.is_empty(), "真实HWND可见性查询成功")
	if exit_code != 0 or output.is_empty():
		return {}
	var data = JSON.parse_string(String(output[0]).strip_edges())
	_check(data is Dictionary, "原生辅助查询返回有效JSON")
	return data if data is Dictionary else {}


## 每次失败保留实际断言，由最终退出码明确反映。
func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)


## 原生验收通过标记仅在子进程真实退出并复核落盘后输出。
func _finish() -> void:
	if failures.is_empty():
		print("DESKTOP_NATIVE_TEST_PASS checks=%d expected_failures=2" % checks)
		quit(0)
	else:
		for message in failures:
			push_error(message)
		print("DESKTOP_NATIVE_TEST_FAIL checks=%d failures=%d" % [checks, failures.size()])
		quit(1)
