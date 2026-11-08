class_name DesktopWindowController
extends Node

signal restore_requested()
signal hide_requested()
signal quit_requested()
signal zoom_requested(scale: int)
signal pin_changed(value: bool)
signal failure(message: String)

const DEFAULT_PREFERENCES_PATH = "user://desktop_settings.json"
const TRAY_ICON_PATH = "res://assets/pixel/student01/south.png"
const BRIDGE_RELATIVE_PATH = "tools/native/bin/DesktopWindowBridge.exe"
const SETTINGS_VERSION = 1
const FIRST_LAUNCH_MARGIN = Vector2i(16, 16)

# 只保存窗口偏好；游戏状态和结算始终由主界面的唯一执行器持有。
var pixel_scale: int = 1
var pinned: bool = true
var error_message: String = ""
var preferences_path: String = DEFAULT_PREFERENCES_PATH
# 只在辅助程序验证同进程真实 HWND 的可见性后更新，不能用请求本身代表隐藏成功。
var hidden_to_tray: bool = false

# 托盘与原生菜单的句柄只在真实 Windows 初始化成功后有效。
var _window: Window
var _status_indicator: int = -1
var _tray_menu: RID
var _tray_icon: Texture2D
var _pin_menu_index: int = -1
var _one_x_menu_index: int = -1
var _two_x_menu_index: int = -1
var _initialized: bool = false
var _layout_initialized: bool = false

# 原生操作在工作线程中等待，主线程继续处理窗口消息与唯一游戏模拟器。
var _bridge_executable_path: String = ""
var _native_window_handle: int = 0
var _bridge_thread: Thread
var _native_operation: String = ""
var _session_serial: int = 0

# 保存右下角锚点，使详情向左展开、像素缩放和重启都不会挪动主教室右边缘。
var _saved_anchor: Vector2i = Vector2i.ZERO
var _has_saved_anchor: bool = false
var _observed_position: Vector2i = Vector2i.ZERO
var _position_save_elapsed: float = -1.0


# 创建真实系统托盘并读取偏好；无托盘的运行环境明确失败，不隐藏游戏窗口。
func initialize(target_window: Window, settings_path: String = DEFAULT_PREFERENCES_PATH) -> Error:
	if _initialized or target_window == null or settings_path.is_empty():
		return _fail("桌面窗口初始化参数无效或已经初始化。", ERR_INVALID_PARAMETER)
	_window = target_window
	preferences_path = settings_path
	if OS.get_name() != "Windows":
		return _fail("桌面窗口原生桥接只支持 Windows。", ERR_UNAVAILABLE)
	if DisplayServer.get_name() == "headless":
		return _fail("桌面模式需要真实 Windows 窗口与系统托盘，无头模式不能初始化。", ERR_UNAVAILABLE)
	if not DisplayServer.has_feature(DisplayServer.FEATURE_STATUS_INDICATOR) or not NativeMenu.has_feature(NativeMenu.FEATURE_POPUP_MENU):
		return _fail("当前显示后端不支持系统托盘及原生托盘菜单。", ERR_UNAVAILABLE)
	if not DisplayServer.has_feature(DisplayServer.FEATURE_WINDOW_TRANSPARENCY):
		return _fail("当前显示后端不支持桌面透明窗口。", ERR_UNAVAILABLE)
	_bridge_executable_path = ProjectSettings.globalize_path("res://" + BRIDGE_RELATIVE_PATH) if OS.has_feature("editor") else OS.get_executable_path().get_base_dir().path_join(BRIDGE_RELATIVE_PATH)
	if not FileAccess.file_exists(_bridge_executable_path):
		return _fail("缺少 Windows 窗口辅助程序：%s。请先运行 tools/native/build_bridge.ps1。" % _bridge_executable_path, ERR_FILE_NOT_FOUND)
	_native_window_handle = DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, _window.get_window_id())
	if _native_window_handle <= 0:
		return _fail("无法取得游戏窗口的真实 Windows HWND。", ERR_CANT_ACQUIRE_RESOURCE)
	# query 只读取原生状态，不向主线程发消息，因此初始化时可以同步等待。
	var result: Error = _accept_bridge_result("query", _execute_bridge(_bridge_executable_path, "query", _native_window_handle, OS.get_process_id()))
	if result != OK:
		return result
	result = _load_preferences()
	if result != OK:
		return result
	_window.borderless = true
	_window.unresizable = true
	_window.transparent = true
	_window.transparent_bg = true
	_window.always_on_top = pinned
	result = _create_tray()
	if result != OK:
		return result
	_initialized = true
	error_message = ""
	set_process(true)
	return OK


# 主界面只通过此入口判断托盘与原生窗口管理是否完整初始化。
func is_initialized() -> bool:
	return _initialized


# 退出或错误恢复前可等待当前窗口请求结束，避免重入相反的原生命令。
func is_transitioning() -> bool:
	return not _native_operation.is_empty()


# 按真实内容尺寸调整窗口，保留右下锚点；工作区约束只用于保证显示区域可达。
func configure_layout(content_size: Vector2i) -> void:
	if not _initialized or content_size.x <= 0 or content_size.y <= 0:
		_fail("桌面窗口尚未初始化，或内容尺寸无效。", ERR_INVALID_PARAMETER)
		return
	var anchor: Vector2i
	if _layout_initialized:
		anchor = _window.position + _window.size
	elif _has_saved_anchor:
		anchor = _saved_anchor
	else:
		anchor = DisplayServer.screen_get_usable_rect(_window.current_screen).end - FIRST_LAUNCH_MARGIN
	var work_area: Rect2i = DisplayServer.screen_get_usable_rect(_screen_for_anchor(anchor))
	var destination: Vector2i = anchor - content_size
	# 屏幕或任务栏变化后只重新摆放窗口，不擅自改变玩家选择的像素倍数。
	destination.x = clampi(destination.x, work_area.position.x, maxi(work_area.position.x, work_area.end.x - content_size.x))
	destination.y = clampi(destination.y, work_area.position.y, maxi(work_area.position.y, work_area.end.y - content_size.y))
	_window.min_size = Vector2i.ZERO
	_window.size = content_size
	_window.position = destination
	_layout_initialized = true
	_observed_position = _window.position
	_position_save_elapsed = -1.0
	persist_preferences()


# 修改真实置顶标志，并同步菜单与偏好；保存失败通过 failure 明确交给界面显示。
func set_pinned(value: bool) -> void:
	if not _initialized:
		_fail("桌面窗口尚未初始化，不能修改置顶状态。", ERR_UNCONFIGURED)
		return
	pinned = value
	_window.always_on_top = value
	_sync_menu_checks()
	pin_changed.emit(value)
	persist_preferences()


# 收起前先保存窗口偏好，失败时保持窗口可见，避免错误提示被藏进托盘。
func hide_to_tray() -> Error:
	var result: Error = await _wait_for_native_idle()
	if result != OK:
		return result
	result = persist_preferences()
	if result != OK:
		return result
	result = await _perform_native_action("hide")
	if result != OK:
		return result
	hide_requested.emit()
	return OK


# 托盘恢复后先显示并激活窗口，再通知界面恢复画面刷新。
func restore_window() -> Error:
	var result: Error = await _perform_native_action("restore")
	if result != OK:
		return result
	_window.grab_focus()
	restore_requested.emit()
	return OK


# 工作线程等待短命辅助程序；逐帧等待保留主窗口消息、模拟推进和自动保存。
func _perform_native_action(command: String) -> Error:
	var ready: Error = await _wait_for_native_idle()
	if ready != OK:
		return ready
	var session: int = _session_serial
	var worker := Thread.new()
	_bridge_thread = worker
	_native_operation = command
	var result: Error = worker.start(_execute_bridge.bind(_bridge_executable_path, command, _native_window_handle, OS.get_process_id()))
	if result != OK:
		_bridge_thread = null
		_native_operation = ""
		return _fail("无法启动窗口辅助程序工作线程，错误码 %d。" % result, result)
	while worker.is_alive():
		await get_tree().process_frame
	# shutdown 可能已经回收此线程；旧会话的协程不能更新重新初始化后的新会话。
	if session != _session_serial or not worker.is_started():
		return ERR_UNCONFIGURED
	var response: Dictionary = worker.wait_to_finish()
	_bridge_thread = null
	_native_operation = ""
	# 必须先清理操作状态再发 failure，允许主界面的单次错误恢复请求正常启动。
	return _accept_bridge_result(command, response)


# 连续点击托盘时顺序执行请求，等待期间不能发失败信号触发与在途请求冲突的恢复。
func _wait_for_native_idle() -> Error:
	if not _initialized:
		return _fail("桌面窗口尚未初始化，不能执行原生窗口请求。", ERR_UNCONFIGURED)
	var session: int = _session_serial
	while is_transitioning():
		await get_tree().process_frame
		if session != _session_serial:
			return ERR_UNCONFIGURED
	return OK


# 仅工作线程或初始化只读查询调用；不从这里访问场景或发送信号。
func _execute_bridge(executable: String, command: String, native_handle: int, process_id: int) -> Dictionary:
	var output: Array = []
	var exit_code: int = OS.execute(executable, PackedStringArray([command, str(native_handle), str(process_id)]), output, true, false)
	var captured: String = ""
	for part in output:
		captured += str(part)
	return {"exit_code": exit_code, "output": captured.strip_edges()}


# 同时核对退出码、协议与真实窗口归属；原生失败不得伪装成成功的视觉状态。
func _accept_bridge_result(command: String, response: Dictionary) -> Error:
	var parser := JSON.new()
	if parser.parse(String(response.output)) != OK or not parser.data is Dictionary:
		return _fail("窗口辅助程序未返回有效 JSON，退出码 %d：%s" % [int(response.exit_code), String(response.output)], ERR_INVALID_DATA)
	var data: Dictionary = parser.data
	if not data.has_all(["ok", "command", "hwnd", "pid", "verified", "visible", "minimized", "message"]):
		return _fail("窗口辅助程序返回字段不完整。", ERR_INVALID_DATA)
	if not data.ok is bool or not data.verified is bool or not data.visible is bool or not data.minimized is bool or not data.message is String:
		return _fail("窗口辅助程序返回的状态字段类型不正确。", ERR_INVALID_DATA)
	if data.command != command or data.hwnd != str(_native_window_handle):
		return _fail("窗口辅助程序返回了不匹配的命令或 HWND。", ERR_INVALID_DATA)
	var valid_owner: bool = (data.pid is int or data.pid is float) and data.pid == OS.get_process_id()
	if data.verified and valid_owner:
		hidden_to_tray = not data.visible
	if int(response.exit_code) != 0 or not data.ok:
		return _fail("Windows 窗口命令 %s 失败，退出码 %d：%s" % [command, int(response.exit_code), String(data.message)], ERR_CANT_RESOLVE)
	if not data.verified or not valid_owner:
		return _fail("窗口辅助程序未验证游戏窗口的真实进程归属。", ERR_INVALID_DATA)
	if command == "hide" and data.visible:
		return _fail("窗口辅助程序没有确认窗口已实际隐藏。", ERR_CANT_RESOLVE)
	if command == "restore" and (not data.visible or data.minimized):
		return _fail("窗口辅助程序没有确认窗口已显示并解除最小化。", ERR_CANT_RESOLVE)
	error_message = ""
	return OK


# 由标题区的鼠标按下调用原生拖动，按钮不应连接此入口。
func start_drag() -> void:
	if not _initialized:
		_fail("桌面窗口尚未初始化，不能拖动。", ERR_UNCONFIGURED)
		return
	_window.start_drag()


# 像素倍数只接受当前界面支持的 1 倍和 2 倍，实际排版由主界面响应信号完成。
func request_zoom(scale: int) -> void:
	if not _initialized or scale not in [1, 2]:
		_fail("桌面窗口尚未初始化，或像素倍数不是 1/2。", ERR_INVALID_PARAMETER)
		return
	pixel_scale = scale
	_sync_menu_checks()
	zoom_requested.emit(scale)
	persist_preferences()


# 真实退出前可显式检查此结果；使用临时文件替换，失败时保留可见窗口及完整错误。
func persist_preferences() -> Error:
	if not _initialized or not _layout_initialized:
		return _fail("桌面窗口尚未完成初始化与排版，不能保存窗口偏好。", ERR_UNCONFIGURED)
	_saved_anchor = _window.position + _window.size
	_has_saved_anchor = true
	var snapshot: Dictionary = {
		"settings_version": SETTINGS_VERSION,
		"bottom_right": {"x": _saved_anchor.x, "y": _saved_anchor.y},
		"pixel_scale": pixel_scale,
		"pinned": pinned,
	}
	var destination: String = ProjectSettings.globalize_path(preferences_path)
	var result: Error = DirAccess.make_dir_recursive_absolute(destination.get_base_dir())
	if result != OK:
		return _fail("无法创建窗口偏好目录，错误码 %d。" % result, result)
	var temporary_path: String = destination + ".tmp"
	var file: FileAccess = FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		return _fail("无法写入窗口偏好：%s，错误码 %d。" % [preferences_path, FileAccess.get_open_error()], FileAccess.get_open_error())
	file.store_string(JSON.stringify(snapshot, "\t"))
	file.flush()
	result = file.get_error()
	file.close()
	if result != OK:
		return _fail("窗口偏好写入失败，错误码 %d。" % result, result)
	result = DirAccess.rename_absolute(temporary_path, destination)
	if result != OK:
		return _fail("无法替换窗口偏好，错误码 %d。" % result, result)
	_position_save_elapsed = -1.0
	return OK


# 真正退出时释放托盘和菜单；此入口不保存文件，调用方应先完成所有可失败的保存。
func shutdown() -> void:
	set_process(false)
	_initialized = false
	_session_serial += 1
	# 主界面应先等操作结束再退出；仍有线程时也必须回收，不能留下后台线程或辅助进程。
	if _bridge_thread != null and _bridge_thread.is_started():
		_bridge_thread.wait_to_finish()
	_bridge_thread = null
	_native_operation = ""
	if _status_indicator >= 0:
		DisplayServer.delete_status_indicator(_status_indicator)
		_status_indicator = -1
	if _tray_menu.is_valid():
		NativeMenu.free_menu(_tray_menu)
		_tray_menu = RID()
	_window = null
	_tray_icon = null
	_pin_menu_index = -1
	_one_x_menu_index = -1
	_two_x_menu_index = -1
	_layout_initialized = false
	_bridge_executable_path = ""
	_native_window_handle = 0
	hidden_to_tray = false
	pixel_scale = 1
	pinned = true
	preferences_path = DEFAULT_PREFERENCES_PATH
	_saved_anchor = Vector2i.ZERO
	_has_saved_anchor = false
	_observed_position = Vector2i.ZERO
	_position_save_elapsed = -1.0
	error_message = ""


# 原生拖动结束后短暂等待位置稳定再落盘，避免拖动期间逐帧写磁盘。
func _process(delta: float) -> void:
	if not _initialized or not _layout_initialized:
		return
	if _window.position != _observed_position:
		_observed_position = _window.position
		_position_save_elapsed = 0.0
	elif _position_save_elapsed >= 0.0:
		_position_save_elapsed += delta
		if _position_save_elapsed >= 0.35:
			# 保存失败只报告一次，由主界面展示并处理，不自动重试或吞掉错误。
			_position_save_elapsed = -1.0
			persist_preferences()


# 未找到文件表示首次运行；已有偏好损坏时明确失败，不偷偷使用默认窗口状态。
func _load_preferences() -> Error:
	if not FileAccess.file_exists(preferences_path):
		return OK
	var file: FileAccess = FileAccess.open(preferences_path, FileAccess.READ)
	if file == null:
		return _fail("无法读取窗口偏好：%s。" % preferences_path, FileAccess.get_open_error())
	var parser := JSON.new()
	var result: Error = parser.parse(file.get_as_text())
	file.close()
	if result != OK or not parser.data is Dictionary:
		return _fail("窗口偏好 JSON 格式错误：%s。" % preferences_path, ERR_FILE_CORRUPT)
	var data: Dictionary = parser.data
	if not data.has_all(["settings_version", "bottom_right", "pixel_scale", "pinned"]) or data.settings_version != SETTINGS_VERSION:
		return _fail("窗口偏好版本或必需字段不正确。", ERR_FILE_CORRUPT)
	# Godot JSON 会将数值解析为 float；不能用整数数组成员比较误拒绝自己保存的 1/2 倍。
	var valid_scale: bool = (data.pixel_scale is int or data.pixel_scale is float) and (data.pixel_scale == 1.0 or data.pixel_scale == 2.0)
	if not valid_scale or not data.pinned is bool or not data.bottom_right is Dictionary or not data.bottom_right.has_all(["x", "y"]):
		return _fail("窗口偏好的倍数、置顶或位置字段不正确。", ERR_FILE_CORRUPT)
	for coordinate in [data.bottom_right.x, data.bottom_right.y]:
		if not (coordinate is int or coordinate is float) or not is_finite(float(coordinate)) or float(coordinate) != floorf(float(coordinate)):
			return _fail("窗口偏好坐标必须是有限整数。", ERR_FILE_CORRUPT)
	pixel_scale = int(data.pixel_scale)
	pinned = data.pinned
	_saved_anchor = Vector2i(int(data.bottom_right.x), int(data.bottom_right.y))
	_has_saved_anchor = true
	return OK


# 使用真实角色图生成等比托盘图标，并创建 Windows 原生菜单与状态图标。
func _create_tray() -> Error:
	var source: Texture2D = load(TRAY_ICON_PATH)
	if source == null:
		return _fail("无法载入托盘角色图标：%s。" % TRAY_ICON_PATH, ERR_FILE_NOT_FOUND)
	var source_image: Image = source.get_image()
	var edge: int = maxi(source_image.get_width(), source_image.get_height())
	var square := Image.create(edge, edge, false, Image.FORMAT_RGBA8)
	square.fill(Color.TRANSPARENT)
	square.blit_rect(source_image, Rect2i(Vector2i.ZERO, source_image.get_size()), Vector2i((edge - source_image.get_width()) / 2, (edge - source_image.get_height()) / 2))
	square.resize(32, 32, Image.INTERPOLATE_NEAREST)
	_tray_icon = ImageTexture.create_from_image(square)
	_tray_menu = NativeMenu.create_menu()
	if not _tray_menu.is_valid():
		return _fail("Windows 托盘菜单创建失败。", ERR_CANT_CREATE)
	NativeMenu.add_item(_tray_menu, "显示教室", _on_menu_action, Callable(), "show")
	NativeMenu.add_item(_tray_menu, "收起到托盘", _on_menu_action, Callable(), "hide")
	NativeMenu.add_separator(_tray_menu)
	_pin_menu_index = NativeMenu.add_check_item(_tray_menu, "窗口置顶", _on_menu_action, Callable(), "pin")
	_one_x_menu_index = NativeMenu.add_radio_check_item(_tray_menu, "原始尺寸 1x", _on_menu_action, Callable(), "zoom_1")
	_two_x_menu_index = NativeMenu.add_radio_check_item(_tray_menu, "放大尺寸 2x", _on_menu_action, Callable(), "zoom_2")
	NativeMenu.add_separator(_tray_menu)
	NativeMenu.add_item(_tray_menu, "退出游戏", _on_menu_action, Callable(), "quit")
	_status_indicator = DisplayServer.create_status_indicator(_tray_icon, "高考冲刺七天 · 点击显示教室", _on_tray_activated)
	if _status_indicator < 0:
		NativeMenu.free_menu(_tray_menu)
		_tray_menu = RID()
		return _fail("Windows 系统托盘图标创建失败，教室窗口将保持可见。", ERR_CANT_CREATE)
	DisplayServer.status_indicator_set_menu(_status_indicator, _tray_menu)
	_sync_menu_checks()
	return OK


# 原生菜单的勾选状态只反映当前真实窗口偏好。
func _sync_menu_checks() -> void:
	NativeMenu.set_item_checked(_tray_menu, _pin_menu_index, pinned)
	NativeMenu.set_item_checked(_tray_menu, _one_x_menu_index, pixel_scale == 1)
	NativeMenu.set_item_checked(_tray_menu, _two_x_menu_index, pixel_scale == 2)


# 右键菜单由 Windows 自动展开，普通左键负责恢复可见教室。
func _on_tray_activated(button: int, _screen_position: Vector2i) -> void:
	if button == MOUSE_BUTTON_LEFT:
		restore_window()


# 菜单只分派窗口命令；退出请求交给主界面保存真实游戏数据后决定。
func _on_menu_action(command: Variant) -> void:
	match String(command):
		"show":
			restore_window()
		"hide":
			hide_to_tray()
		"pin":
			set_pinned(not pinned)
		"zoom_1":
			request_zoom(1)
		"zoom_2":
			request_zoom(2)
		"quit":
			quit_requested.emit()


# 优先使用锚点所在显示器；显示器移除后由当前工作区约束重新放置窗口。
func _screen_for_anchor(anchor: Vector2i) -> int:
	for screen in DisplayServer.get_screen_count():
		if DisplayServer.screen_get_usable_rect(screen).has_point(anchor - Vector2i.ONE):
			return screen
	return _window.current_screen


# 向调用方和日志同时暴露失败，不把偏好或系统托盘错误伪装成成功。
func _fail(message: String, code: Error) -> Error:
	error_message = message
	push_error(message)
	failure.emit(message)
	return code


# 释放场景时清理原生资源，已主动关闭的托盘不会重复删除。
func _exit_tree() -> void:
	shutdown()
