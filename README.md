# QNAP 威联通 NAS 问题排查笔记

在自己的威联通 NAS 上遇到的问题、排查过程和解决办法。每篇都是在真实设备上测过的，尽量写清楚**怎么发现、怎么定位、怎么验证**，而不只是给一个结论，方便遇到类似问题的人照着排查。

*Field notes on troubleshooting QNAP NAS issues — each post documents how the problem was found, isolated and verified on real hardware. Posts are in Chinese, with an English TL;DR at the top.*

## 文章

| 日期 | 问题 | 标签 | 状态 |
|---|---|---|---|
| 2026-10-03 | [机械硬盘噪音 / 不休眠 / 磁头频繁停靠](posts/2026-10-03-hdd-noise-and-standby/) | `硬盘` `噪音` `休眠` `APM` `QuFirewall` `IPv6` | ✅ 已解决 |

## 背景知识

可以被多篇文章引用的原理性内容：

- [QNAP 系统分区：为什么"系统写一下，所有硬盘都醒"](knowledge/system-partitions.md)

## 排查工具

- [tools/](tools/)：临时特权容器的用法，以及几个通用排查脚本（看磁头停靠次数、记录谁在写盘、看实际磁盘读写、统计 QuFirewall 规则更新）。

## 设备环境

| 项目 | 型号 / 版本 |
|---|---|
| NAS | QNAP TS-264C（TS-x64 系列，Intel Celeron N5105） |
| 系统 | QTS 5.2.x |
| 硬盘 | 2 × Seagate IronWolf 4TB（机械），2 × NVMe SSD |

每篇文章里会写明当时的具体版本。不同型号、不同固件版本的行为可能不一样，请**先测再改**。

## 仓库结构

```
.
├── posts/                    # 每个问题一篇，目录名 = 日期-简短英文名
│   └── 2026-10-03-hdd-noise-and-standby/
│       ├── README.md         # 正文
│       └── autorun.sh        # 这篇用到的专属脚本 / 配置
├── knowledge/                # 可复用的背景知识
├── tools/                    # 可复用的排查脚本
└── TEMPLATE.md               # 新文章模板
```

## 免责声明

文中的操作可能涉及开机脚本、系统定时任务、特权容器等，请在**确认数据已备份**的前提下操作，风险自负。脚本按 [MIT 协议](LICENSE)提供，不提供任何担保。

欢迎在 Issues 里补充你遇到的情况，比如不同型号上的表现，或者更好的解决办法。
