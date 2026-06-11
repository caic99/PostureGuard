# PostureGuard 坐姿卫士

[![CI](https://github.com/caic99/PostureGuard/actions/workflows/ci.yml/badge.svg)](https://github.com/caic99/PostureGuard/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/caic99/PostureGuard)](https://github.com/caic99/PostureGuard/releases)

[English](README.md) | **中文**

macOS 菜单栏小工具：**屏幕开合角度 + 人脸朝向** 推算真实低头角度，低头过久时提醒你坐直。

## 原理

```
                 摄像头光轴
                ↗ (随屏幕后仰抬高 lid−90°)
       ▢ 屏幕
      ╱ 盖角 lid (隐藏 HID 传感器)
 ▁▁▁▁╱▁▁▁▁ 底座

真实头部俯仰(以水平面为参考, 正=抬头)
  = pitchSign × Vision人脸俯仰(相对相机) + (盖角 − 90°)
```

1. **盖角**：Apple Silicon MacBook 内置一颗隐藏的合页角度传感器（HID Sensor
   page `0x20` / usage `0x8A`）。读 feature report ID 1，得到小端 `UInt16`，
   单位为度（0≈合盖，90=屏幕竖直，180=摊平）。无需任何特殊权限。
2. **人脸俯仰**：AVFoundation 以 VGA 低分辨率采集内置摄像头，每 0.5s 一帧跑
   Vision `VNDetectFaceRectanglesRequest`，取 `VNFaceObservation.pitch`
   （macOS 12+，revision 3）。画面只在内存中实时分析，不落盘、不上传。
3. **合成**：人脸俯仰是相对相机的；屏幕后仰会让相机抬高 `lid−90°`，补偿之后
   得到以水平面为参考的真实头部俯仰。因此**调整屏幕开合角度不会造成误报，也不用
   重新校准**。
4. **间歇检测（省电）**：摄像头不常开——默认每 3 分钟唤醒一次，采样 8 秒取
   中位数后立即关闭，平时只剩一个定时器，功耗≈0（实测空闲 CPU 0%），绿灯也
   不常亮。第一次检测即为基准校准（保持标准坐姿即可）。**插电时自动提速**：
   间隔缩短为 1/3（最短 30 秒，菜单信息行显示 ⚡），拔电立即恢复设定间隔。
5. **判定**：某次检测发现头部俯仰低于基准 −15°（可调）→ 不立刻报警，60 秒后
   复查；连续两次低头 → 系统通知 + 提示音（可选语音），每 60 秒最多一次。
   这等价于「持续低头才提醒」，弯腰捡东西不会误报。头部转向（|yaw|>35°）或
   离开时自动挂起。菜单可切换为「实时」模式（摄像头常开，连续判定，耗电
   约 0.5–1W，主要用于调试）。

## 安装

从 [Releases](https://github.com/caic99/PostureGuard/releases) 下载最新的
`PostureGuard.app.zip`，解压运行。应用为 ad-hoc 签名，首次启动可能需要清除
隔离属性：

```bash
xattr -cr PostureGuard.app
open PostureGuard.app
```

或者从源码构建：

```bash
./make-app.sh                 # 构建并生成 build/PostureGuard.app
open build/PostureGuard.app   # 启动（首次会请求摄像头权限）
```

开机自启：系统设置 → 通用 → 登录项，添加 `PostureGuard.app`。

> 注意：应用使用 ad-hoc 签名，每次重新构建后签名哈希都会变化，macOS 会把它
> 当作新应用——**重新构建后的首次启动需要重新点一次摄像头授权**。日常使用
> （不重新构建）不受影响。

## 使用

菜单栏图标含义：`🙆` 坐姿良好 · `🙇` 正在低头 · `🚨` 已触发提醒 ·
`🪑📐` 校准中 · `🪑` 未检测到人脸 · `🪑⏸` 已暂停 · `🪑📷✕` 无摄像头权限。
默认只显示 emoji；打开「菜单栏显示角度」后会附带相对基准的偏差（如 `🙇 -17°`）。

菜单里可以：重新校准、暂停/继续、调阈值（10/15/20/25°）、调检测间隔
（实时/1/3/5 分钟）、开关菜单栏角度显示、开关语音提醒。

## 调试

```bash
open build/PostureGuard.app --args --debug
tail -f /tmp/posture-guard.debug.log
```

每行输出 `lid`（盖角）、`vision`（Vision 原始俯仰）、`head`（补偿后头部俯仰）、
`dev`（相对基准偏差）和状态。
**验证方向**：低头时 `dev` 应变负；若方向相反，加 `--invert-pitch` 启动，
旧基准会自动作废并重新校准。

CLI 选项：`--threshold N` `--check-interval N`（0=实时常开）
`--duration N`（仅实时模式） `--interval N` `--voice` `--invert-pitch`
`--no-lid` `--debug` `--reset`（清除校准与设置）。

## 限制

- 盖角传感器仅较新的 Apple Silicon MacBook 有；读不到时自动退化为
  纯人脸俯仰模式（此时调整屏幕角度后建议重新校准）。
- 假设底座放平（桌面使用）。膝上/支架大角度倾斜时基准会偏，重新校准即可。
- 合盖外接显示器（clamshell）场景不适用——内置摄像头被盖住了。
- Vision 的 pitch 符号在 Apple 文档中未明确定义。实测（macOS 26.5，pitch 与
  人脸框纵向位置相关性 −0.95）确认 **pitch 正值 = 低头**，默认 `pitchSign=-1`
  据此设定；若系统更新后方向异常，用 `--invert-pitch` 启动即可。

## 许可

[MIT](LICENSE)
