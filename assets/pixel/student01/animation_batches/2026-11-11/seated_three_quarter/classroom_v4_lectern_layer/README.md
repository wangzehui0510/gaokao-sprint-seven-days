# 讲桌独立层与无残影背景

2026年11月12日，针对 v3 教室中讲桌残影问题，将讲桌从教室背景拆成独立透明场景层，并重新生成关闭讲桌层的背景。

## 查看

- `classroom_clean_no_lectern.png`：关闭 `lectern` 层后的背景。
- `lectern_layer.png`：独立透明讲桌层。
- `lectern_cutout.png`：讲桌裁片预览。
- `classroom_recomposed_lectern_layer.png`：背景重新叠加讲桌后的还原图。
- `classroom_four_students_2x.png`、`classroom_four_desks_2x.png`：四工位检查图。
- `scene_manifest.json`：场景层顺序、四工位和老师预留位置。
- `build_checks.json`、`FINAL_QA.md`、`acceptance.json`：像素检查和目检结果。

## 结果

讲桌层画布为 384×256，透明可见像素 1684，边界为 `[215,84,269,134]`。关闭讲桌层时，平台、墙面和黑板下沿连续，没有桌面、桌腿或棕色残影；重新叠加后与 v3 来源场景 RGBA 差异为 0 像素。

讲桌按三块木色区域提取：桌面、左前脸、右前脸。平台、墙边和老师预留区不作为讲桌层内容。场景仍使用 v3 的固定 384×256 坐标，老师预留矩形为 `[236,78,40,56]`，脚点为 `[260,126]`。

## 来源与修复

第一次 PixelLab `inpaint_image_pro_flash` 清理任务为 `5eefbdc3-d4ef-40ed-ae45-fbccaa689120`，费用 6 generations。后续局部修复任务 `3f073e50-a656-4dc7-ac50-4bcc0a8a5e5e`（Pro Flash，6 generations）和 `ea20a7a0-7147-46d7-83e2-13ffeab80f3c`（标准局部重绘，10 generations）均保留在目录中。最终采用标准局部重绘结果，再对 35 个已定位残色像素沿相邻墙面/平台纹理做确定性修复；没有用旧缓存或默认图替代失败结果。

## 限制

本轮只完成素材拆层和静态预览，没有切换正式游戏；教师精灵和教师动画仍未制作。讲桌层绑定当前 384×256 场景坐标，不能直接作为自由移动物体使用。
