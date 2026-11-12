# 3/4视角写字循环

`raw/frame_00.png`至`frame_06.png`为同一次PixelLab真实整段输出，原稿保持不变。任务`51e7f97e-e979-4fa1-9f82-f375d5a9bc3d`、种子`2026111152`、费用1 generation，原始请求与回执见`production_log.json`。

原稿中有头部和脚部漂移，最终仅采用源`0,6,4,2,4,6`的右前臂、手、笔。`curated/frame_00.png`至`frame_05.png`是64×64透明人物层；同目录的`arm_*`是动作局部，`character_body_fixed.png`为固定身体。合成只使用完整人物帧，不应再次叠加arm。

时长依次为280、150、160、200、160、150毫秒，循环1100毫秒。首帧与批准人物层完全一致，头部、领口、臀腿、脚和家具固定；每帧相对首帧变化0、4、68、82、68、4像素。近侧椅背绘制于人物之后。纸张始终归桌层，笔归人物层。

`build_animation.py`保留全部局部采用规则；`motion_masks/`为每个采用源的精确动作mask，`motion_union_mask.png`为允许变化区域。`curation.json`记录源序号、原稿/输出摘要、静态身体依赖、两像素身侧连接和显式局部调色映射。它不会覆盖原稿，也不会通过移动全身来补偿AI漂移。

`curated_contact.png`与`writing_preview.gif`供美术查看。引擎和四工位检查结论见上一级`FINAL_QA.md`；本目录的合成动图本身不构成正式游戏接入验收。
