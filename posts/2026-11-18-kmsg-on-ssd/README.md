# QTS 6.1 机械盘又响了：把内核日志和归档迁到 SSD

| | |
|---|---|
| 日期 | 2026-11-18 |
| 状态 | ✅ 已迁移，已通过整机重启验证 |
| 设备 | QNAP TS-264C，QTS 6.1.0 build 20261023，两块 IronWolf 4 TB 机械盘，两块 NVMe SSD 组 RAID1 |
| 标签 | `硬盘噪音` `内核日志` `kmsg` `SSD` |

**English TL;DR** — Repeated ICMP routing warnings were written to a kernel log mirrored across both HDDs. Moving the log and its ten archives to the NVMe volume reduced writes per HDD from 136 to 8 in a pair of 80-second samples. After a NAS reboot, the logger was still writing to the SSD.

## 怎么找到写盘来源

10 月调整 APM 后，两块机械盘安静了一阵。11 月又听到「炒豆子」声，但两块盘的磁头停靠计数与三天前完全相同。SMART 显示正常，重映射、待处理和不可校正扇区均为 0。[10 月的排查记录](../2026-10-03-hdd-noise-and-standby/)

查 `/proc/diskstats`，80 秒内两块机械盘都没有读取，写入全部落在各自的第一个分区。它们同属系统镜像 `md9`。同一时段，`/mnt/HDA_ROOT/.logs/kmsg` 新增 35 行，其中 32 行是这条告警（地址已省略）：

```text
icmp: detected local route for <地址> during ICMP sending, src <地址>
```

内核在发送 ICMP 回包时遇到了本地路由。容器服务可以照常工作，但 QTS 每次把这类消息记入内核日志，两块机械盘都会收到写入。曾尝试只过滤这条消息，发现新启动的 QTS 日志进程受 AppArmor 规则限制，无法加载原厂模块。最终保留了原来的日志进程和所有告警，只改存放位置。

## 迁移前先做对照

把这一份日志临时转到 SSD，再恢复原路径。两个相邻窗口各测 80 秒，机械盘写入取自物理设备计数器。

| 日志位置 | 新增同类告警 | 每块 HDD 写入次数 | 每块 HDD 写入量 |
|---|---:|---:|---:|
| 临时写入 SSD | 29 | 8 | 23 KiB |
| 恢复到默认系统分区 | 36 | 136 | 1,032 KiB |

告警在两段时间里都出现了。写 SSD 时，每块机械盘的写入次数少了约 94%。这个数字只描述这两个采样窗口，测量的是读写活动，没有测分贝。

## 实际改了什么

本机的 SSD 卷是 `/share/CACHEDEV3_DATA`，已从块设备映射追到两块 NVMe。其他机器的卷编号可能不同，迁移前要先查实际映射。

| 内容 | QTS 原来的位置 | 迁移后 |
|---|---|---|
| 当前内核日志 | `/mnt/HDA_ROOT/.logs/kmsg` | SSD 目录中的 `kmsg` |
| 最近两份压缩归档 | 同目录的 `kmsg.1.gz`、`kmsg.2.gz` | 同一 SSD 目录 |
| 更早的八份备份 | `/share/CACHEDEV1_DATA/.system/kmsg_backup.*.gz` | 同一 SSD 目录 |

1. 在 SSD 上建立 `/share/CACHEDEV3_DATA/.qts-kernel-log/`。先用测试日志实际跑一次轮转，核对当前文件会压缩为第一份归档，旧文件会依次进入第二份归档和备份。
2. 复制并逐份比对历史文件。短暂停住 QTS 的内核日志进程，复制并核对当时的活动日志，再将原路径原子替换为指向 SSD 文件的符号链接。这样 QTS 自带的日志读取工具仍可从原路径打开文件。
3. 修改 `/etc/config/logrotate.d/klog`。活动日志路径、轮转脚本里的 `LAST_FILE` 和备份目录 `SYS_VOL` 都要指向 SSD；只迁活动文件会漏掉归档。保留原来的 2 MiB 轮转阈值和十份归档。原配置备份在 SSD 目录的 `.rotation-before-migration`。
4. 让原日志进程重新打开文件并恢复运行，确认它实际打开了 SSD 文件、文件大小开始增长，再清理迁移用的临时副本。此次迁移没有增加开机脚本。

## 重启后怎么确认

整机重启后，核对了三件事：日志进程持有的文件与 SSD 上的 `kmsg` 设备号和 inode 完全一致；采样期间该文件新增 **1,336 字节**；十份归档都能从原路径读到，轮转配置仍指向 SSD。只看链接指向哪里，无法排除进程还握着旧文件的情况。

在 NAS 宿主机用管理员权限执行下面的只读命令。将 `ssd` 改为自己核实过的路径。

```sh
ssd=/share/CACHEDEV3_DATA/.qts-kernel-log/kmsg
pid=$(cat /var/run/rsyslogd.pid)
readlink -f /mnt/HDA_ROOT/.logs/kmsg
stat -Lc '%d:%i %s %n' "$ssd"
for fd in /proc/"$pid"/fd/*; do
    [ "$(readlink "$fd")" = "$ssd" ] && stat -Lc '%d:%i %n' "$fd"
done
grep -E 'kmsg \{|LAST_FILE=|SYS_VOL=' /etc/config/logrotate.d/klog
```

## 需要撤销时

先确认原卷空间足够，在轮转间隙暂停同一个内核日志进程。把 SSD 上的当前日志和归档复制到各自原目录的临时文件，逐份核对，再用这些文件替换符号链接。恢复备份的轮转配置，让进程重新打开日志并恢复运行。确认原文件持续增长后，再清理 SSD 副本。复制时直接写入仍是符号链接的原路径，会写回 SSD。

这次只迁了内核日志及其归档。其他 QTS 配置和日志仍可能写入系统镜像，固件升级后也可以用上面的命令复查。
