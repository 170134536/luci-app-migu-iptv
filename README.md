# luci-app-migu-iptv — 咪咕直播源转发（LuCI 插件）

把**咪咕视频**的直播频道转成 TV-BOX 能直接订阅的标准 **M3U 播放列表**，并在播放时按需换取咪咕流地址、302 重定向到最终 HLS 流。

- 路由器原生运行，**无需 Node.js / Docker / Python**，只用 ucode + curl + openssl。
- **纯 LuCI 应用**：全部配置在路由器「服务 → 咪咕直播」里完成，没有独立管理网页。
- 游客模式最高 540p；填咪咕账号到 720p；VIP 到蓝光 1080p / 原画 / 4K。

> 参考实现：[akiralereal/iptv](https://github.com/akiralereal/iptv)（Node.js 版）。
> 本项目用 ucode 重写其核心算法：频道列表接口 + playurl 签名 + ddCalcu 解密 + 302 跟随。

---

## 一、LuCI 界面（配置入口）

安装后在路由器 LuCI 里出现 **服务 → 咪咕直播**，两个子页：

| 页面 | 路径 | 作用 |
| --- | --- | --- |
| **设置** | 服务 → 咪咕直播 → 设置 | 服务开关、监听端口/地址、画质档位、H.265/HDR、缓存、调试日志、咪咕账号（userId + token，密码框输入） |
| **运行状态** | 服务 → 咪咕直播 → 运行状态 | 运行状态徽章、服务控制（启动/停止/重启）、TV-BOX 订阅地址（可点选复制）、频道测试、频道分组统计、服务日志 |

**「保存 & 应用」会写 UCI 并自动重启服务**，无需手动去「系统 → 启动项」重启。

配置改动落在 `/etc/config/migu`，同一份配置只有 LuCI 一个维护入口。

---

## 二、服务端点（流媒体后端）

| 路径 | 说明 |
| --- | --- |
| `GET /m3u` | M3U 播放列表（分组、台标、频道名），TV-BOX 订阅用 |
| `GET /txt` | TXT 播放列表（`频道名,地址` 一行一条） |
| `GET /ch/<pID>` | 按需取流：换咪咕流地址 → 302 重定向到最终 HLS |
| `GET /health` | 服务状态 JSON（频道数、游客/账号、画质） |
| `GET /` | 302 跳转到 LuCI 的咪咕直播页 |

TV-BOX 里订阅地址就是 `http://路由器IP:8788/m3u`。

> 早期版本自带的管理网页 `/admin` 已移除（`/admin` 会 302 回 LuCI）。配置管理统一在 LuCI，避免同一份配置两处维护。

---

## 三、安装

### 方式 A：OpenWrt SDK 打包（推荐）

把本目录放到 SDK 的 `package/` 下编译：

```sh
cp -r luci-app-migu-iptv package/
make package/luci-app-migu-iptv/compile V=s
# 产物：bin/packages/.../luci-app-migu-iptv_1.2.0-1_all.ipk
```

路由器上安装：

```sh
apk add --allow-untrusted luci-app-migu-iptv_1.2.0-1_all.ipk
# 老版本 OpenWrt 用：opkg install luci-app-migu-iptv_1.2.0-1_all.ipk
```

### 方式 B：手动部署

需要把 4 类文件放到位（缺一 LuCI 菜单就不出现）：

```sh
# 1) 流媒体后端 + 服务脚本 + 配置
cp files/usr/share/ucode/migu.uc      /usr/share/ucode/migu.uc
cp files/etc/init.d/migu              /etc/init.d/migu && chmod +x /etc/init.d/migu
cp files/etc/config/migu              /etc/config/migu

# 2) LuCI 菜单与权限（这两步决定菜单能否出现）
cp files/usr/share/luci/menu.d/luci-app-migu-iptv.json  /usr/share/luci/menu.d/
cp files/usr/share/rpcd/acl.d/luci-app-migu-iptv.json   /usr/share/rpcd/acl.d/

# 3) LuCI 页面
mkdir -p /www/luci-static/resources/view/migu
cp files/www/luci-static/resources/view/migu/*.js /www/luci-static/resources/view/migu/

# 4) rpcd 后端接口（LuCI 的状态/控制/测速靠它）
cp files/usr/share/rpcd/ucode/migu    /usr/share/rpcd/ucode/migu

# 5) 生效
/etc/init.d/rpcd restart
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
/etc/init.d/migu enable
/etc/init.d/migu start
```

依赖（缺一不可）：`ucode`、`ucode-mod-fs`、`ucode-mod-uloop`、`ucode-mod-socket`、`ucode-mod-uci`、`curl`、`openssl-util`、`rpcd`、`luci-base`。

```sh
apk add ucode ucode-mod-fs ucode-mod-uloop ucode-mod-socket ucode-mod-uci curl openssl-util rpcd luci-base
```

---

## 四、配置（`/etc/config/migu`）

| 选项 | 默认 | 说明 |
| --- | --- | --- |
| `enabled` | `1` | 服务开关 |
| `port` | `8788` | 监听端口 |
| `host` | `0.0.0.0` | 监听地址（`0.0.0.0` 允许局域网访问） |
| `userId` | 空 | 咪咕账号 ID（空 = 游客，最高 540p） |
| `token` | 空 | 咪咕登录令牌（等同登录态，勿外传） |
| `rateType` | `3` | 2=标清540p / 3=高清720p / 4=蓝光1080p(VIP) / 7=原画(VIP) / 9=4K(VIP) |
| `enableH265` | `1` | H.265（部分设备只有声无画时关） |
| `enableHDR` | `1` | HDR |
| `cacheMinutes` | `360` | 频道列表缓存分钟数 |
| `debug` | `0` | 调试日志 |

超出账号权益时会自动降级到咪咕愿意给的档位（例如游客要 4K 会一路降到 540p）。

---

## 五、获取咪咕 token

`userId` + `token` 是咪咕的登录态。两种取法：

1. **浏览器**：登录咪咕后，按 F12 打开开发者工具 → Network 面板 → 找发往
   `play.miguvideo.com` 的请求 → 看请求头里的 `UserId` 和 `UserToken`。
2. **咪咕 App**：登录后用抓包工具（如 HttpCanary / Stream）抓
   `play.miguvideo.com` 请求的 `UserId` / `UserToken` 头。

把这两个值填进 LuCI「设置 → 咪咕账号」保存即可。**token 等同账号密码，只在自家路由器保存。**

> 两项要**同时填或同时留空**：只填一个会在服务端被拒（返回明确错误）。

---

## 六、TV-BOX 使用

1. 打开 IPTV 播放器（TiviMate / IPTV Pro / Kodi 等）。
2. 添加远程播放列表，地址填 `http://路由器IP:8788/m3u`（LuCI 状态页可直接点选复制）。
3. 频道按「央视 / 卫视 / 地方 / 体育 / 影视 / 综艺 / 新闻 / 纪实 / 少儿 / 教育 / 熊猫」分组显示（**央视排最前，CCTV1 开头**，符合正常电视台排序习惯），点开即播。

> 说明：频道在**播放时**才实时取流，流地址短期有效、自动续期；播放器切台 / 重连时会重新走 `/ch/<pID>` 取新地址。

---

## 七、CCTV5 与体育频道说明

咪咕对 **CCTV5（含 CCTV5+）在播出版权体育赛事时段会做版权屏蔽**（接口返回
`COPYRIGHT_SHIELD_INVALID`，提示「节目播出调整」）。这是咪咕服务端的时段性限制：

- **游客模式**：CCTV5 播版权赛事时**完全取不到流**，非赛事时段可看标清 540p；
  CCTV5+、CCTV1 等其它频道不受影响。
- **已登录账号**：实测配好账号（VIP 档位）后 CCTV5 可正常取流，返回
  `mgsp-*.live.miguvideo.com/.../cctv5hdnew/...` 的 302；后续是否需要体育会员取决于咪咕当时的版权策略。

本项目如实转发「你已有权限的流」，不绕过版权校验。取流失败时，LuCI 的
「运行状态 → 频道测试」会给出 `该频道受版权限制，需登录咪咕体育会员后观看`
的明确提示，而非含糊报错。

---

## 八、核心算法（逆向自参考项目）

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

## 九、文件结构

```
luci-app-migu-iptv/
├── Makefile
├── README.md
├── LICENSE
└── files/
    ├── etc/
    │   ├── config/migu                        # UCI 配置模板
    │   └── init.d/migu                        # procd 服务脚本
    ├── usr/share/
    │   ├── ucode/migu.uc                      # 流媒体后端（/m3u /txt /ch/ /health）
    │   ├── rpcd/ucode/migu                    # rpcd 插件：LuCI 的状态/控制/测试接口
    │   ├── rpcd/acl.d/luci-app-migu-iptv.json # LuCI 权限（uci + ubus migu）
    │   └── luci/menu.d/luci-app-migu-iptv.json# LuCI 菜单（服务 → 咪咕直播）
    └── www/luci-static/resources/view/migu/
        ├── config.js                          # 设置页
        └── status.js                          # 运行状态页
```

---

## 十、安全提示

- `token` 是咪咕登录态，等同账号密码，**不要**发到公网、不要提交到公开仓库。
- 服务端口（默认 8788）默认监听 `0.0.0.0`，同网段内任何人都能取流；如需限制改
  「设置 → 监听地址」或配合防火墙。
- 蓝光 / 原画 / 4K 以及体育会员频道需要**付费 VIP**，本项目只负责「转发你已有权限的流」，不绕过、不破解咪咕的会员校验。
