# 平台贴墙与讲桌后方站位

2026年11月12日，根据用户反馈调整讲台版：矮平台后沿接到黑板下方墙边，讲桌向学生侧前移，讲桌与墙之间保留连续平台区域，供老师站在讲桌后方。

## 查看

- `classroom_four_students_2x.png`：贴墙平台、前移讲桌和四套学生桌椅。
- `classroom_four_desks_2x.png`：关闭人物后的空桌椅检查图。
- `classroom_writing_2x.gif`：沿用六帧写字循环。
- `teacher_behind_lectern_layout_3x.png`：老师后方预留画布标注图；紫框和圆点不在正式背景中。
- `classroom_with_wall_connected_podium.png`：384×256原生场景背景。
- `wall_connected_podium_overlay.png`：与v2背景原点绑定的透明覆盖层。
- `scene_manifest.json`、`build_checks.json`：本轮几何、来源和像素检查。
- `FINAL_QA.md`、`acceptance.json`、`gpu_final_result.json`：独立Windows GPU验收结果。

## 几何调整

平台后沿为`[[199,76],[326,140]]`，贴合黑板下方的墙面投影；平台前沿为`[[181,101],[287,160]]`，前沿高4像素。讲桌桌面改为`[[232,92],[260,106],[242,115],[214,101]]`，整体画布`[214,92,47,43]`，向学生侧前移。老师预留矩形为`[236,78,40,56]`，脚点`[260,126]`，位置定义为`behind_lectern`。老师预留框可以与讲桌画布重叠，因为未来教师会在讲桌后方绘制并由讲桌遮挡下半身。

四套64×64工位仍为`[124,93]`、`[60,125]`、`[208,135]`、`[144,167]`。平台改动区域与四个工位实际可见像素相交为0，学生桌椅保持原有遮挡和动画。

## PixelLab来源

本轮使用PixelLab `edit_image`任务`14c5fa5a-9f46-4536-a27f-4f70fd6aa549`，费用10 generations。先由`prepare_wall_connection.py`生成`wall_connection_volume_guide.png`作为体块引导，再编辑当前v2讲台裁片。完整返回保存为`generated_crop_raw.png`；由于整张编辑可能改变mask外区域，构建脚本只采用新mask内真实返回像素，mask外恢复v2背景，输出`adopted_crop.png`。不把引导图或整张原稿冒充最终素材。

## 验收结果

独立Godot工程`.artifacts/podium_wall_qa/`实际运行158页（156普通页＋2几何页），649项检查0失败；156张普通页与CPU合成逐像素一致，78组1倍/2倍最近邻一致，24个工位帧碰撞检查为0。Windows Intel UHD Graphics 770实际GPU退出0，stderr为空。平台后沿采样200点全部命中场景改动和mask，确认平台已连接墙边。该结果只覆盖冻结美术预览。

## 适用范围

本轮只调整美术布局和老师预留位置，没有生成教师精灵或教师动画，也没有切换正式游戏。`wall_connected_podium_overlay.png`包含局部地面和墙边修补，与v2背景画布坐标绑定，不能自由移动。四人仍共用学生01外观和六帧固定坐姿写字动作；起立、移动、转身、巡堂路径和正式资源索引仍需后续适配。
