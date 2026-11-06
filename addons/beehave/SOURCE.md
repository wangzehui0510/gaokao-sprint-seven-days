# 第三方来源

- 项目：Beehave（bitbrain/beehave）
- 固定版本：v2.9.3
- 许可证：MIT，见本目录`LICENSE`。
- 来源归档：`https://github.com/bitbrain/beehave/archive/refs/tags/v2.9.3.zip`
- 引入日期：2026-11-06。

除下述兼容补丁外，本目录第三方脚本保持上游原样；本游戏的共享行为树和中文业务注释放在`res://scripts/ai/`。

## 本地兼容补丁

Godot 4.7.2独立运行或无头测试时，上游调试代码仅根据editor特性决定发送消息，会产生`No active debugger`，无活动调试器时注册捕获还会在退出时产生`Capture not registered`。

- `debug/debugger_messages.gd`：发送前要求`EngineDebugger.is_active()`。
- `debug/global_debugger.gd`：仅在调试会话中注册消息捕获。

补丁只约束调试通道的生命周期，不改变行为树选择、动作执行或游戏状态。
