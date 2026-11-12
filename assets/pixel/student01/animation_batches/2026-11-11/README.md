# 学生01共用动作样片 · 2026年11月11日

本轮使用 PixelLab MCP 分批生成与修订，围绕现有学生01制作，整理出32组、178帧，覆盖A01～A13与B01～B04共17个动作族。这里是素材样片库，未接入正式游戏，也不代表全部60项行为的道具、方向和双人演出均已完成。

用户已确认：Steam电脑挂机游戏；游戏动作操作电脑键鼠；体育、做操、健身与操场活动共用徒手伸展和踏步；洗漱使用洗手台洗脸。

## 查看

- `review.html`：离线交互预览，包含全部真实PNG；支持播放、暂停、逐帧、速度、倍率、脚锚点和动作筛选。
- `overview.png`：32组首帧总览。
- `highlights.gif`：6组代表动作的动态预览；PNG原帧是实际素材，GIF仅作展示。
- `writing_back_comparison.gif`与同名PNG：写字衣背修订前后同步对比，下方按同一真实教室工位显示。修订后的六帧已替换预览中的A01，原稿保留。
- `review_curated/<动作ID>/`：透明横条 `strip.png`、逐帧表、GIF与指标。
- `FINAL_QA.md`：人工与独立Godot GPU验收结果、已通过范围及未完成部分。
- `paired_review/review.html`与`paired_review/review/`：掰手腕、挥枕头、递接的双人站位检查。枕头展示32像素脚点距的轻触参考；递接页是明确的待补道具反例，不代表完成交接。

## 批次与交付范围

| 批次 | 内容 | 组数 |
| --- | --- | ---: |
| 课堂主体 | 写字、阅读、转笔、坐姿放松、站姿待机、趴睡、眼操 | 7 |
| 生活活动 | 卧床、餐食/零食/糖、左右电脑、伸展、踏步、扫地、洗脸 | 10 |
| 双人主动作 | 左右掰手腕僵持、左右挥枕头 | 4 |
| 短动作 | 递书、左右接取、示意、举手、纸条抛出、弹指、三种反应、趴睡醒来 | 11 |

每组具体帧序、毫秒时长、循环方式、画布、锚点和验收状态以 `curated_manifest.json` 为准。`loop=false` 的短动作播放结束后保持末帧，不自行重复触发业务事件。

## 来源与修订

`production_log.json` 保存72个已完成MCP任务，包括关键姿态、动画初稿、整段修订及返工，不等于72组可用动画。`raw_review_manifest.json` 保存43组动画生成稿、269帧；所有原始PNG均保留在 `raw/`。32组整理稿来自29组原始动画，另有3组镜像派生。

`curation.json` 为可复现的人工决定；`curation_provenance.json` 记录每帧源路径、源序号、原始/输出摘要及操作。采用边界：

- 去掉循环中的多余重复端点，或按短动作节奏选帧；原始帧不删除。
- 用户指出A01背部过于方形后，使用PixelLab `edit_animation`整段修改六帧，采用斜肩、收腰、衣褶与蓝色侧缝，去除方形背板的感觉。新原稿为`A01_write_north_v2`；其他背面动作暂保留各自原稿，未批量改服装。
- A01新原稿首帧缺一条斜褶，显式从源第1号帧复制`[14,32,20,35]`到输出第0帧，只补8个衣褶像素以消除循环闪褶；操作记录在`copy_regions`。AI整段修改也重采样了角色配色与局部轮廓，不宣称手脚原像素完全不变；六帧脚点与落地像素位置保持稳定。
- 用户随后指出首帧缺领口：已从同一源第1号帧复制`[12,25,21,27]`到输出第0帧，只补18个领口像素。相对上一版，alpha、已有衣褶和其余177帧逐字节不变；六帧均有连续蓝色领口，预览与动图已同步重建。
- 卧床采用前4帧，排除床头缺一行的第4号源帧。
- 北向眼操按脚底实测左移3、下移2像素；未拉伸或缩放。
- 掰手腕右向、挥枕头左向、接取左手由对应样片围绕画布中线镜像；锚点使用画布边界坐标，例如宽64时中线x32。
- 弹指稿清除头顶 `[0,0,64,11]` 中的附加魔法气泡，保留角色像素；具体差异在最终检查报告核验。
- 趴睡允许头部随呼吸起伏1像素，前额始终贴合前臂。生成提示里的绝对静止不当作用户额外要求。

## 接入边界

普通32×48帧脚锚点为`[16,44]`；加透明边的64×48帧为`[32,44]`。卧床为64×64、暂定家具锚点`[32,48]`，需要单独适配床位。这里保存的是完整合成PNG，已含手部，不再重复叠加旧hands层。

电脑、洗手台、床包含家具，需要与正式场景的工位及遮挡统一。掰手腕只验收僵持循环，不增加胜负动画或业务结算；配对桌面为检查用矩形参考，真实桌面遮挡另验。挥枕头单人挥动通过，40像素脚点距打空，32像素仅为轻触/擦边参考，明确双人互击演出仍待完善。

递出、接取手势不等于完整交接：书本在双方之间的独立道具层与接触时序仍需补做；纸条与橡皮跨工位的飞行、送达/受击必须服从真实执行器。现有B02为示意和举手，击掌/拍肩等特殊接触手位尚未单独交付。教师与其他学生外观、新增方向、起坐转身行走、物品/状态图标也未计入本轮。

父目录 `.gdignore` 保持本批草稿与预览不被正式工程批量导入；接入时将已验收素材移入正式目录并维护资源索引。不要把全部raw或失败试验直接导入。

## 重建

在仓库根目录使用本机Python和Pillow运行，按顺序执行：

```powershell
python tools/collect_pixel_batch.py --log assets/pixel/student01/animation_batches/2026-11-11/production_log.json
python tools/curate_pixel_animations.py --plan assets/pixel/student01/animation_batches/2026-11-11/curation.json
python tools/review_pixel_animations.py --manifest assets/pixel/student01/animation_batches/2026-11-11/curated_manifest.json --output-dir assets/pixel/student01/animation_batches/2026-11-11/review_curated
python tools/build_animation_review.py --manifest assets/pixel/student01/animation_batches/2026-11-11/curated_manifest.json
python tools/compose_animation_pairs.py --plan assets/pixel/student01/animation_batches/2026-11-11/pairs_plan.json
python tools/build_animation_review.py --manifest assets/pixel/student01/animation_batches/2026-11-11/paired_review/pairs_manifest.json
python tools/make_animation_highlights.py --manifest assets/pixel/student01/animation_batches/2026-11-11/curated_manifest.json
```

工具不会自动批准素材。修改任何帧序、像素、时长或站位后，重新目检和GPU检查。独立Godot检查方法与本机证据见仓库 `.artifacts/gpu_animation_qa/README.md`；该目录是本地检查产物，换机不能依赖旧截图判定新素材通过。
