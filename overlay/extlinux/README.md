# extlinux.conf 模板

基于实机验证（`ark@192.168.31.113:/boot/extlinux/`），相对上游 dArkOS RK2023 的 APPEND 改动：

| 改动 | 上游 | X35 模板 |
| --- | --- | --- |
| 控制台 | `console=tty1`（占用 LCD） | **去掉** |
| 日志级别 | `loglevel=5` | **去掉** |
| 串口日志 | 无 | `console=ttyS2,1500000n8`（日志走 UART，不占屏幕） |

FDT 改为 `/rk3566-powkiddy-x35h.dtb` 或 `/rk3566-powkiddy-x35s.dtb`。

构建时 `scripts/mod-image.sh` 会用对应模板整文件替换 boot 分区上的 `extlinux/extlinux.conf`。
