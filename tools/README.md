# 排查工具

QTS 自带的工具很少（没有 `fatrace`、`sqlite3`，`hdparm` 的输出格式也和标准版不同）。这里的脚本都在一个**临时的特权 Alpine 容器**里运行，用 Alpine 的软件包来补齐工具。

## 辅助容器

```sh
# 在 NAS 上用 admin 账号 SSH 登录后执行（需要已安装 Container Station）
docker run --rm -it --privileged --net=host --pid=host \
  -v /:/host:ro -v "$PWD":/work -w /work alpine:3.22 sh

# 容器里：
apk add -q hdparm smartmontools sqlite
nsenter -t 1 -m -n sh     # 需要时进入宿主机的挂载/网络空间执行命令
```

- `--pid=host`：能看到宿主机上的所有进程（读写统计、进程名）。
- `--net=host`：和宿主机共用网络（抓包、看路由表）。
- `-v /:/host:ro`：宿主机文件系统以只读方式挂在 `/host`。
- `--privileged`：可以访问硬盘设备（SMART、APM）。

> ⚠️ 特权容器加上 `--pid=host`，效果上就等于 NAS 的 root 权限。只在排查时使用，用完即删（`--rm`）。如果要长时间在后台运行，请给容器加上 label（如 `--label purpose=debug`），清理时按 label 删，**不要按镜像名批量删除**，以免误删别人的容器。
>
> 排查期间请**关掉 QTS 管理网页**：网页每隔几秒就会调用 CGI 写系统分区，会严重干扰结果。

## 脚本

| 脚本 | 用途 | 用法 |
|---|---|---|
| [`check-disks.sh`](check-disks.sh) | 查看每块机械盘的型号、APM、磁头停靠次数（Load_Cycle_Count）、启停次数、通电时间 | `sh check-disks.sh`，隔 10~30 分钟再跑一次，对比停靠次数 |
| [`watch-hdd-writes.sh`](watch-hdd-writes.sh) | 用 `fatrace` 记录"哪个进程写了哪个文件"（只看机械盘相关的文件系统），并每分钟记一次机械盘的写入计数 | `sh watch-hdd-writes.sh 2400 > writes.log`（2400 秒 = 40 分钟） |
| [`watch-hdd-io.sh`](watch-hdd-io.sh) | 每 5 秒看一次机械盘**实际发生的读写**（`/proc/diskstats`），有读写时打印涉及的阵列和当时最忙的进程 | `sh watch-hdd-io.sh 2400 > io.log` |
| [`autolan-events.sh`](autolan-events.sh) | 统计 QTS 事件日志里 QuFirewall "auto-LAN 规则更新"的次数，并列出最近的记录 | `sh autolan-events.sh` |

### 小提示

- **fatrace 和 diskstats 怎么选？** `fatrace` 看的是文件访问，能直接告诉你是谁、改了哪个文件，但很多读取其实命中了内存缓存，没有真正碰到硬盘。`/proc/diskstats` 只统计真正发到硬盘上的请求，适合确认"硬盘到底有没有在动"。两个配合着用。
- **用 fatrace 监控读取时只用 `-f R`**。`-f RO` 会把 fatrace 自己的开关文件操作也记进去，形成死循环，一分钟就能刷出几十万行。
- **QNAP 内核没有开块设备跟踪（block tracepoints）**，没法把每一次磁盘请求精确对应到进程。`watch-hdd-io.sh` 列出的进程只是"那一刻谁最忙"的线索。
- **长时间抓包不要用 `| head -N` 限制行数**：主路由每十几秒发一次 IPv6 路由通告，行数很快就满了，抓包程序会被 SIGPIPE 提前结束。应该收紧过滤条件。
- **查 QTS 事件日志**：日志是 SQLite 数据库，位于 `/mnt/HDA_ROOT/.logs/event.log`，表名 `NASLOG_EVENT`。先复制一份再查，不要直接读写原文件。
