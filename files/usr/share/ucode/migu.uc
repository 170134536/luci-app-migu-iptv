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
const APP_VERSION = '1.2.0';
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

// 说明：本服务只做流媒体后端（/health /m3u /txt /ch/<pid>），
// 不再自带管理网页 —— 配置与管理全部在 LuCI 的「服务 → 咪咕直播」里完成，
// 由 /usr/share/rpcd/ucode/migu 提供 ubus 接口支撑。
// 这样同一份 UCI 配置只有一个维护入口，避免两套界面互相覆盖。

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

	// 老管理页地址已被 LuCI 取代，统一跳转，避免书签失效后看到 404
	if (path === '/admin' || substr(path, 0, 6) === '/admin') {
		redirectResponse(conn, '/');
		return;
	}

	// 根路径 → 回 LuCI 的咪咕直播页（管理入口只有 LuCI 一个）
	if (method === 'GET' && path === '/') {
		let luciHost = host;
		let ci = index(luciHost, ':');
		if (ci >= 0) luciHost = substr(luciHost, 0, ci);
		redirectResponse(conn, 'http://' + luciHost + '/cgi-bin/luci/admin/services/migu');
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
