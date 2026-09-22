#!/usr/bin/ucode
// ============================================================
// migu.uc — 咪咕直播源转发（OpenWrt 原生实现，无 Node/Docker 依赖）
//
// 在路由器上监听一个 HTTP 端口，把咪咕视频的直播频道转成 TV-BOX 能直接
// 订阅的标准 M3U 播放列表，并提供「按需取流」端点 /ch/<pID>：
//   1. /m3u、/txt —— 输出频道列表（分组、台标、频道名）
//   2. /ch/<pID>    —— 播放时按需换取咪咕流地址，302 重定向到最终 HLS
//   3. /admin       —— 管理页：填咪咕 userId / token、选画质、测试频道
//
// 画质说明：
//   游客（不填账号）最高 540p；免费账号到 720p；蓝光 1080p / 原画 / 4K 需 VIP。
//   token 是咪咕登录态，等同账号密码，务必只在自家路由器上保存。
//
// 参考实现：github.com/akiralereal/iptv（Node.js 版），本项目用 ucode 重写，
// 保留其核心算法：频道列表接口 + playurl 签名 + ddCalcu 解密 + 302 跟随。
//
// 用法: ucode /usr/share/ucode/migu.uc
// 配置: /etc/config/migu (UCI)
// ============================================================

'use strict';

import { readfile, writefile, popen, access, mkdir, error, unlink } from 'fs';
import * as socket from 'socket';
import * as uloop from 'uloop';
import * as uci from 'uci';

// ---------- 日志 ----------
function logMsg(level, msg) {
	printf('[migu] %s: %s\n', level, msg);
}
function logInfo(msg) { logMsg('info', msg); }
function logErr(msg) { logMsg('error', msg); }

// ---------- 常量 ----------
const APP_NAME = '咪咕直播';
const APP_VERSION = '1.1.0';
const DEFAULT_PORT = 8788;

// 分组显示顺序：按正常电视台习惯，央视（CCTV1 开头）排最前，其余靠后。
// 未列出的分组按咪咕原始顺序追加到末尾。
const GROUP_ORDER = ['央视', '卫视', '地方', '体育', '影视', '综艺', '新闻', '纪实', '少儿', '教育', '熊猫'];

// 版权 / 会员限制的友好提示（用于取流失败时给用户看得懂的原因）
const ERR_HINT = {
	'COPYRIGHT_SHIELD_INVALID': '该频道受版权限制，需登录咪咕体育会员后观看',
	'TIPS_NEED_MEMBER': '该频道需要咪咕会员权限',
	'PROGRAM_OFFLINE': '节目已下线或暂未播出',
};

// ---------- 全局状态 ----------
let cfg = null;            // 运行时配置
let connections = [];      // 活跃连接
let sessions = {};         // 管理页会话 token -> 过期时间戳
let chanCache = { at: 0, cates: null, channels: null };  // 频道列表缓存
let streamCache = {};      // pid -> { url, at } 取流结果短缓存

// ---------- 配置 ----------
function loadConfig() {
	let c = {
		enabled: '1',
		port: DEFAULT_PORT,
		host: '0.0.0.0',
		userId: '',
		token: '',
		rateType: '3',
		enableH265: '1',
		enableHDR: '1',
		adminPassword: '',
		cacheMinutes: '360',
		debug: '0',
	};

	let ctx = uci.cursor();
	let all = ctx.get_all('migu') || {};
	let main = all.main || {};

	for (let k in main) {
		if (main[k] === '' || main[k] === null) continue;
		c[k] = main[k];
	}

	c.port = +c.port || DEFAULT_PORT;
	c.rateType = +c.rateType || 3;
	if (c.rateType < 2 || c.rateType > 9) c.rateType = 3;
	c.enabled = (('' + c.enabled) !== '0');
	c.enableH265 = (('' + c.enableH265) !== '0');
	c.enableHDR = (('' + c.enableHDR) !== '0');
	c.cacheMinutes = +c.cacheMinutes || 360;
	c.userId = '' + (c.userId || '');
	c.token = '' + (c.token || '');
	c.adminPass = '' + (c.adminPassword || '');
	c.isGuest = (c.userId === '' || c.token === '');

	return c;
}

// ---------- 基础工具 ----------
function shquote(s) {
	return "'" + replace('' + s, "'", "'\\''") + "'";
}

// 执行 shell 命令，返回 stdout 或 null
function sh(cmd) {
	let buf = '';
	try {
		let p = popen(cmd, 'r');
		if (!p) return null;
		let c;
		while ((c = p.read(16384)) !== null && length(c) > 0) buf += c;
		p.close();
	} catch (e) {
		return null;
	}
	return buf;
}

// MD5 小写十六进制（输入需为数字/字母，否则会被单引号破坏）
function md5hex(s) {
	let r = sh("printf '%s' " + shquote(s) + " | openssl dgst -md5 | awk '{print $2}'");
	if (!r) return '';
	return trim(r);
}

// GET 请求，返回 body 字符串或 null。headers 为值数组（"Name: value"）。
function httpGet(url, headers) {
	let cmd = 'curl -s -m 20';
	for (let h in headers)
		cmd += ' -H ' + shquote(h);
	cmd += ' ' + shquote(url);
	return sh(cmd);
}

// 跟随 302 重定向，返回最终 URL（最多 6 跳）
function resolveFinal(url) {
	for (let i = 0; i < 6; i++) {
		let r = sh("curl -s -m 10 -o /dev/null -w '%{redirect_url}' " + shquote(url));
		let loc = trim(r || '');
		if (loc === '') break;
		url = loc;
	}
	return url;
}

// ---------- 咪咕核心 ----------

// 频道分组列表
function cateList() {
	let r = httpGet('https://program-sc.miguvideo.com/live/v2/tv-data/1ff892f2b5ab4a79be6e25b69d2f5d05', []);
	if (!r) return null;
	let j;
	try { j = json(r); } catch (e) { return null; }
	if (!j || !j.body || !j.body.liveList) return null;
	return j.body.liveList;
}

// 某分组下的频道
function channelList(vomsID) {
	let r = httpGet('https://program-sc.miguvideo.com/live/v2/tv-data/' + vomsID, []);
	if (!r) return null;
	let j;
	try { j = json(r); } catch (e) { return null; }
	if (!j || !j.body || !j.body.dataList) return null;
	return j.body.dataList;
}

// 拉取全部频道（带缓存）。返回 [{name, dataList:[{name,pID,pics}]}]
function allChannels() {
	let now = time();
	if (chanCache.cates && chanCache.channels && (now - chanCache.at) < (cfg.cacheMinutes * 60)) {
		return chanCache.channels;
	}
	let cates = cateList();
	if (!cates) {
		// 有缓存就用旧缓存兜底
		if (chanCache.channels) return chanCache.channels;
		return [];
	}
	let groups = [];
	for (let cate in cates) {
		if (!cate || !cate.name || cate.name === '热门') continue;
		let chans = channelList(cate.vomsID);
		if (!chans) chans = [];
		// 分组内按 name 去重
		let seen = {};
		let uniq = [];
		for (let ch in chans) {
			if (!ch || !ch.name || ch.pID === null || ch.pID === '') continue;
			let key = '' + ch.name;
			if (seen[key]) continue;
			seen[key] = true;
			push(uniq, ch);
		}
		if (length(uniq) > 0) push(groups, { name: cate.name, dataList: uniq });
	}
	// 按正常电视台习惯重排分组（央视在前 → CCTV1 开头）
	let ordered = [];
	for (let gn in GROUP_ORDER) {
		for (let g in groups) {
			if (g.name === gn) { push(ordered, g); break; }
		}
	}
	for (let g in groups) {
		let found = false;
		for (let o in ordered) if (o.name === g.name) { found = true; break; }
		if (!found) push(ordered, g);
	}
	groups = ordered;
	chanCache = { at: now, cates: cates, channels: groups };
	return groups;
}

// 请求 playurl 接口，返回解析后的 JSON 或 null
function requestPlayurl(pid, rt, withOtt, userId, token, h265, hdr) {
	let ts = time() * 1000;
	let appVersion = '26000370';
	let headers = [
		'AppVersion: 2600037000',
		'TerminalId: android',
		'X-UP-CLIENT-CHANNEL-ID: 2600037000-99000-200300220100002',
	];
	if (pid != '641886683' && pid != '641886773')
		push(headers, 'appCode: miguvideo_default_android');
	if (rt != 2 && userId != '' && token != '') {
		push(headers, 'UserId: ' + userId);
		push(headers, 'UserToken: ' + token);
	}

	let str = '' + ts + pid + appVersion;
	let m = md5hex(str);
	let sign = md5hex(m + '3ce941cc3cbc40528bfd1c64f9fdf6c0migu0123');

	let params = '?sign=' + sign + '&rateType=' + rt + '&contId=' + pid +
		'&timestamp=' + ts + '&salt=1230024&flvEnable=true&super4k=true' +
		(withOtt ? '&ott=true' : '') +
		(hdr ? '&4kvivid=true&2Kvivid=true&vivid=2' : '') +
		(h265 ? '&h265N=true' : '');

	let respStr = httpGet('https://play.miguvideo.com/playurl/v1/play/playurl' + params, headers);
	if (!respStr) return null;
	try { return json(respStr); } catch (e) { return null; }
}

// ddCalcu 解密（android 端）
function ddCalcuURL(puDataURL, pid, rateType, userId) {
	let idx = index(puDataURL, '&puData=');
	if (idx < 0) return puDataURL;  // 没有 puData 就原样返回
	let puData = substr(puDataURL, idx + 8);
	let keys = 'cdabyzwxkl';
	let w0 = 'v', w3 = 'a';
	let id = userId || '';
	if (id != '') {
		let n = int(substr(id, 7, 1));
		if (n >= 0 && n < 10) w0 = substr(keys, n, 1);
	}
	if (rateType == 2) w0 = 'v';
	if (length(id) > 3 && length(id) <= 8) w0 = 'e';

	let dateStr = trim(sh('date +%Y%m%d') || '');
	if (dateStr === '') dateStr = '20260101';
	let out = '';
	let n = int(length(puData) / 2);
	for (let i = 0; i < n; i++) {
		out += substr(puData, length(puData) - i - 1, 1);
		out += substr(puData, i, 1);
		if (i == 1) out += w0;
		else if (i == 2) out += substr(keys, int(substr(dateStr, 0, 1)), 1);
		else if (i == 3) out += substr(keys, int(substr(pid, 6, 1)), 1);
		else if (i == 4) out += w3;
	}
	return puDataURL + '&ddCalcu=' + out + '&sv=10004&ct=android';
}

// 取流：playurl + 降级 + ddCalcu + 302，返回最终流地址
function getAndroidURL(pid, rateType, userId, token, h265, hdr) {
	let resp = requestPlayurl(pid, rateType, rateType == 9, userId, token, h265, hdr);
	if (!resp) return { url: '', rid: '', err: 'playurl 接口无响应' };

	// 4K 被大屏策略拒绝时，先按手机策略再要一次
	if (resp.rid == 'TIPS_NEED_MEMBER' && rateType == 9) {
		resp = requestPlayurl(pid, 9, false, userId, token, h265, hdr);
	}
	// 超出账号权益，按咪咕愿意给的档位降级
	if (resp && resp.rid == 'TIPS_NEED_MEMBER') {
		let offered = (resp.body && resp.body.urlInfo) ? (+resp.body.urlInfo.rateType || 0) : 0;
		let fallback = (offered >= 4) ? 4 : 3;
		resp = requestPlayurl(pid, fallback, false, userId, token, h265, hdr);
		if (resp && resp.rid == 'TIPS_NEED_MEMBER' && fallback != 3) {
			resp = requestPlayurl(pid, 3, false, userId, token, h265, hdr);
		}
	}

	if (!resp || !resp.body || !resp.body.urlInfo || !resp.body.urlInfo.url) {
		let rid = resp ? ('' + resp.rid) : '';
		let hint = ERR_HINT[rid];
		let msg = hint ? hint : (resp ? ('' + (resp.message || rid || '未知错误')) : '无响应');
		return { url: '', rid: rid, err: msg };
	}

	let encUrl = resp.body.urlInfo.url;
	let pid2 = (resp.body.content && resp.body.content.contId) ? ('' + resp.body.content.contId) : pid;
	let dec = ddCalcuURL(encUrl, pid2, rateType, userId);
	let fin = resolveFinal(dec);
	return {
		url: (fin !== '' ? fin : dec),
		rid: '' + resp.rid,
		rateType: +resp.body.urlInfo.rateType || rateType,
		logined: (resp.body.auth && resp.body.auth.logined) ? true : false,
	};
}

// 带缓存的取流（每 60 秒）
function resolveStream(pid) {
	let now = time();
	let hit = streamCache[pid];
	if (hit && hit.url && (now - hit.at) < 60) return hit;
	let r = getAndroidURL(pid, cfg.rateType, cfg.userId, cfg.token, cfg.enableH265, cfg.enableHDR);
	let entry = { url: r.url, rid: r.rid, rateType: r.rateType, at: now, err: r.err };
	streamCache[pid] = entry;
	return entry;
}

// ---------- HTTP 工具 ----------
function httpStatusText(code) {
	let map = {
		'200': 'OK', '302': 'Found', '400': 'Bad Request', '401': 'Unauthorized',
		'404': 'Not Found', '405': 'Method Not Allowed', '500': 'Internal Server Error',
		'502': 'Bad Gateway', '503': 'Service Unavailable',
	};
	return map[code] || 'Unknown';
}

function closeConn(conn) {
	if (conn.closed) return;
	conn.closed = true;
	try { if (conn.handle) conn.handle.cancel(); } catch (e) { }
	try { if (conn.procHandle) conn.procHandle.cancel(); } catch (e) { }
	try { if (conn.proc) conn.proc.close(); } catch (e) { }
	try { conn.sock.close(); } catch (e) { }
}

function rawResponse(conn, status, ctype, body, extraHeaders) {
	if (conn.closed) return;
	body = '' + (body || '');
	let extra = '';
	if (extraHeaders) {
		for (let k in extraHeaders)
			extra += k + ': ' + extraHeaders[k] + '\r\n';
	}
	let head = sprintf(
		'HTTP/1.1 %d %s\r\n' +
		'Content-Type: %s\r\n' +
		'Content-Length: %d\r\n' +
		'Connection: close\r\n' +
		'Cache-Control: no-store\r\n' +
		'Access-Control-Allow-Origin: *\r\n' +
		'%s' +
		'\r\n',
		status, httpStatusText(status), ctype, length(body), extra
	);
	conn.sock.send(head + body);
	closeConn(conn);
}

function jsonResponse(conn, status, obj) {
	rawResponse(conn, status, 'application/json; charset=utf-8', sprintf('%.J', obj), null);
}

function textResponse(conn, status, body) {
	rawResponse(conn, status, 'text/html; charset=utf-8', body, null);
}

function redirectResponse(conn, location) {
	if (conn.closed) return;
	let head = sprintf(
		'HTTP/1.1 302 Found\r\n' +
		'Location: %s\r\n' +
		'Content-Length: 0\r\n' +
		'Connection: close\r\n' +
		'Access-Control-Allow-Origin: *\r\n' +
		'\r\n',
		location
	);
	conn.sock.send(head);
	closeConn(conn);
}

function parseHead(head) {
	let lines = split(head, '\r\n');
	let first = lines[0] || '';
	let m = match(first, /^(\S+)\s+(\S+)/);
	let method = m ? m[1] : 'GET';
	let path = m ? m[2] : '/';
	let headers = {};
	for (let i = 1; i < length(lines); i++) {
		let ln = lines[i];
		let idx = index(ln, ':');
		if (idx <= 0) continue;
		let k = lc(trim(substr(ln, 0, idx)));
		let v = trim(substr(ln, idx + 1));
		headers[k] = v;
	}
	return { method: method, path: path, headers: headers };
}

function parseJsonBody(body) {
	if (type(body) !== 'string' || length(body) === 0) return {};
	try {
		let j = json(body);
		if (type(j) === 'object' && j !== null) return j;
	} catch (e) { }
	return {};
}

// ---------- 播放列表 ----------
function buildM3u(host) {
	let groups = allChannels();
	let lines = ['#EXTM3U x-tvg-url=""'];
	for (let g in groups) {
		for (let ch in g.dataList) {
			let logo = (ch.pics && ch.pics.highResolutionH) ? ch.pics.highResolutionH : '';
			let url = 'http://' + host + '/ch/' + ch.pID;
			push(lines, '#EXTINF:-1 tvg-id="' + ch.name + '" tvg-name="' + ch.name + '"' +
				(logo !== '' ? ' tvg-logo="' + logo + '"' : '') +
				' group-title="' + g.name + '",' + ch.name);
			push(lines, url);
		}
	}
	return join('\n', lines) + '\n';
}

function buildTxt(host) {
	let groups = allChannels();
	let lines = [];
	for (let g in groups) {
		for (let ch in g.dataList) {
			push(lines, ch.name + ',' + 'http://' + host + '/ch/' + ch.pID);
		}
	}
	return join('\n', lines) + '\n';
}

// ---------- 管理页 ----------

// 生成会话 token（用 openssl 产生真随机值；ucode 没有全局 rand()）
function newSession() {
	let t = trim(sh("openssl rand -hex 16") || '');
	if (t === '') t = sprintf('%d%d', time(), length(sessions));
	sessions[t] = time() + 86400;
	return t;
}

function validSession(req) {
	let ck = req.headers['cookie'] || '';
	let m = match(ck, /migu_admin=([^;\s]+)/);
	if (!m) return false;
	let t = m[1];
	if (sessions[t] && sessions[t] > time()) return true;
	return false;
}

// 删除会话（ucode 无 delete 运算符，重建表）
function deleteSession(t) {
	let ns = {};
	for (let k in sessions)
		if (k !== t) ns[k] = sessions[k];
	sessions = ns;
}

function adminEnabled() {
	return cfg.adminPass !== '';
}

function adminCss() {
	return ':root{--bg:#0f1115;--panel:#171a21;--panel2:#1e222b;--line:#2a2f3a;--fg:#e6e9ef;--dim:#9aa4b2;--accent:#4c8dff;--accent2:#3a6fd8;--ok:#35c26b;--warn:#e0a83a;--err:#e5544b}' +
		'*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI","Noto Sans CJK SC","Microsoft YaHei",sans-serif}' +
		'.wrap{max-width:1000px;margin:0 auto;padding:20px}header{display:flex;align-items:center;gap:12px;padding:16px 20px;background:var(--panel);border-bottom:1px solid var(--line);flex-wrap:wrap}' +
		'header h1{font-size:17px;margin:0;font-weight:600}.sp{flex:1}.badge{font-size:12px;padding:2px 9px;border-radius:99px;border:1px solid var(--line);background:var(--panel2);color:var(--dim)}' +
		'.badge.ok{color:var(--ok);border-color:#1e4a30}.badge.warn{color:var(--warn);border-color:#4a3d1e}.card{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:18px;margin-bottom:16px}' +
		'.card h2{font-size:14px;margin:0 0 4px;font-weight:600}.card .desc{color:var(--dim);font-size:12.5px;margin:0 0 14px}label{display:block;font-size:12.5px;color:var(--dim);margin-bottom:5px}' +
		'input[type=text],input[type=password],input[type=number],select{width:100%;padding:9px 11px;background:var(--bg);color:var(--fg);border:1px solid var(--line);border-radius:7px;font-size:13.5px;font-family:inherit}' +
		'input:focus,select:focus{outline:none;border-color:var(--accent)}.field{margin-bottom:14px}button{cursor:pointer;border:1px solid var(--line);background:var(--panel2);color:var(--fg);padding:8px 15px;border-radius:7px;font-size:13px;font-family:inherit}' +
		'button:hover{border-color:var(--accent)}button.primary{background:var(--accent);border-color:var(--accent);color:#fff;font-weight:500}code,.mono{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12.5px}' +
		'.kv{display:flex;justify-content:space-between;padding:7px 0;border-bottom:1px solid var(--line)}.kv:last-child{border-bottom:none}.kv .k{color:var(--dim)}' +
		'.toast{position:fixed;right:18px;bottom:18px;z-index:99}.toast div{padding:11px 15px;border-radius:8px;background:var(--panel2);border:1px solid var(--line);margin-top:8px;font-size:13px}' +
		'.toast div.ok{border-color:#1e4a30;color:#9fe8bd}.toast div.err{border-color:#4a201e;color:#ffb3ae}' +
		'.login{max-width:370px;margin:11vh auto;padding:0 20px}.login .card{padding:26px}.login h1{font-size:19px;margin:0 0 6px;font-weight:600}' +
		'.hint{color:var(--dim);font-size:12px;margin-top:7px}.row{display:flex;gap:12px;flex-wrap:wrap}.row>div{flex:1;min-width:190px}' +
		'.sw{position:relative;display:inline-block;width:38px;height:21px;vertical-align:middle}.sw input{opacity:0;width:0;height:0}.sw span{position:absolute;inset:0;background:#39404d;border-radius:99px;transition:.2s}' +
		'.sw span:before{content:"";position:absolute;width:15px;height:15px;left:3px;top:3px;background:#fff;border-radius:50%;transition:.2s}.sw input:checked+span{background:var(--ok)}.sw input:checked+span:before{transform:translateX(17px)}';
}

// 转义 HTML 属性（管理页表单回填用）
function escAttr(s) {
	return replace(replace(replace(replace('' + s, '&', '&amp;'), '"', '&quot;'), '<', '&lt;'), '>', '&gt;');
}

// 下拉选项（画质）
function opt(v, label, cur) {
	return '<option value="' + v + '"' + (cur == v ? ' selected' : '') + '>' + label + '</option>';
}

function adminPage(req, loggedIn) {
	let groups = allChannels();
	let total = 0;
	for (let g in groups) total += length(g.dataList);

	let statusBadge = cfg.isGuest
		? '<span class="badge warn">游客模式（最高 540p）</span>'
		: '<span class="badge ok">已填账号（最高受 VIP 决定）</span>';

	let m3uHost = req.headers['host'] || (cfg.host + ':' + cfg.port);

	let h = '';
	h += '<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">';
	h += '<meta name="viewport" content="width=device-width,initial-scale=1">';
	h += '<title>' + APP_NAME + ' · 管理</title><style>' + adminCss() + '</style></head><body>';
	h += '<header><h1>' + APP_NAME + '</h1>' + statusBadge +
		'<span class="badge">v' + APP_VERSION + '</span><span class="sp"></span>';
	if (loggedIn) h += '<a href="/admin/logout" style="color:var(--dim);text-decoration:none;font-size:13px">退出</a>';
	h += '</header><div class="wrap">';

	// 订阅地址卡片
	h += '<div class="card"><h2>订阅地址（TV-BOX 用）</h2>';
	h += '<p class="desc">在 IPTV 播放器（TiviMate / IPTV Pro / Kodi 等）里添加下面的地址即可。</p>';
	h += '<div class="kv"><span class="k">M3U 播放列表</span><code id="m3u">http://' + m3uHost + '/m3u</code></div>';
	h += '<div class="kv"><span class="k">TXT 播放列表</span><code>http://' + m3uHost + '/txt</code></div>';
	h += '<div class="kv"><span class="k">频道总数</span><span>' + total + ' 个（' + length(groups) + ' 个分组）</span></div>';
	h += '<p class="hint">频道在播放时才实时取流，地址短期有效、自动续期。</p></div>';

	// 账号配置卡片
	h += '<div class="card"><h2>咪咕账号（决定画质上限）</h2>';
	h += '<p class="desc">不填 = 游客模式（最高 540p）；填免费账号到 720p；VIP 到蓝光 / 原画 / 4K。</p>';
	h += '<div class="field"><label for="fUser">咪咕账号 ID（userId）</label>';
	h += '<input type="text" id="fUser" placeholder="留空为游客" value="' + escAttr(cfg.userId) + '"></div>';
	h += '<div class="field"><label for="fToken">咪咕 Token</label>';
	h += '<input type="password" id="fToken" placeholder="留空为游客（等同登录态，勿外传）" value="' + escAttr(cfg.token) + '"></div>';
	h += '<div class="field"><label for="fRate">画质</label><select id="fRate">';
	h += opt(2, '标清 540p', cfg.rateType);
	h += opt(3, '高清 720p', cfg.rateType);
	h += opt(4, '蓝光 1080p（需 VIP）', cfg.rateType);
	h += opt(7, '原画 1080p+（需 VIP）', cfg.rateType);
	h += opt(9, '4K 2160p（需 VIP）', cfg.rateType);
	h += '</select></div>';
	h += '<div class="row"><div><label class="row" style="align-items:center;gap:9px;cursor:pointer;color:var(--fg)"><span class="sw"><input type="checkbox" id="fH265"' + (cfg.enableH265 ? ' checked' : '') + '><span></span></span><span>H.265（部分设备只有声无画时关闭）</span></label></div>';
	h += '<div><label class="row" style="align-items:center;gap:9px;cursor:pointer;color:var(--fg)"><span class="sw"><input type="checkbox" id="fHDR"' + (cfg.enableHDR ? ' checked' : '') + '><span></span></span><span>HDR</span></label></div></div>';
	h += '<p class="hint">token 获取：浏览器登录咪咕后，F12 网络面板找 play.miguvideo.com 请求的 UserId / UserToken 请求头；或从咪咕 App 抓包。</p>';
	h += '<button class="primary" onclick="saveCfg()">保存配置</button></div>';

	// 测试卡片
	h += '<div class="card"><h2>测试取流</h2><p class="desc">输入频道 ID（pID）测试能否取到流。</p>';
	h += '<div class="row"><div><label for="fTest">频道 pID</label><input type="text" id="fTest" placeholder="如 608807420"></div>';
	h += '<div style="align-self:flex-end"><button class="primary" onclick="testChan()">测试</button></div></div>';
	h += '<pre id="testOut" class="mono" style="background:var(--bg);border:1px solid var(--line);border-radius:7px;padding:10px;min-height:40px;white-space:pre-wrap;word-break:break-all;font-size:12px;margin-top:10px">等待测试…</pre></div>';

	h += '</div><div class="toast" id="toast"></div><script>';
	h += 'function esc(s){return (s||"").replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;");}';
	h += 'function toast(m,k){var d=document.createElement("div");d.className=k||"";d.textContent=m;document.getElementById("toast").appendChild(d);setTimeout(function(){d.remove();},3200);}';
	h += 'function api(p,b){return fetch("/admin/api/"+p,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(b||{})}).then(function(r){return r.json();});}';
	h += 'function saveCfg(){var b={userId:document.getElementById("fUser").value.trim(),token:document.getElementById("fToken").value.trim(),rateType:document.getElementById("fRate").value,enableH265:document.getElementById("fH265").checked?"1":"0",enableHDR:document.getElementById("fHDR").checked?"1":"0"};';
	h += 'api("config/save",b).then(function(r){if(r.ok){toast("已保存","ok");}else{toast("失败："+(r.error||""),"err");}});}';
	h += 'function testChan(){var pid=document.getElementById("fTest").value.trim();var o=document.getElementById("testOut");o.textContent="取流中…";';
	h += 'api("test",{pid:pid}).then(function(r){o.textContent=JSON.stringify(r,null,2);});}';
	h += '</script></body></html>';
	return h;
}

function loginPage() {
	let h = '<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">';
	h += '<meta name="viewport" content="width=device-width,initial-scale=1">';
	h += '<title>' + APP_NAME + ' · 登录</title><style>' + adminCss() + '</style></head><body>';
	h += '<div class="login"><div class="card"><h1>' + APP_NAME + '</h1>';
	h += '<p class="sub" style="color:var(--dim);font-size:13px;margin:0 0 20px">请输入管理密码</p>';
	h += '<div class="field"><input type="password" id="pw" placeholder="管理密码"></div>';
	h += '<button class="primary" style="width:100%" onclick="doLogin()">登录</button></div></div>';
	h += '<script>function doLogin(){var p=document.getElementById("pw").value;fetch("/admin/login",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({password:p})}).then(function(r){return r.json();}).then(function(j){if(j.ok){location.href="/admin";}else{alert("密码错误");}});}</script>';
	h += '</body></html>';
	return h;
}

// ---------- 处理器 ----------
function handleHealth(conn) {
	let groups = allChannels();
	let total = 0;
	for (let g in groups) total += length(g.dataList);
	jsonResponse(conn, 200, {
		ok: true,
		service: 'luci-app-migu-iptv',
		version: APP_VERSION,
		channels: total,
		groups: length(groups),
		guest: cfg.isGuest,
		rateType: cfg.rateType,
		cacheAge: time() - chanCache.at,
	});
}

function handleM3u(conn, host) {
	let body = buildM3u(host);
	rawResponse(conn, 200, 'application/x-mpegurl; charset=utf-8', body, null);
}

function handleTxt(conn, host) {
	let body = buildTxt(host);
	rawResponse(conn, 200, 'text/plain; charset=utf-8', body, null);
}

function handleChannel(conn, pid) {
	if (pid === '' || match(pid, /[^0-9]/)) {
		jsonResponse(conn, 400, { ok: false, error: '频道 ID 必须是数字' });
		return;
	}
	let r = resolveStream(pid);
	if (r.url === '') {
		logErr('channel ' + pid + ' 取流失败: ' + r.err);
		jsonResponse(conn, 502, { ok: false, error: r.err, rid: r.rid });
		return;
	}
	redirectResponse(conn, r.url);
}

function handleAdminApi(conn, req, path, body) {
	let j = parseJsonBody(body);

	if (path === '/admin/login' && req.method === 'POST') {
		let pw = '' + (j.password || '');
		if (adminEnabled() && pw === cfg.adminPass) {
			let t = newSession();
			let head = sprintf(
				'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\nSet-Cookie: migu_admin=%s; Path=/; HttpOnly\r\nAccess-Control-Allow-Origin: *\r\n\r\n',
				length('{"ok":true}'), t
			);
			conn.sock.send(head + '{"ok":true}');
			closeConn(conn);
		} else {
			jsonResponse(conn, 401, { ok: false, error: '密码错误' });
		}
		return;
	}

	// 其余管理接口需要会话
	if (adminEnabled() && !validSession(req)) {
		jsonResponse(conn, 401, { ok: false, error: '未登录' });
		return;
	}

	if (path === '/admin/api/state' && req.method === 'POST') {
		let groups = allChannels();
		let total = 0;
		for (let g in groups) total += length(g.dataList);
		jsonResponse(conn, 200, {
			ok: true,
			channels: total,
			groups: length(groups),
			guest: cfg.isGuest,
			rateType: cfg.rateType,
			userId: cfg.userId !== '' ? (substr(cfg.userId, 0, 3) + '…') : '',
			hasToken: cfg.token !== '',
			enableH265: cfg.enableH265,
			enableHDR: cfg.enableHDR,
			version: APP_VERSION,
		});
		return;
	}

	if (path === '/admin/api/config/save' && req.method === 'POST') {
		let ctx = uci.cursor();
		if ('userId' in j) ctx.set('migu', 'main', 'userId', '' + (j.userId || ''));
		if ('token' in j) ctx.set('migu', 'main', 'token', '' + (j.token || ''));
		if ('rateType' in j) {
			let rt = +j.rateType;
			if (rt >= 2 && rt <= 9) ctx.set('migu', 'main', 'rateType', '' + rt);
		}
		if ('enableH265' in j) ctx.set('migu', 'main', 'enableH265', (j.enableH265 === '1' || j.enableH265 === true || j.enableH265 === 1) ? '1' : '0');
		if ('enableHDR' in j) ctx.set('migu', 'main', 'enableHDR', (j.enableHDR === '1' || j.enableHDR === true || j.enableHDR === 1) ? '1' : '0');
		let rc = ctx.commit('migu');
		cfg = loadConfig();
		// 清空流缓存，让新画质/账号立即生效
		streamCache = {};
		if (rc !== true && rc !== 0 && rc !== null) {
			jsonResponse(conn, 500, { ok: false, error: 'uci commit 失败' });
			return;
		}
		logInfo('config saved (guest=' + cfg.isGuest + ', rateType=' + cfg.rateType + ')');
		jsonResponse(conn, 200, { ok: true });
		return;
	}

	if (path === '/admin/api/test' && req.method === 'POST') {
		let pid = '' + (j.pid || '');
		if (pid === '' || match(pid, /[^0-9]/)) {
			jsonResponse(conn, 400, { ok: false, error: '频道 ID 必须是数字' });
			return;
		}
		let r = getAndroidURL(pid, cfg.rateType, cfg.userId, cfg.token, cfg.enableH265, cfg.enableHDR);
		jsonResponse(conn, 200, {
			ok: r.url !== '',
			url: r.url,
			rid: r.rid,
			rateType: r.rateType,
			logined: r.logined,
			error: r.err,
		});
		return;
	}

	jsonResponse(conn, 404, { ok: false, error: 'no such admin endpoint' });
}

// ---------- 分发 ----------
function dispatch(conn, head, body) {
	let req = parseHead(head);
	let method = req.method;
	let qIdx = index(req.path, '?');
	let path = (qIdx >= 0) ? substr(req.path, 0, qIdx) : req.path;
	let host = req.headers['host'] || (cfg.host + ':' + cfg.port);

	// /health 始终放行
	if (method === 'GET' && path === '/health') {
		handleHealth(conn);
		return;
	}

	// /m3u /txt
	if (method === 'GET' && path === '/m3u') {
		handleM3u(conn, host);
		return;
	}
	if (method === 'GET' && path === '/txt') {
		handleTxt(conn, host);
		return;
	}

	// /ch/<pid> —— 取流，始终放行（TV-BOX 直接访问）
	if (method === 'GET' && substr(path, 0, 4) === '/ch/') {
		handleChannel(conn, substr(path, 4));
		return;
	}

	// /admin 管理页
	if (path === '/admin' || substr(path, 0, 6) === '/admin') {
		if (path === '/admin' && method === 'GET') {
			if (adminEnabled() && !validSession(req)) {
				textResponse(conn, 200, loginPage());
			} else {
				textResponse(conn, 200, adminPage(req, true));
			}
			return;
		}
		if (path === '/admin/logout' && method === 'GET') {
			let ck = req.headers['cookie'] || '';
			let m = match(ck, /migu_admin=([^;\s]+)/);
			if (m) { let t = m[1]; deleteSession(t); }
			redirectResponse(conn, '/admin');
			return;
		}
		if (substr(path, 0, 11) === '/admin/api/' || path === '/admin/login') {
			handleAdminApi(conn, req, path, body);
			return;
		}
		textResponse(conn, 404, '<h1>404</h1>');
		return;
	}

	// / 根路径 → 跳管理页
	if (method === 'GET' && path === '/') {
		redirectResponse(conn, '/admin');
		return;
	}

	jsonResponse(conn, 404, { ok: false, error: 'not found' });
}

// ---------- 服务端循环 ----------
function onData(conn) {
	if (conn.closed) return;
	let chunk;
	try { chunk = conn.sock.recv(8192); } catch (e) { closeConn(conn); return; }
	if (chunk === null) { closeConn(conn); return; }
	if (length(chunk) === 0) { closeConn(conn); return; }

	conn.buf += chunk;
	if (conn.headerEnd < 0) {
		let idx = index(conn.buf, '\r\n\r\n');
		if (idx < 0) {
			if (length(conn.buf) > 65536) closeConn(conn);
			return;
		}
		conn.headerEnd = idx + 4;
		conn.head = substr(conn.buf, 0, idx);
		let cl = match(conn.head, /\r\nContent-Length:\s*([0-9]+)/i);
		conn.bodyLen = cl ? +cl[1] : 0;
	}
	let got = length(conn.buf) - conn.headerEnd;
	if (got < conn.bodyLen) return;

	let body = substr(conn.buf, conn.headerEnd, conn.bodyLen);
	try {
		dispatch(conn, conn.head, body);
	} catch (e) {
		logErr('dispatch error: ' + e);
		jsonResponse(conn, 500, { ok: false, error: '' + e });
	}
}

function onAccept(listenSock) {
	let addr = {};
	let peer = listenSock.accept(addr, socket.SOCK_CLOEXEC);
	if (!peer) return;
	try { peer.setopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, true); } catch (e) { }

	let conn = {
		sock: peer, buf: '', handle: null, headersSent: false, closed: false,
		bodyLen: 0, headerEnd: -1, ip: (addr && addr.address) ? addr.address : '?',
	};
	push(connections, conn);
	conn.handle = uloop.handle(peer, () => onData(conn), uloop.ULOOP_READ | uloop.ULOOP_BLOCKING);
}

function main() {
	cfg = loadConfig();
	if (!cfg.enabled) {
		logInfo('service disabled in config');
		return;
	}

	uloop.init();
	let listenSock = socket.create(socket.AF_INET, socket.SOCK_STREAM, 0);
	if (!listenSock) {
		logErr('socket create failed: ' + socket.error());
		return;
	}
	listenSock.setopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, true);
	if (!listenSock.bind(cfg.host + ':' + cfg.port)) {
		logErr('bind failed on ' + cfg.host + ':' + cfg.port + ': ' + listenSock.error());
		return;
	}
	if (!listenSock.listen(64)) {
		logErr('listen failed: ' + listenSock.error());
		return;
	}
	uloop.handle(listenSock, () => onAccept(listenSock), uloop.ULOOP_READ | uloop.ULOOP_BLOCKING);

	logInfo(sprintf('listening on %s:%d (guest=%s, rateType=%d)',
		cfg.host, cfg.port, cfg.isGuest ? 'yes' : 'no', cfg.rateType));

	// 预热频道列表：启动 1.5 秒后后台拉取一次，让首个 /m3u 请求不等待。
	// 拉取失败只记日志，不让预热错误把服务进程带崩。
	uloop.timer(1500, () => {
		try {
			let g = allChannels();
			let total = 0;
			for (let x in g) total += length(x.dataList);
			logInfo('channel cache warmed: ' + total + ' channels in ' + length(g) + ' groups');
		} catch (e) {
			logErr('warmup failed: ' + e);
		}
	});

	uloop.run();
	uloop.done();
}

main();
