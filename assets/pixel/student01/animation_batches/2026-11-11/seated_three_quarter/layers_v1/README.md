# 东北斜后方坐姿：课桌、椅子与人物分层

日期：2026年11月11日。所有交付层均为原生64×64透明PNG，沿用批准稿的原始坐标，没有移动、缩放或镜像。正式场景和资源路由未修改。

## 文件与绘制顺序

按同一左上角`[0,0]`依次绘制：

1. `desk_back.png`：课桌、桌腿、桌面纸张。
2. `chair_base.png`：椅面、椅腿以及人物背后的椅子补全区域。
3. `character_seed.png`：原稿可见人物、双手、手持笔。
4. `chair_front.png`：原稿可见的椅背木板和前景立柱。

空座位省略第3层，或直接使用`all_furniture.png`。`reconstructed_seed.png`是上述四层重组结果，与批准稿逐像素一致。世界摆放锚点由主场景决定；分层仅记录共同画布原点，最低非透明行是`y=60`，落地参考线为`y=61`。

## 动画遮罩

| 文件 | 含义 |
| --- | --- |
| `character_visibility_mask.png` | 原稿全部可见人物，含头部最右侧轮廓与笔 |
| `character_static_body_mask.png` | 冻结头、躯干、裤腿、双脚及托纸手的区域 |
| `right_forearm_visibility_mask.png` | 持笔右前臂 |
| `writing_hand_pen_visibility_mask.png` | 持笔手与笔；纸张不在此层 |
| `writing_motion_visibility_mask.png` | 右前臂与持笔手/笔的并集 |

全部遮罩为同尺寸纯黑白RGB，无抗锯齿。精确逐行坐标记录在`mask_geometry.json`。它们描述批准关键帧的可见像素，不代表后续动画的完整运动包围盒。

人物被椅背挡住的躯干、臀部和远侧腿没有猜测补画。当前分层适用于保持身体、脚与座位固定的小幅写字动作；起身、转身或移动需要另做完整人体、家具遮挡和接触点验证。椅背前景不与原稿人物、头部或双手相交，后续动画仍需逐帧检查。

## 真实空家具来源

`inpaint_empty_raw.png`保留第一次PixelLab局部重绘的原始返回文件，任务`27b80127-5f4b-437d-ab59-477c34aa8632`，实际计费5 generations。

首次人物遮罩漏了头部右沿`(36,13)`、`(36,14)`、`(36,15)`共3像素。发现后同步修正人物和静态身体遮罩，并以`inpaint_edge_cleanup_mask.png`调用第二次真实局部重绘，任务`efdf7f09-ae99-4cd1-a17d-28693364b89e`，实际计费5 generations。原始返回保留为`inpaint_empty_refined_raw.png`；`all_furniture.png`与它字节一致。总计10 generations。

两次请求、回执和实际计费结果均保留在本目录。第一次返回稿及其`inpaint_empty_raw_12x.png`、`empty_grid_16x.png`是历史证据，最终预览和家具层采用第二次返回稿。没有在本地涂改外部模型返回图。

## 验证结果

| 检查 | 结果 |
| --- | ---: |
| 最终人物遮罩之外发生RGBA变化 | 0像素 |
| 第二次清理遮罩之外发生变化 | 0像素 |
| 人物区域恢复为家具 | 460像素 |
| 人物区域恢复为透明 | 252像素 |
| 三层家具与最终真实空座位差异 | 0像素 |
| 四层重组与批准原稿RGBA差异 | 0像素 |
| 椅背前景与原稿人物遮罩相交 | 0像素 |
| 最终透明度取值 | 0、255 |

已打开查看`comparison_1x_2x_4x.png`的原生1倍、2倍、4倍对照，以及`layer_review_4x.png`的独立图层；空桌面原有3像素头部残线已消除。桌、椅、人物和四层重组关系可读。本验证不代替后续六帧动画、四工位合成或正式运行时验收。

`layer_manifest.json`记录SHA256、真实来源、绘制顺序、分层几何、边界与定量检查。`reconstruction_diff.png`是全透明的零差异图。

## 重建

在已取得两次真实模型返回PNG的前提下，执行`build_layers.py`即可确定性重建分层、遮罩、清单与预览。脚本在越界修改、非零重组差异或前景覆盖人物时直接报错。

```powershell
& 'C:/Users/admin/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe' 'D:/挂机上课/assets/pixel/student01/animation_batches/2026-11-11/seated_three_quarter/layers_v1/build_layers.py'
```
