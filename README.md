# luci-app-migu-iptv — 咪咕直播源转发

把**咪咕视频**的直播频道转成 TV-BOX 能直接订阅的标准 **M3U 播放列表**，并在播放时按需换取咪咕流地址、302 重定向到最终 HLS 流。

- 路由器原生运行，**无需 Node.js / Docker / Python**，只用 ucode + curl + openssl。
- 游客模式最高 540p；填咪咕账号到 720p；VIP 到蓝光 1080p / 原画 / 4K。
- 内置独立管理页 `/admin`（免登录或密码保护），填账号、选画质、测试频道。

> 参考实现：[akiralereal/iptv](https://github.com/akiralereal/iptv)（Node.js 版）。
> 本项目用 ucode 重写其核心算法：频道列表接口 + playurl 签名 + ddCalcu 解密 + 302 跟随。

---

## 一、功能端点

| 路径 | 说明 |
| --- | --- |
| `GET /m3u` | M3U 播放列表（分组、台标、频道名），TV-BOX 订阅用 |
| `GET /txt` | TXT 播放列表（`频道名,地址` 一行一条） |
| `GET /ch/<pID>` | 按需取流：换咪咕流地址 → 302 重定向到最终 HLS |
| `GET /health` | 服务状态 JSON（频道数、游客/账号、画质） |
| `GET /admin` | 管理页（账号 / 画质 / 测试 / 订阅地址） |
| `POST /admin/api/config/save` | 保存配置（userId/token/rateType/H265/HDR） |
| `POST /admin/api/test` | 测试某频道取流 |

TV-BOX 里订阅地址就是 `http://路由器IP:8788/m3u`。

---

## 二、安装

### 方式 A：OpenWrt SDK 打包（推荐，含 LuCI 菜单）

把本目录放到 `package/` 下，用 OpenWrt SDK 编译出 `luci-app-migu-iptv` 的 ipk：

```sh
# 在 OpenWrt SDK 根目录
cp -r luci-app-migu-iptv package/
make package/luci-app-migu-iptv/compile V=s
# 产物在 bin/packages/.../luci-app-migu-iptv_1.0.0-1_all.ipk
```

路由器上安装：

```sh
opkg install luci-app-migu-iptv_1.0.0-1_all.ipk
```

### 方式 B：手动部署（无 LuCI 菜单，仅核心服务）

```sh
# 1) 主程序
cp migu.uc /usr/share/ucode/migu.uc
# 2) 配置
cp files/etc/config/migu /etc/config/migu
# 3) 服务脚本
cp files/etc/init.d/migu /etc/init.d/migu
chmod +x /etc/init.d/migu
# 4) 启动
/etc/init.d/migu enable
/etc/init.d/migu start
```

依赖（缺一不可）：`ucode`、`ucode-mod-fs`、`ucode-mod-uloop`、`ucode-mod-socket`、`ucode-mod-uci`、`curl`、`openssl-util`。

```sh
opkg install ucode ucode-mod-fs ucode-mod-uloop ucode-mod-socket ucode-mod-uci curl openssl-util
```

---

## 三、配置（`/etc/config/migu`）

| 选项 | 默认 | 说明 |
| --- | --- | --- |
| `enabled` | `1` | 服务开关 |
| `port` | `8788` | 监听端口 |
| `host` | `0.0.0.0` | 监听地址（0.0.0.0 允许局域网） |
| `userId` | 空 | 咪咕账号 ID（空 = 游客，最高 540p） |
| `token` | 空 | 咪咕登录令牌（等同登录态，勿外传） |
| `rateType` | `3` | 2=标清540p / 3=高清720p / 4=蓝光1080p(VIP) / 7=原画(VIP) / 9=4K(VIP) |
| `enableH265` | `1` | H.265（部分设备只有声无画时关） |
| `enableHDR` | `1` | HDR |
| `adminPassword` | 空 | 管理页密码（空 = 免登录） |
| `cacheMinutes` | `360` | 频道列表缓存分钟数 |

超出账号权益时会自动降级到咪咕愿意给的档位（例如游客要 4K 会一路降到 540p）。

---

## 四、获取咪咕 token

`userId` + `token` 是咪咕的登录态。两种取法：

1. **浏览器**：登录咪咕后，按 F12 打开开发者工具 → Network 面板 → 找发往
   `play.miguvideo.com` 的请求 → 看请求头里的 `UserId` 和 `UserToken`。
2. **咪咕 App**：登录后用抓包工具（如 HttpCanary / Stream）抓
   `play.miguvideo.com` 请求的 `UserId` / `UserToken` 头。

把这两个值填进管理页保存即可。**token 等同账号密码，只在自家路由器保存。**

---

## 五、TV-BOX 使用

1. 打开 IPTV 播放器（TiviMate / IPTV Pro / Kodi 等）。
2. 添加远程播放列表，地址填 `http://路由器IP:8788/m3u`。
3. 频道按「央视 / 卫视 / 地方 / 体育 / 影视 …」分组显示（**央视排最前，CCTV1 开头**，符合正常电视台排序习惯），点开即播。

> 说明：频道在**播放时**才实时取流，流地址短期有效、自动续期；播放器切台 / 重连时会重新走 `/ch/<pID>` 取新地址。

---

## 五、CCTV5 与体育频道说明

咪咕对 **CCTV5（含 CCTV5+）在播出版权体育赛事时段会做版权屏蔽**（接口返回
`COPYRIGHT_SHIELD_INVALID`，提示「节目播出调整」）。这是咪咕服务端的时段性限制：

- **游客模式**：CCTV5 播版权赛事时**完全取不到流**，非赛事时段可看标清 540p；
  CCTV5+、CCTV1 等其它频道不受影响。
- **体育会员**（登录咪咕账号）后可看体育频道，蓝光 / 4K 需对应 VIP 档位。

本项目如实转发「你已有权限的流」，不绕过版权校验。CCTV5 取流失败时，管理页测试会给出
`该频道受版权限制，需登录咪咕体育会员后观看` 的明确提示，而非含糊报错。

---

## 六、核心算法（逆向自参考项目）

1. **频道列表**：`program-sc.miguvideo.com/live/v2/tv-data/{vomsID}`，分组 → 频道（pID、台标）。
2. **取流签名**：
   - `ts = 当前毫秒时间戳`，`appVersion = "26000370"`；
   - `md5 = MD5(ts + pID + appVersion)`；
   - `sign = MD5(md5 + "3ce941cc3cbc40528bfd1c64f9fdf6c0migu0123")`，`salt = 1230024`；
   - 请求头带 `AppVersion / TerminalId:android / X-UP-CLIENT-CHANNEL-ID / appCode`，账号档位额外带 `UserId / UserToken`。
3. **ddCalcu 解密**：对返回 URL 的 `puData` 做首尾交错重排，并按位置注入
   `keys="cdabyzwxkl"` 与 `words=['v','a','0','a']` 的字符（CCTV5/5+ 走特殊分支）。
4. **302 跟随**：解密后的地址经 1~2 次 302 得到最终 HLS（`*.miguvideo.com`）。

---

## 七、安全提示

- `token` 是咪咕登录态，等同账号密码，**不要**发到公网、不要提交到公开仓库。
- 若需公网访问，务必在管理页设置 `adminPassword`；否则任何人拿到地址都能改配置。
- 蓝光 / 原画 / 4K 以及体育会员频道需要**付费 VIP**，本项目只负责「转发你已有权限的流」，不绕过、不破解咪咕的会员校验。
