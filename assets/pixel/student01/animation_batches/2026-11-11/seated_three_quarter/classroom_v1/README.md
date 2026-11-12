# 斜后方视角教室制作

用户已于2026年11月11日采用3/4关键帧，要求写字动画与桌椅分层，并进一步要求按桌椅角度重新生成教室、摆入四套桌椅。

当前制作目标：384×256的无人物、无桌椅教室背景；以独立图层摆入四套64×64家具；保留原生像素与1倍/2倍显示。黑板位于右后墙，四套工位均朝东北，与批准关键帧方向一致。工位按近似2:1的斜轴排列，不把源桌面称为数学上严格的等轴投影。

本目录是制作资产与预览，正式课堂的其他行为、教师、命中区域和双人布局尚需统一适配。禁止直接把该背景替换进旧视图后宣称全部新视角接入已完成。

## 最终文件

- `classroom_empty.png`：真实生成的384×256空教室，无桌椅或人物。
- `classroom_four_desks_1x.png`、`classroom_four_desks_2x.png`：四套分层空桌椅的完整场景。
- `classroom_four_students_1x.png`、`classroom_four_students_2x.png`：四个固定坐姿的合成预览。
- `classroom_writing_2x.gif`：六帧循环；真实逐帧PNG另存于`composed_frames/`。
- `layer_breakdown.png`：家具、人物与前景椅背的图层对照。
- `scene_manifest.json`：图层顺序、实际PNG、帧时长、四工位坐标的引擎输入。
- `build_checks.json`：来源摘要、批准首帧精确重建与画布/位置检查结果。

背景与桌椅分别保存，场景图由独立图层重建。工位64×64画布左上角为`[160,63]`、`[72,107]`、`[248,107]`、`[160,151]`，均面向右后墙黑板；四画布不重叠，人物脚与椅腿保持同一原点。`room_geometry_reference.png`只用于生成构图参考，不能当作最终背景。

独立Godot GPU检查读取同一个清单，不加载正式游戏autoload或存档。最终检查状态见上级`FINAL_QA.md`与本机`.artifacts/seated_three_quarter_qa/FINAL_QA.md`。
