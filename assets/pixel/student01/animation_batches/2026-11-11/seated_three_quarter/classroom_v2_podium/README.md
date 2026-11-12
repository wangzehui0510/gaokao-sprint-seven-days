# 讲台、讲桌与老师预留区

2026年11月11日。用户确认采用“矮平台＋讲桌，老师站桌旁”，并允许将四套学生桌椅后移，留出前排通道。本目录是同角度教室的第二版美术预览；正式游戏仍使用原有资源与视角。

## 查看

- `classroom_four_students_2x.png`：讲台、讲桌与四个学生的完整场景。
- `classroom_four_desks_2x.png`：关闭人物后的四套空桌椅。
- `classroom_writing_2x.gif`：沿用六帧写字循环，完整周期1100毫秒。
- `teacher_reserve_layout_3x.png`：单独标注老师预留画布与脚点；正式背景不含框线。
- `classroom_with_podium.png`：384×256原生教室背景，已含讲台和讲桌。
- `podium_overlay.png`：与原教室共用画布原点的透明覆盖层，可供引擎按层开关。
- `scene_manifest.json`：最终图层顺序、工位位置、逐帧时长与绝对PNG路径。
- `FINAL_QA.md`与`acceptance.json`：最终GPU检查及独立目检结果，生成素材本身不等于验收通过。

## 位置与图层

原生场景384×256，保留门窗、黑板和原教室地砖。平台设计顶面为`[[211,83],[317,136],[287,151],[181,98]]`，高4像素；讲桌设计画布为`[222,84,47,43]`，桌面抬高19像素，木前脸朝西南。模型按体块引导细化像素，几何字段表示设计占位与验收边界，不把生成细节声称为严格数学模型。

老师站讲桌右侧，预留矩形`[272,80,40,56]`，脚点`[292,132]`，面朝西南。此范围包含未来老师整张精灵的画布空间；本轮没有生成新教师或教师动作。四套64×64工位左上角为`[124,93]`、`[60,125]`、`[208,135]`、`[144,167]`，完整画布互不相交，也不占用老师预留框。中央和讲台前方留有通道，后排外缘只有边缘余量，不宣称已经具备完整巡堂动线。

绘制顺序为原教室`room`→`podium_overlay`→各工位`desk_back`→`chair_base`→`student`→`chair_front`。桌椅及六帧写字全部读取前一版已冻结PNG，本轮未重做角色。纸归桌层、笔归人物层，前景椅背继续遮住下背。

覆盖层包含真实重绘的讲台、讲桌及局部地面，绑定`classroom_v1/classroom_empty.png`的384×256原点；它不是可自由移动的纯讲桌或纯平台cutout，不能独立移位。覆盖层与原背景可0像素差异重组为`classroom_with_podium.png`。

## PixelLab来源与采用

第一次`inpaint_image_pro_flash`任务`53e66ddb-03b9-4cee-aa70-e63a22be7870`，费用6 generations。mask外实际未变，但讲桌缺失、局部地砖模糊且有错误墙色，人工检查拒绝；完整原稿、回执与当时临时预览均留在`rejected_attempt_01/`，拒绝原因另见`attempt_01_rejection.json`。该次像素保存正确不等于内容可采用。

第二次先按明确几何制作`volume_guide_crop.png`体块引导，再使用PixelLab MCP `edit_image`任务`eaf3b135-3183-4dec-b4c7-eab96648f2f0`细化成品，费用10 generations。`generated_crop_raw.png`保留完整160×128返回原稿，未经涂改。`edit_image`会改变整张裁片，因此构建时显式仅采用白mask内的真实返回像素，mask外恢复冻结原教室，输出`adopted_crop.png`；没有将原稿的外部漂移伪称为像素不变。所有采用像素直接来自第二次返回，未以体块引导冒充生成结果。

两次实际合计16 generations。英文最终提示、输入裁片、原始回执、实际扣费分别见`generation_request.json`、`source_crop.png`、`generation_submission.json`和`generation_completed.json`。输入与输出摘要、完整原稿mask外变化数、采用后mask外变化数均在`build_checks.json`。

## 重建与适用边界

使用带Pillow与NumPy的Python执行`build_podium_preview.py`。它显式读取本目录真实原稿、mask和几何，同时核对前版家具与人物来源摘要；不会自动改用其他批次、缩放画布或吞掉错误。输入裁片与mask由`prepare_podium.py`准备；第二次体块引导由`prepare_volume_guide.py`构建。重新生成素材或改变位置后必须重新进行GPU与目检，不能沿用当前检查结论。

本轮只制作资产、布局和隔离预览。四人仍共用学生01外观与动作相位，人物是固定坐姿的可见切片；教师动作、起坐移动、其他行为、双人布局、命中区域及正式资源切换尚待适配。父级`.gdignore`继续隔离制作目录；未修改玩法、权威配置、存档或正式游戏进程。
