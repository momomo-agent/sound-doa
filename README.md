# Sound DOA (Direction of Arrival) — iPhone 声源方向检测研究

## 目标
iPhone 平放桌上，检测说话人从哪个方向对着手机说话（左上/右上/右下/左下等）。

## 硬件基础
- iPhone 有 3 个 MEMS 麦克风：底部、前置（听筒旁）、后置（摄像头旁）
- 音频编解码器：Cirrus Logic 338S00509
- iOS 立体声录音 API（WWDC 2020）可拿到 2 通道 PCM，但被限制在 16kHz
- iOS 不允许同时访问 3 个独立麦克风原始信号

## 方案一：TDOA（到达时间差）

### 原理
声音到达不同麦克风有微小时间差，通过 GCC-PHAT 互相关算法计算时间差推导方向。
θ = arcsin(τ × c / d)，c=343m/s，d=麦克风间距

### 实现
1. AVAudioSession 立体声录音，2 通道 16kHz PCM
2. 每帧 20-50ms 窗口做 GCC-PHAT 互相关
3. 找峰值对应的时间延迟 τ
4. τ → 角度转换
5. CMMotionManager 设备姿态补偿

### Hack 点
- 尝试绕过 16kHz 限制（RemoteIO AudioUnit 底层）
- 快速切换 front/back data source 录两组数据，等效 4 通道
- Cirrus Logic 硬件支持多通道，是 iOS 软件层限制

### 精度预估
- 16kHz: 时间分辨率 62.5μs，角度分辨率 ~15-20°
- 48kHz（如果能 hack）: ~5-7°

## 方案二：ILD（声强差）+ 频谱分析

### 原理
不同方向声音到达两个麦克风的能量差异不同。手机机身本身是天然的声学遮挡结构。

### 实现
1. 立体声录音，2 通道 PCM
2. 短时帧分析：
   - ILD: 左右声道 RMS 能量比
   - IPD: 左右声道 STFT 相位差
   - 频谱形状差异（高频衰减模式）
3. 特征组合 → 方向映射（查找表或轻量 ML）

### Hack 点
- 手机机身 = 天然 EarCase，不同方向高频衰减不同
- 标定：12 个方向播放测试音建立指纹库
- 平放 vs 竖放需分别标定

### 精度预估
- 左/右: ±15°
- 前/后: ±30-45°（靠频谱差异）
- 组合: 8-12 个方向区域

## 其他方案（备选）

### 方案三：ML 模型
CNN/CRNN 从立体声频谱图回归方向角度。精度最高但工程量大。

### 方案四：EarCase（声学结构增强）
3D 打印手机壳，非对称声学结构，单麦判断方向。Rutgers 大学论文。

### 方案五：VoLoc（墙壁反射）
MobiCom 2020，利用房间墙壁反射推算声源位置，精度 0.44m。需要房间几何信息。

### 方案六：Swadloon（运动辅助）
IMU + 麦克风，手机晃动时多普勒频移推断方向。需要手机在动。

## 参考文献
- WWDC 2020: Record stereo audio with AVAudioSession
- EarCase: Sound Source Localization Leveraging Mini Acoustic Structure (Rutgers)
- VoLoc: Voice Localization Using Nearby Wall Reflections (MobiCom 2020)
- Swadloon: Direction Finding and Indoor Localization Using Acoustic Signal (USTC)
- Stanford: Learning Sound Location from a Single Microphone (monaural HRTF)
- GCC-PHAT Cross-Correlation for TDOA estimation
- A Survey of Sound Source Localization with Deep Learning Methods (JASA 2022)

## Demo App
iOS SwiftUI app，实时显示声源方向，可切换 TDOA / ILD 两种算法。
