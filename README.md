# dArkOS RK2023 → PowKiddy X35H / X35S

将 [dArkOS v06072026](https://github.com/christianhaitian/dArkOS/releases/tag/v06072026) 的 **RK2023** 官方镜像 mod 为可在 **PowKiddy X35H / X35S** 上启动的版本，并通过 GitHub Actions 自动构建、发布 Release、上传百度网盘。

## 修改内容

| 组件 | 文件 | 说明 |
| --- | --- | --- |
| U-Boot | `RK3566-Specific_uboot.bin` | 写入镜像 sector 64（与 `flash-uboot.sh` 一致） |
| 内核 | `Image` | 替换 boot 分区的 `/Image` |
| DTB | `rk3566-powkiddy-x35h.dtb` / `rk3566-powkiddy-x35s.dtb` | 复制到 boot 分区根目录 |
| extlinux | `overlay/extlinux/*.extlinux.conf` | 整文件替换，APPEND 相对上游有三处改动（见下） |
| rootfs | `overlay/rootfs/etc/systemd/sleep.conf.d/s2idle.conf` | 强制 s2idle 休眠模式 |

### extlinux.conf APPEND 改动（相对上游 RK2023）

| 项 | 上游 | 本 mod |
| --- | --- | --- |
| LCD 控制台 | `console=tty1` | **去掉** |
| 内核日志级别 | `loglevel=5` | **去掉** |
| 串口控制台 | 无 | `console=ttyS2,1500000n8`（日志走 UART，不占 LCD） |

另将 `FDT` 改为对应 X35H / X35S 的 dtb。模板见 `overlay/extlinux/`。

### rootfs 改动

| 路径 | 说明 |
| --- | --- |
| `/etc/systemd/sleep.conf.d/s2idle.conf` | 强制 `MemorySleepMode=s2idle`、`SuspendState=mem`（本板 deep sleep 无法唤醒） |

模板位于 `overlay/rootfs/`，构建时挂载 rootfs 分区（p4，btrfs）后复制进去。

X35H 与 X35S 硬件相同，仅屏幕方向不同，因此分别输出两个镜像。

## 目录结构

```
.
├── config.env                 # 上游版本、输出命名、变体配置
├── flash-uboot.sh             # U-Boot 刷写（本地/CI 共用）
├── Image                      # 自定义内核
├── RK3566-Specific_uboot.bin  # 自定义 U-Boot
├── rk3566-powkiddy-x35h.dtb
├── rk3566-powkiddy-x35s.dtb
├── overlay/
│   ├── extlinux/              # extlinux.conf 模板
│   │   ├── X35H.extlinux.conf
│   │   └── X35S.extlinux.conf
│   └── rootfs/                # rootfs 文件覆盖（保持路径一致）
│       └── etc/systemd/sleep.conf.d/s2idle.conf
└── scripts/
    ├── download-base.sh       # 下载并解压上游 RK2023 镜像
    ├── mod-image.sh           # 单变体 mod（uboot + kernel + dtb）
    ├── build-all.sh           # 构建全部变体并 7z 分卷
    └── upload-baidu.sh        # 百度网盘上传
```

## 本地构建

依赖：`p7zip-full`、`curl`、`sgdisk`（`gdisk` 包）、`dosfstools`、`btrfs-progs`。

```bash
sudo apt-get install -y p7zip-full curl gdisk dosfstools btrfs-progs
sudo bash scripts/build-all.sh
```

产物在 `dist/`：

- `dArkOS_RK2023_X35H_trixie_06082026.img.7z.001` …
- `dArkOS_RK2023_X35S_trixie_06082026.img.7z.001` …

仅构建某一变体：

```bash
sudo bash scripts/build-all.sh --variant X35H
```

## 手动刷 U-Boot（可选）

若已有 dArkOS RK2023 镜像或 SD 卡，可单独刷 U-Boot：

```bash
sudo ./flash-uboot.sh /dev/sdX          # SD 卡
sudo ./flash-uboot.sh darkos-rk2023.img  # 镜像文件
```

## GitHub Actions

工作流：`.github/workflows/build-release.yml`

### 触发方式

1. **打 tag 发布**（推荐）  
   ```bash
   git tag v1.0.0
   git push origin v1.0.0
   ```
2. **手动运行**：Actions → Build and Release → Run workflow

### 仓库 Secrets（百度网盘）

| Secret | 说明 |
| --- | --- |
| `BDUSS` | 百度账号 BDUSS Cookie |
| `STOKEN` | 百度账号 STOKEN Cookie |

在浏览器登录 [pan.baidu.com](https://pan.baidu.com) 后，从 Cookie 中获取（勿泄露）。

### 仓库 Variables（可选）

| Variable | 默认值 | 说明 |
| --- | --- | --- |
| `BAIDU_REMOTE_DIR` | `/Apps/dArkOS-X35/` | 网盘目标目录 |
| `DARKOS_RELEASE` | `v06072026` | Release 说明中引用的上游版本 |

未配置 `BDUSS` / `STOKEN` 时，构建与 GitHub Release 仍会执行，仅跳过百度上传。

## 更新 mod 资源

1. 替换仓库根目录下的 `Image`、`RK3566-Specific_uboot.bin` 或 dtb 文件。
2. 若上游 dArkOS 版本变更，编辑 `config.env` 中的 `DARKOS_RELEASE` 与 `BASE_IMAGE_BASENAME`。
3. 打新 tag 触发 CI，或本地 `sudo bash scripts/build-all.sh` 验证。

## 刷机

1. 下载对应变体（x35h / x35s）的全部 `.7z.00x` 分卷。
2. 用 7-Zip 打开 `.001` 解压得到 `.img`。
3. 写入 SD 卡（Rufus、balenaEtcher、`dd` 等）。

## 许可与声明

- 上游 dArkOS 版权归 [christianhaitian/dArkOS](https://github.com/christianhaitian/dArkOS) 所有。
- 本仓库仅提供镜像 mod 脚本与自动化流程；设备变砖风险自负，请先备份。
