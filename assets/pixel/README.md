# 首批复古像素素材

采用斜俯视正交视角，原生网格16×16像素。角色32×48透明画布，南向可见高度40像素，脚底锚点(16,44)。教室384×256，北墙48像素，四张课桌按两列两排布置。

## 直接查看

- `previews/classroom_with_student_3x.png`：单名学生与教室的比例预览。
- `previews/student01_directions_6x.png`：同一学生的南、东、北、西方向。
- `classroom/classroom.aseprite`：分层教室源文件。
- `student01/student01.aseprite`：四方向角色源文件。

全部预览采用整数倍最近邻放大，接入使用原生PNG。角色当前为站姿，坐姿、学习、趴桌等状态另行制作。

## 目录

- `student01/`：角色四方向、原始参考、Aseprite源文件和像素修正记录。
- `classroom/`：完整教室、无桌椅背景、各桌主体、独立椅子、局部遮挡与布局数据。
- `reference/classroom_pixellab.png`：PixelLab教室草稿；因课桌数量和透视偏离要求，留作生成记录。
- `previews/`：比例和朝向检查图。
- `validation.json`：图片的真实尺寸、轮廓和SHA-256摘要。

## 接入约定

教室拆分PNG均为384×256透明画布，图片左上角对应房间(0,0)。桌、椅与角色分别按各自地面脚点排序；每桌局部前景只用于真正需要遮挡的角色区域。不可把整张前景统一盖在全部人物上。

`classroom/layout.json`记录桌位、门口、脚点、推荐出生点和碰撞参考。主走道留白供角色移动及互动表现使用。完整尺寸说明见项目`docs/像素美术规范_v0.1.md`。

## 生成记录

首名学生原图使用PixelLab Pro Flash生成，种子261106，原图轮廓20×44像素。随后在Aseprite按明确记录删除4行衣服和裤子像素，保留头脸和鞋，规范为南向20×40像素。四方向使用PixelLab V3参考旋转，角色ID为`a8e45275-522e-4afa-ac11-e00c05c684a8`。

教室首先尝试PixelLab Pixen，种子261106；草稿出现8张课桌及透视变化，最终教室由真实Aseprite Lua按固定像素坐标绘制。绘制脚本为`tools/draw_classroom.lua`。源文件可直接在Aseprite继续编辑。
