官方文档：https://www.shimmersensing.com/support/wireless-sensor-networks-documentation/
所需设备
硬件：采集设备（以皮电模块为例）
软件：ConsensysBASIC （用于设备识别、信号采集与保存。不能进行数据分析）

## 第一步：连接设备

将模块插入底座，连接电脑

注意模块插入方向

![[5e8d639e58d572cec011a4f6f6ac5358.jpg]]

正确插入的效果

![[09cdba0f4dbade17f2f2c16a396e1f01.jpg]]

打开模块侧边的开关

![[Screenshot 2025-06-09 at 15.46.03.png]]
## 第二步：配置软件

Connsensys 
系统：只能安装于Win系统
版本：只有BASIC版本（PRO版本可同步记录多个模块、标记数据上下文、数据转换等）
输入：需要连接设备、蓝牙
环境：在软件内更新framware
配置：软件内选择GSR 传感器
数据精度：可调整采样率
步骤结束标志：显示Logging Data页面，点击Finish后。

## 第三步：记录数据

连接蓝牙：必须搜索并连接到shimmer3-A863后面带有序号的设备，SHIMMER USB READER不可以。添加shimmer3-A863 时要求PIN：1234
准备记录：在LIVE DATA标签窗口
- 左侧列表选择要记录的数据
- 依次点击蓝牙、运行两个按钮
佩戴设备：
- 取下模块
- 佩戴传感器

![[Screenshot 2025-06-09 at 15.56.03.png]]

- 将模块装入碗带卡扣中
![[Screenshot 2025-06-09 at 15.54.49.png]]

- 佩戴完成

![[d6c9879ee02a3e3da7378fe7a8720e49.jpg]]

软件端操作

- 右侧观察数据曲线
- 可添加新曲线窗口，每个窗口对应一条数据
- 右键可编辑显示窗口
- 开始记录与结束记录：START TO PC、STOP TO PC 开始记录和结束记录。数据将保存在本地电脑中
- 停止采集：点击停止按钮、关闭蓝牙
- 保存数据：进入MATEDATA标签窗口，更新当前项目数据，选择相应数据下载保存。可保存为csv。

## 采集完毕