# 机械硬盘噪音 / 不休眠 / 磁头频繁停靠

| | |
|---|---|
| **日期** | 2026-10-03 ~ 2026-10-04 |
| **状态** | ✅ 已解决 |
| **标签** | `硬盘` `噪音` `休眠` `APM` `QuFirewall` `IPv6` |
| **设备** | TS-264C / QTS 5.2.10 / Seagate IronWolf 4TB |

> 两块机械硬盘一直"炒豆子"、偶尔"咔哒"、永远不休眠。这篇记录了从"听到噪音"到找出**每一个写盘来源**并逐个解决的完整过程。

**English TL;DR** — On QNAP, the system partitions (`md9` = `/mnt/HDA_ROOT`, `md13` = `/mnt/ext`) are RAID1-mirrored onto **every internal disk**, including HDDs, even if your data volumes live on SSDs. Any write to config/log files wakes the HDDs. We found four culprits: (1) APM 128 causing ~35 head unloads/hour on Seagate IronWolf (fix: `hdparm -B 254` via `autorun.sh`), (2) QuFirewall rewriting its config every minute (fix: disable "firewall events"), (3) `storage_usage.sh` cron writing every 10 min (fix: change cron to daily), (4) QuFirewall regenerating auto-LAN rules + sshd_config every time an IPv6 **route-cache** entry appears/expires — triggered by a monitoring agent that looked up the public IPv6 address every few minutes (fix: block those lookups). Result: HDDs untouched for 40 min straight, Load_Cycle_Count frozen.

---

## 目录
- [环境](#环境)
- [先搞清楚：两种声音，两个原因](#先搞清楚两种声音两个原因)
- [背景知识和工具](#背景知识和工具)
- [排查流程](#排查流程)
- [找到的 4 个元凶和解决办法](#找到的-4-个元凶和解决办法)
- [结果](#结果)
- [踩过的坑](#踩过的坑)
- [FAQ](#faq)
- [参考资料](#参考资料)

## 环境

| 项目 | 型号 / 版本 |
|---|---|
| NAS | QNAP TS-264C（TS-x64 系列） |
| 系统 | QTS 5.2.10 |
| 机械硬盘 | 2 × Seagate IronWolf 4TB（ST4000VN008），各自独立的静态卷，已通电约 41,000 小时 |
| 固态硬盘 | 2 × NVMe，RAID1，存放 Docker、应用和虚拟机 |
| 防火墙 | QuFirewall 2.6.1 |

数据、应用、容器基本都在 SSD 上，机械硬盘只存媒体。照理说机械盘应该很安静——但事实并非如此。

> ⚠️ 这是在**一台**设备上的实测记录。不同型号、固件、硬盘的表现可能不同，请按下文的方法**先测再改**。

## 先搞清楚：两种声音，两个原因

| 声音 | 来源 | 由谁控制 |
|---|---|---|
| 连续的"咔咔咔/哒哒哒"（炒豆子） | 磁头**寻道**，有读写时才发生 | 读写负载 |
| 偶尔一声"咔哒"，空闲几秒到十几秒后出现 | 磁头**收回到停泊位**（unload / head parking） | 硬盘的 **APM** 等级 |

所以要做两件事：
1. 让磁头别频繁收回 → 调 APM；
2. 找出是谁在读写机械盘 → 逐个排查写入来源。

## 背景知识和工具

**先读这篇：[QNAP 系统分区：为什么"系统写一下，所有硬盘都醒"](../../knowledge/system-partitions.md)**

一句话总结：QNAP 会把系统配置和日志所在的分区（`md9` = `/mnt/HDA_ROOT`、`md13` = `/mnt/ext`）**镜像到每一块内置硬盘上**，就算你的数据和应用都放在 SSD 上也一样。所以：

> 在 QNAP 上，机械盘安不安静，取决于有没有程序在频繁写系统分区。

排查用的是一个临时的特权 Alpine 容器，加上几个脚本，用法见 **[tools/](../../tools/)**。下文的 `tools/xxx.sh` 都在那个容器里运行。

## 排查流程

### 第 1 步：看磁头停靠次数和 APM

```sh
sh tools/check-disks.sh      # 隔 10~30 分钟再跑一次，对比 Load_Cycle_Count
```

我们的实测：

| | sda | sdb |
|---|---|---|
| APM | 128 | 128 |
| Load_Cycle_Count | **1,314,664** | **1,399,137** |
| 增长速度 | 10 分钟 +6，约每小时 35 次 | 10 分钟 +5 |
| SMART 该项归一化值 | 1（接近阈值） | 1 |

IronWolf 这一代的设计寿命约 60 万次，这两块盘已经是两倍多。原因是 APM 128 下空闲几秒就收回磁头，有读写又放下来。这也是"咔哒"声的来源。

### 第 2 步：找出谁在写系统分区

```sh
sh tools/watch-hdd-writes.sh 2400 > writes.log   # 40 分钟
```

它用 `fatrace` 记录每一次"哪个进程写了哪个文件"，同时每分钟记一次两块机械盘的写入计数。输出示例：

```
07:46:45 syslogRequest.c(803575): CW  /host/mnt/HDA_ROOT/.logs/notice.log
08:10:34 python3(765): CW /host/mnt/HDA_ROOT/.config/QuFirewall.conf.tmp.y3uvcwen
08:10:36 mksshdconf(1044213): W /host/mnt/HDA_ROOT/.config/ssh/sshd_config
08:10:38 log_tool(1044938): W /host/mnt/HDA_ROOT/.logs/event.log-journal
DISK 08:12:32 sda:w=17361 sdb:w=16931
```

按"进程 + 文件"汇总，再看时间规律（每分钟？每 10 分钟？不规律？），就能定位来源。

### 第 3 步：连读盘一起看

`fatrace` 记录的是文件访问，很多读取其实命中了内存缓存，根本没碰硬盘。要确认硬盘是否**真的**在工作，看 `/proc/diskstats`：

```sh
sh tools/watch-hdd-io.sh 2400 > io.log
```

每 5 秒检查一次，机械盘只要有读写，就打印涉及的阵列（`md9` 系统分区？`md1` 数据卷？swap？）和当时读写最多的进程。

### 第 4 步：查 QTS 事件日志

很多后台动作会在系统事件日志里留下记录，日志是个 SQLite 数据库：

```sh
sh tools/autolan-events.sh
```

## 找到的 4 个元凶和解决办法

### 元凶 1：APM 128 → 磁头每小时停靠约 35 次

**解决：** 把 APM 设成 254（最高性能，磁头保持加载）。

先临时测试：

```sh
hdparm -B 254 /dev/sda
hdparm -B 254 /dev/sdb
```

我们实测 30 分钟，停靠次数 **0 增长**。QTS 重启后会恢复默认值，所以要写进开机脚本 `autorun.sh`：

1. **控制台 → 系统 → 硬件 → 常规**，勾选"**启动时运行用户定义的进程**"（Run user defined startup processes (autorun.sh)）。
2. SSH 登录 NAS，用 QTS 自带的辅助命令挂载启动闪存里的配置分区（QTS 4.3.3 以后都有，不用关心分区路径）：
   ```sh
   /etc/init.d/init_disk.sh mount_flash_config      # 挂载到 /tmp/nasconfig_tmp
   cp autorun.sh /tmp/nasconfig_tmp/autorun.sh      # 先把本文目录下的 autorun.sh 传到 NAS 上
   chmod +x /tmp/nasconfig_tmp/autorun.sh
   /etc/init.d/init_disk.sh umount_flash_config
   ```
   （我们实际是手动挂载的 `/dev/mmcblk0p6`，这个路径只适用于 TS-x64，不同型号不一样，所以推荐用上面的辅助命令。）
3. 重启后检查 `/tmp/apm254.log`，并用 `hdparm -B /dev/sdX` 确认。

[`autorun.sh`](autorun.sh) 在开机 2 分钟和 10 分钟后各设置一次（防止被 QTS 启动流程改回去），只作用于机械盘。

> 代价：多耗一点点电（通常 <1W）。硬盘休眠（QTS 的"硬盘待机"）不受影响，照样可以用。
>
> 撤销：在控制台里取消勾选"启动时运行用户定义的进程"即可。

### 元凶 2：QuFirewall 每分钟改写配置

`fatrace` 显示 QuFirewall 每分钟整点改写 `QuFirewall.conf` 和 `QuFirewall_DENIED_IP.conf`。对比前后两份文件，只有一行变了：

```
current_deny = 737  ->  current_deny = 872
```

这是"已拦截连接数"统计。只要 NAS 的 IPv6 暴露在公网，每分钟就会拦截上百次扫描，计数器也就每分钟写一次盘。

**解决：** QuFirewall → 设置里关掉"**启用防火墙事件**"（配置里对应 `enable_event_log`），顺便关掉"**自动捕获**"（超过阈值时会自动抓包写盘）。防火墙规则、地区限制、IP 库更新都照常生效，只是不再记录每一次拦截。

> QNAP 官方 FAQ 把 QuFirewall 列为"会阻止硬盘待机"的应用之一，但没有给出不停用防火墙的解决办法。社区也有 QuFirewall 2.6.x 拦截计数每分钟重复累加的 bug 报告。

### 元凶 3：存储用量日志每 10 分钟写一次

系统定时任务 `/etc/init.d/storage_usage.sh` 每 10 分钟把各卷用量写进 `/etc/logs/storage_usage_history/`（也就是 `md9`）。它**只**用于存储管理页面里的"用量历史曲线"，不负责容量告警，当前用量显示也不依赖它。

**解决：** 改定时任务的执行频率，比如改成每天凌晨 3 点一次：

```sh
cp -p /etc/config/crontab /etc/config/crontab.bak
sed -i 's#^0-59/10 \* \* \* \* /etc/init.d/storage_usage.sh$#0 3 * * * /etc/init.d/storage_usage.sh#' /etc/config/crontab
crontab /etc/config/crontab && /etc/init.d/crond.sh restart
crontab -l | grep storage_usage
```

**重启后依然有效**：开机时 `crond.sh` 只检查 crontab 里**有没有**包含 `storage_usage.sh` 的行，没有才补回"每 10 分钟"那一行，不会检查执行间隔。固件升级时可能被重写，升级后检查一下即可。

代价：用量曲线的精度变低（日 / 周 / 月平均值基本不受影响）。

### 元凶 4（最隐蔽）：IPv6 路由缓存 → QuFirewall 反复重写"自动 LAN 规则"

修完前三个以后，机械盘还是每隔 10～20 分钟被一大波写入叫醒。`fatrace` 显示每次都是这一串：

```
python3 (QuFirewall)  -> QuFirewall.conf, QuFirewall_DENIED_IP.conf
mksshdconf / login.sh -> ssh/sshd_config, sshd_user_config   (重新生成 SSH 配置)
log_tool              -> event.log                            (事件日志)
ncdb                  -> nc/db/...                            (通知中心数据库)
```

事件日志里对应的是这条记录，而且**每天两百多次**：

```
[QuFirewall] Updated the auto-LAN discovery rule settings. Permission: Allow,
IP type: IPv6, Source: <你的 /64>,fe80::/64,2406:840:800:2::5, ...
```

注意那个时有时无的单个地址 `2406:840:800:2::5`。

**排查过程：**
1. 读 QuFirewall 的源码（`.qpkg/qufirewall/app/profile.py` 的 `compare_auto_lan_rules`、`monitor.py`）发现：**不管界面上"自动 LAN 发现"开没开**，它都会监听网络变化，读取主路由表，只要路由表里的网段集合变了，就重新生成规则并写一遍配置。所以在界面上关掉"自动 LAN 发现"并不能阻止这些写入。
2. 用 `ip -6 route show cache` 在它出现的那一刻抓到：
   ```
   2406:840:800:2::5 via fe80::xxxx dev qvs0 metric 100
       cache  expires 0sec
   ```
   这是内核的**路由缓存条目**（由 ICMPv6 重定向、PMTU 等产生），访问某个外网 IPv6 地址时出现，过一段时间失效。QuFirewall 把它当成了一个"新的局域网网段"——出现时重写一次，消失时再重写一次。
3. 抓包看是谁在访问这个地址：`tcpdump -i qvs0 -n host 2406:840:800:2::5`，用 DoH 反查域名，它是 `v6.ip.zxinc.org`，一个**查询公网 IPv6 地址**的服务。
4. 定位到 NAS 上运行的服务器监控探针（CF-Server-Monitor 的 `cf-probe`）会定期访问它来获取本机公网 IPv6。重新启动探针时**当场复现**：
   ```
   07:32:12  cf-probe 连接 2406:840:800:2::5:443
   07:32:13  路由缓存里出现 2406:840:800:2::5
   07:32:20  QuFirewall: Updated the auto-LAN discovery rule settings ... 2406:840:800:2::5
   07:42:24  缓存过期 → QuFirewall 再重写一次
   ```

**解决：** 让这个探针不再访问外网的 IPv6 查询服务。探针没有提供开关，所以在它的容器里用 `extra_hosts` 把这些域名指向 `::1`：

```yaml
services:
  cf-probe:
    image: alpine:3.22
    network_mode: host
    pid: host
    restart: unless-stopped
    extra_hosts:
      - "v6.ip.zxinc.org:::1"
      - "api-ipv6.ip.sb:::1"
      - "api6.ipify.org:::1"
      - "ipv6.icanhazip.com:::1"
    # ...
```

只屏蔽一个不够，它查不到会自动换下一个服务。屏蔽以后，探针会直接读网卡上的 IPv6 地址，后台照样能显示，监控数据没有任何损失。

**通用思路：** 如果你的事件日志里也有大量"auto-LAN discovery rule"更新，看看 IPv6 Source 列表里有没有一个**时有时无的单个地址**，然后：
1. 用 DoH 反查这个地址对应的域名（如 `https://dns.alidns.com/resolve?name=<域名>&type=AAAA`，正向查找候选域名后比对）；
2. 用 `tcpdump ... host <地址>` 抓包，看是哪个程序在连接它；
3. 让这个程序别再连接它，或者改用 IPv4。

常见的嫌疑对象：各种监控探针、DDNS 客户端、"获取公网 IP"的脚本、测速工具。

## 结果

同一台 NAS，40 分钟监控，关掉 QTS 网页：

| | 修复前 | 修复后 |
|---|---|---|
| APM | 128 | 254 |
| 磁头停靠 | 约每小时 35 次 | **0**（重启、关机各 +1） |
| QuFirewall 计数器 | 每分钟写一次 | 不再写 |
| 存储用量日志 | 每 10 分钟写一次 | 每天 3:00 写一次 |
| auto-LAN 规则重写 | 每天约 260 次 | **0** |
| 40 分钟内机械盘被写入的时间点 | 每分钟都有 → 后来每 10 分钟一次 | **基本为 0**（只剩排查工具本身） |
| 机械盘读取 | — | 无人访问媒体时为 0 |

改完以后，硬盘也终于可以进入待机了（QNAP 硬盘日志里出现了"进入待机"）。

## 踩过的坑

1. **QTS 管理网页本身就是写入源。** `utilRequest.cgi`、`disk_manage.cgi` 每隔几秒就写一次系统分区。测试时一定要关掉网页。
2. **`fatrace` 用 `-f RO` 监控打开/读取事件时，会把自己的开关文件操作也记进去，形成死循环**，一分钟刷出几十万行。监控读取只用 `-f R`，并过滤掉 `fatrace(` 自己。
3. **`tcpdump ... | head -N` 会提前退出。** 主路由每 15 秒发一次 RA，`head -400` 几分钟就满了，抓包程序会跟着被 SIGPIPE 杀掉。长时间抓包请收紧过滤条件，或者把上限加大。
4. **清理临时容器时只按镜像名删，会误删别人的容器。** 我们就因为"删除所有 `alpine:3.22` 容器"误删了正在运行的监控探针。给临时容器加 label，清理时按 label 删。
5. **看起来相关不一定真的相关。** 元凶 4 刚好在主人出门的时间点消失，一度怀疑是手机或 mesh 路由器的原因，最后发现只是巧合：同一时间我们误删了探针容器。所以要找到**能复现**的证据再下结论。
6. **QTS 自带的 `hdparm` 输出格式和标准版不同**，脚本里不要解析它的输出，确认时用容器里的 `hdparm -B`。

## FAQ

**Q：没有读写了，就完全没有声音了吗？**
大部分会没有。但 IronWolf 这类盘空闲时固件也会做后台维护（扫描盘面、挪动磁头），偶尔还是会"嗒"一声，这是正常现象，系统层面关不掉。想要完全安静，只能让硬盘休眠停转。

**Q：能把机械盘从 md9 / md13 镜像里移出去吗？**
技术上可以，但不推荐：这是 QNAP 不支持的状态，系统会认为镜像降级，重启、升级、自检时可能自动加回去，还可能触发告警。先把写入来源处理掉，效果通常已经足够。

**Q：APM 254 和 255 有什么区别？**
254 是"最高性能但仍支持 APM"，255 是"关闭 APM"，部分硬盘不支持 255。254 兼容性更好。

**Q：要不要开硬盘休眠？**
看情况。频繁停转、启动对机械盘的磨损也不小。如果仍有零星访问，休眠时间建议设 20～30 分钟以上。

**Q：外接 USB 硬盘也会被加进系统镜像吗？**
不会，外接 USB 盘不使用这套分区结构。

## 参考资料

- [QNAP FAQ：Why can't my NAS drives enter standby mode?](https://www.qnap.com/en/how-to/faq/article/why-cant-my-nas-drives-enter-standby-mode)
- [QNAP FAQ：Running your own application at startup (autorun.sh)](https://www.qnap.com/en/how-to/faq/article/running-your-own-application-at-startup)
- [QNAP Community：QuFirewall accumulates event count every minute](https://community.qnap.com/t/qufirewall-accumulates-event-count-every-minute-results-in-ridiculous-amount-of-events/6586)
- [Unraid Forum：IronWolf two months in and 30K Load Cycle Count](https://forums.unraid.net/topic/85067-ironwolf-4gb-two-months-in-and-30k-load-cycle-count/)
- [Bpazy/blog：威联通硬盘不休眠的解决方法](https://github.com/Bpazy/blog/issues/150)
- QNAP 论坛里还有很多 "IronWolf Load_Cycle_Count"、"HDD wake every n minutes" 的讨论，搜这两个关键词就能找到

## 免责声明

本文的操作涉及开机脚本、系统定时任务和特权容器，请在**确认数据已备份**的前提下操作。不同型号、固件版本的行为可能不同。文中脚本按 MIT 协议提供，不提供任何担保。

---

*本次排查由作者与 AI 助手（Claude）协作完成，所有结论都在真实设备上测过。*
