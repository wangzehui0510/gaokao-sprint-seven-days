extends SceneTree
## 在独立临时工程和独立用户目录中验证真实界面的初始化失败恢复链。

# 统计真实断言；正式工程中的user://存档从不参与本测试。
var checks: int = 0
var failures: Array[String] = []


## 等待场景树就绪，再区分隔离工程子进程与只负责创建隔离环境的入口。
func _initialize() -> void:
	call_deferred("_run")


## 子进程先验证用户目录确实隔离，随后才允许创建损坏存档夹具。
func _run() -> void:
	var arguments: PackedStringArray = OS.get_cmdline_user_args()
	if "--isolated-ui-initialization" in arguments:
		var marker: String = str(ProjectSettings.get_setting("application/config/name"))
		if not marker.begins_with("ClassroomUiInitializationTest_") or marker not in OS.get_user_data_dir():
			push_error("测试用户目录未隔离，拒绝运行任何存档写入")
			quit(1)
			return
		await _test_real_interface()
		_finish()
	else:
		_launch_isolated_project()


## 复制真实工程内容并使用单独应用名称启动，不修改正式project.godot或用户数据。
func _launch_isolated_project() -> void:
	var marker: String = "ClassroomUiInitializationTest_%s_%s" % [OS.get_process_id(), Time.get_ticks_usec()]
	var isolated_root: String = OS.get_cache_dir().path_join(marker)
	var result: Error = DirAccess.make_dir_recursive_absolute(isolated_root)
	if result != OK:
		push_error("无法创建隔离工程：%s" % result)
		quit(1)
		return
	for folder in ["scripts", "config", "assets", "addons", "scenes", "tests"]:
		result = _copy_directory(ProjectSettings.globalize_path("res://" + folder), isolated_root.path_join(folder))
		if result != OK:
			push_error("复制真实工程目录失败：%s，错误码%s" % [folder, result])
			quit(1)
			return
	var project := ConfigFile.new()
	result = project.load("res://project.godot")
	if result != OK:
		push_error("无法读取真实工程设置：%s" % result)
		quit(1)
		return
	project.set_value("application", "config/name", marker)
	project.set_value("application", "config/use_custom_user_dir", true)
	project.set_value("application", "config/custom_user_dir_name", marker)
	result = project.save(isolated_root.path_join("project.godot"))
	if result != OK:
		push_error("无法保存隔离工程设置：%s" % result)
		quit(1)
		return
	var output: Array = []
	var exit_code: int = OS.execute(OS.get_executable_path(), ["--headless", "--path", isolated_root, "--editor", "--import"], output, true)
	if exit_code != 0:
		for line in output:
			print(line)
		push_error("真实工程隔离导入失败：%s" % exit_code)
		quit(exit_code)
		return
	output.clear()
	exit_code = OS.execute(OS.get_executable_path(), ["--headless", "--path", isolated_root, "--script", "res://tests/test_ui_initialization.gd", "--", "--isolated-ui-initialization"], output, true)
	for line in output:
		print(line)
	print("UI_INITIALIZATION_TEST_PROJECT=%s" % isolated_root)
	quit(exit_code)


## 递归复制既有文件属于测试环境准备，失败直接中止而不跳过缺失资源。
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


## 只手动安排真实主界面的生命周期；配置、模拟器、存档和四人行为树均调用生产实现。
func _test_real_interface() -> void:
	var main_script: Script = load("res://scripts/ui/main.gd")
	var ui := Control.new()
	root.add_child(ui)
	# 在基类已完成ready后挂载真实脚本，避免自动_ready抢先开始测试局。
	ui.set_script(main_script)
	ui.set_process(false)
	ui._build_theme()
	ui._build_interface()
	_check(ui.configuration == null and ui.simulation == null, "测试前主界面尚未加载配置和状态")
	print("EXPECTED_UI_FAILURE missing_configuration")
	ui._start_session(false)
	_check(ui.fatal_error, "缺配置启动必须明确停止")
	_check(ui.simulation == null, "缺配置启动不得留下可被重载误认为有效的状态")
	_check(ui.error_dialog.dialog_text.contains("重新读取配表"), "缺配置错误明确说明恢复入口")
	ui.error_dialog.hide()
	ui._reload_configuration()
	_check(not ui.fatal_error and ui.simulation != null, "修复配置后完整重新初始化成功")
	_check(ui.simulation.students.size() == 4, "恢复后具备四份真实角色状态")
	_check(ui.behavior.trees.size() == 4 and ui.simulation.decision_handler.is_valid(), "恢复后挂接四棵真实行为树")
	_check(ui.status_label.text == "配表已更新", "只有成功初始化后才显示更新成功")
	_check(not FileAccess.file_exists("user://classroom_save.json"), "仅初始化不会创建或覆盖存档")
	var valid_simulation: ClassroomSimulation = ui.simulation
	var expected_focus: float = valid_simulation.students[0].focus
	var valid_save: String = "user://ui_initialization_valid_fixture.json"
	_check(valid_simulation.save_file(valid_save) == OK, "通过真实存档执行器生成修复夹具")
	var damaged_text: String = "{ invalid save json"
	var file := FileAccess.open("user://classroom_save.json", FileAccess.WRITE)
	_check(file != null, "损坏存档仅写入隔离用户目录")
	if file == null:
		ui.free()
		return
	file.store_string(damaged_text)
	file.close()
	print("EXPECTED_UI_FAILURE invalid_save_initialization")
	ui._start_session(true)
	_check(ui.fatal_error and ui.simulation == null, "损坏存档初始化失败不留下新局状态")
	_check(ui.error_dialog.dialog_text.contains("存档JSON"), "损坏存档错误可见")
	_check(not ui._save_session(false), "初始化失败后保存必须失败")
	_check(FileAccess.get_file_as_string("user://classroom_save.json") == damaged_text, "失败不能以新局覆盖损坏原文件")
	ui.error_dialog.hide()
	# 等待旧控制器queue_free完成，重试时不复用已移出场景树的对象。
	await process_frame
	print("EXPECTED_UI_FAILURE invalid_save_reload")
	ui._reload_configuration()
	_check(ui.fatal_error and ui.simulation == null, "重读配表仍完整重试读档，损坏存档不能误成功")
	_check(ui.status_label.text == "运行已停止", "失败后不能显示配表更新成功")
	_check(FileAccess.get_file_as_string("user://classroom_save.json") == damaged_text, "重试失败仍不修改损坏存档")
	ui.error_dialog.hide()
	_check(DirAccess.copy_absolute(ProjectSettings.globalize_path(valid_save), ProjectSettings.globalize_path("user://classroom_save.json")) == OK, "以真实有效存档修复隔离测试文件")
	ui._reload_configuration()
	_check(not ui.fatal_error and ui.simulation != null, "存档修正后可经重载完整恢复")
	_check(ui.simulation.students.size() == 4 and ui.behavior.trees.size() == 4, "修复存档后真实角色与行为树完整")
	_check(absf(ui.simulation.students[0].focus - expected_focus) < 0.000001, "修复存档恢复原资源，不重开默认局")
	_check(ui.status_label.text == "配表已更新", "真实恢复成功后才报告成功")
	print("UI_INITIALIZATION_TEST_USER_DIR=%s" % OS.get_user_data_dir())
	ui.free()


## 断言失败记录实际原因并由最终进程退出码体现，不伪造成功。
func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)


## 汇总真实主界面用例，预期错误仍由生产_fail正常输出。
func _finish() -> void:
	if failures.is_empty():
		print("UI_INITIALIZATION_TEST_PASS checks=%s expected_failures=3" % checks)
		quit(0)
	else:
		for message in failures:
			push_error(message)
		print("UI_INITIALIZATION_TEST_FAIL checks=%s failures=%s" % [checks, failures.size()])
		quit(1)
