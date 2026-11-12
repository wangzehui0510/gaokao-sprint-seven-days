# 动画人工整理工具

读取批次目录的 `curation.json` 与 `raw_review_manifest.json`，执行逐项写明的选帧、局部复制、清除附加特效、固定区域、水平镜像及整数归位。工具不判断动作质量，不改原始生成稿，不接入正式游戏。

```powershell
& 'C:/Users/admin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe' tools/curate_pixel_animations.py --plan assets/pixel/student01/animation_batches/2026-11-11/curation.json
```

每项必填 `id`、`label`、`source_clip_id`、`selected_indexes`、`direction`、`duration_ms`、`loop`、`review_status`。`selected_indexes` 为源清单的零起始帧索引，按声明顺序导出。时长可为统一毫秒数或与输出帧数等长的数组。画布沿用原图，不缩放或插帧。

可选操作按以下顺序执行：

1. `lock_regions`：将源第0帧的指定矩形覆盖到每个输出帧。
2. `copy_regions`：列表中的每项用`source_index`指定零起始源帧、`target_frames`指定零起始输出帧列表、`region`指定矩形；在原坐标覆盖已目检的局部。例如`{"source_index":1,"target_frames":[0],"region":[14,32,20,35]}`只给首帧补衣褶，原始帧不变。
3. `clear_regions`：将人工圈定矩形清为透明，仅用于已目检确认的多余特效。
4. `mirror_horizontal`：围绕画布中线水平镜像；锚点按画布边界坐标填写，例如宽64时中线为x32。
5. `translate`：整数 `[dx,dy]` 位移；会裁掉可见像素时明确报错。

矩形均为 `[左,上,右,下]`，包含左上、不包含右下。可选 `anchor`、`notes` 记录归位后的锚点与采用边界。所有修订必须重新目检，锁区不能自动消除接缝或保证动作成立。

输出 `curated/<id>/frame_XX.png`、`curated_manifest.json`、`curation_provenance.json`。来源记录包含每帧原始路径、源帧序号、源PNG摘要、输出PNG摘要以及完整人工操作。预览另外使用 `review_pixel_animations.py` 与 `build_animation_review.py` 生成。
