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
//
// 关于 COPYRIGHT_SHIELD_INVALID：这句提示以前写的是「需登录咪咕体育会员」，
// 但实测这个 rid 出现在 **CCTV5** 上而 CCTV5+ 与其余 7 个体育频道全部正常，
// 说明它**不是账号权限问题**，而是内容侧的时段性版权限制 —— 咪咕返回的
// playCode 403001006 原文是「节目播出调整，换个内容看看吧！」。
// 咪咕在有独家赛事转播（五大联赛 / NBA 等）的时段会锁 CCTV5，
// 无赛事时段则正常放行。提示必须说实话，否则用户会去白折腾会员。
const ERR_HINT = {
	'COPYRIGHT_SHIELD_INVALID': '该频道当前受版权限制（通常是有独家赛事转播的时段被锁），过一段时间再试或改用 CCTV5+ 观看',
	'TIPS_NEED_MEMBER': '该频道需要咪咕会员权限',
	'PROGRAM_OFFLINE': '节目已下线或暂未播出',
};

// ---------- 全局状态 ----------
let cfg = null;            // 运行时配置
let connections = [];      // 活跃连接
let chanCache = { at: 0, cates: null, channels: null };  // 频道列表缓存
let streamCache = {};      // pid -> { url, at } 取流结果短缓存
// 外部源可用性缓存：url -> { ok, at }
// ok=true 缓存 300 秒（源可用，复用结果）；ok=false 缓存 60 秒（避免反复打失效源）
let extSourceCache = {};

// ---------- 配置 ----------

// 解析外部源文本 → [{label, url}]
//
// 接受两种写法（兼容 LuCI TextArea 的手工输入）：
//   1. 每行一条：    标签|URL
//                    标签2|URL2
//   2. 用 ; 或换行混合分隔：标签|URL;标签2|URL2
// 空行、# 开头的注释行、缺 URL 的行直接丢弃。
//
// 注意：必须定义在 loadConfig 之前 —— ucode 没有函数提升，
// 定义在调用点之后会报 "access to undeclared variable"。
function parseExternalSources(text) {
	let out = [];
	if (!text || text === '') return out;

	// 先按换行切成行，再把行内可能残留的分号当分隔符处理
	let lines = split(text, '\n');
	for (let ln in lines) {
		ln = trim(ln);
		if (ln === '' || substr(ln, 0, 1) === '#') continue;

		// 一行里可能有多条，用 ; 再切
		let parts = split(ln, ';');
		for (let p in parts) {
			p = trim(p);
			if (p === '') continue;

			let barIdx = index(p, '|');
			let label, url;
			if (barIdx > 0) {
				label = trim(substr(p, 0, barIdx));
				url = trim(substr(p, barIdx + 1));
			} else {
				// 没写标签，整行当 URL（容忍用户偷懒）
				label = '';
				url = p;
			}
			// URL 必须有 http(s) 前缀，否则是无效输入
			if (url === '' || (index(url, 'http://') !== 0 && index(url, 'https://') !== 0))
				continue;
			push(out, { label: label, url: url });
		}
	}
	return out;
}

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
		// 公网访问相关
		publicAccess: '0',      // 是否允许公网访问
		publicToken: '',        // 公网访问令牌（空 = 不校验）
		publicBaseUrl: '',      // 自定义对外地址（空 = 按请求 Host 自动推断）
		publicProxyHint: '',    // 备注：公网地址由谁提供（仅展示用）
		// 外部备用源：每行一条，格式「标签|URL」，按顺序作为降级链
		externalSources: '',
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
	c.publicAccess = (('' + c.publicAccess) === '1');
	c.publicToken = '' + (c.publicToken || '');
	c.publicBaseUrl = trim('' + (c.publicBaseUrl || ''));
	// 去掉用户可能粘贴进来的结尾斜杠，避免拼出 //ch/
	while (length(c.publicBaseUrl) > 0 &&
		substr(c.publicBaseUrl, length(c.publicBaseUrl) - 1) === '/')
		c.publicBaseUrl = substr(c.publicBaseUrl, 0, length(c.publicBaseUrl) - 1);
	c.publicProxyHint = '' + (c.publicProxyHint || '');

	// 解析外部备用源列表
	//
	// 格式：option externalSources 存多行文本，每行一条「标签|URL」。
	// 按顺序作为降级链 —— 咪咕取流失败后依次尝试。
	// 每行必须含 | 分隔符，缺标签的用空标签。
	c.extSources = parseExternalSources('' + (c.externalSources || ''));

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
//
// 关键规则：**失败结果绝不写入缓存**。
// 咪咕的版权盾（COPYRIGHT_SHIELD_INVALID / 403001006）是**间歇性**的：
// 赛事转播时段封锁，非赛事时段放开，且不同 CDN 边缘节点的鉴权状态
// 可能不同步。如果失败也缓存 60 秒，就会出现「咪咕已经放开、播放器
// 还在拿到缓存的错误」这种假故障 —— 用户看到的就是"这个台一直播不了"。
//
// 所以：只有拿到真实流地址才缓存；失败直接返回，下次请求立刻重试。
function resolveStream(pid) {
	let now = time();
	let hit = streamCache[pid];
	if (hit && hit.url && (now - hit.at) < 60) return hit;

	let r = getAndroidURL(pid, cfg.rateType, cfg.userId, cfg.token, cfg.enableH265, cfg.enableHDR);

	// 首次失败：紧跟一次重试。
	// 版权盾的判定带概率性（多节点状态不同步），同一 pid 连发两次请求
	// 命中不同节点的概率不小，重试能明显降低偶发失败率。
	if (!r.url) {
		let r2 = getAndroidURL(pid, cfg.rateType, cfg.userId, cfg.token, cfg.enableH265, cfg.enableHDR);
		if (r2.url) r = r2;
	}

	let entry = { url: r.url, rid: r.rid, rateType: r.rateType, at: now, err: r.err };

	// 只在成功时落缓存；失败结果一次性丢弃
	if (r.url) streamCache[pid] = entry;
	else delete streamCache[pid];

	return entry;
}

// ---------- 外部备用源 ----------
//
// 咪咕取流失败（典型：赛事时段版权盾锁 CCTV5）时，按用户配置的顺序
// 依次尝试外部源。外部源是静态 HLS URL，不走咪咕鉴权流程，直接返回给播放器。
//
// 检查结果带缓存，避免每次请求都去打失效源浪费带宽。
const EXT_OK_TTL = 300;     // 成功缓存 5 分钟
const EXT_FAIL_TTL = 60;    // 失败缓存 1 分钟

// 检查外部源 URL 是否可达且内容有效。返回 true/false。
//
// 必须同时校验「HTTP 状态」和「响应体含 #EXTM3U」：
// 大量失效 IPTV 源会返回 HTTP 200 + 纯文本错误页（如 "the channel is not exist"），
// 只看状态码会把假源判成可用，导致降级链把用户带到打不开的地址。
// 用 -L 跟随重定向（很多公开源是 302 到真实 HLS），10 秒超时，只取前面一小段。
function checkExternalSource(url) {
	let now = time();
	let hit = extSourceCache[url];
	if (hit) {
		let ttl = hit.ok ? EXT_OK_TTL : EXT_FAIL_TTL;
		if ((now - hit.at) < ttl) return hit.ok;
	}

	let cmd = "curl -s -L -m 10 -r 0-400 -w '\\n__CODE__%{http_code}' " + shquote(url);
	let body = sh(cmd) || '';
	// 从尾部切出状态码，剩下的部分做内容判定
	let ok = false;
	let code = '';
	let mi = rindex(body, '__CODE__');
	if (mi >= 0) {
		code = trim(substr(body, mi + 8));
		body = substr(body, 0, mi);
		ok = (code >= 200 && code < 400) && (index(body, '#EXTM3U') >= 0);
	}

	extSourceCache[url] = { ok: ok, at: now };
	if (!ok) logInfo('外部源不可用: ' + url + ' (HTTP ' + code + '，' + (length(body) === 0 ? '无响应' : '内容非 HLS') + ')');
	return ok;
}

// 按顺序尝试外部源列表，返回第一个可用的 {label, url} 或 null
function tryExternalSources() {
	let list = cfg.extSources;
	if (!list || length(list) === 0) return null;

	for (let i = 0; i < length(list); i++) {
		if (checkExternalSource(list[i].url))
			return list[i];
	}
	return null;
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

function redirectResponse(conn, location, extra) {
	if (conn.closed) return;
	// 注意：ucode 没有 undefined 这个全局变量，只能用 null 和 length() 判断
	let extraLine = '';
	if (extra !== null && type(extra) === 'string' && length(extra) > 0)
		extraLine = 'X-Migu-Fallback: ' + extra + '\r\n';
	let head = sprintf(
		'HTTP/1.1 302 Found\r\n' +
		'Location: %s\r\n' +
		'Content-Length: 0\r\n' +
		'Connection: close\r\n' +
		'Access-Control-Allow-Origin: *\r\n' +
		'%s' +
		'\r\n',
		location, extraLine
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

// ---------- 公网访问控制 ----------
//
// 设计取舍：
//   - 默认（publicAccess=0）只允许内网/本机来源访问，公网请求一律 403。
//     这样即使用户在路由器上做了端口映射，也不会在不知情的情况下把
//     整份频道列表和取流接口暴露到公网。
//   - 显式开启后允许公网访问；若设置了 publicToken，则要求
//     订阅地址与取流地址都带上该令牌（?token=xxx 或 /<token>/ 前缀），
//     防止被人扫到地址后白嫖你的账号带宽。

// 判断 IPv4 是否属于内网/回环/链路本地
function isPrivateV4(ip) {
	if (ip === '') return false;
	let p = split(ip, '.');
	if (length(p) !== 4) return false;
	let a = +p[0], b = +p[1];
	if (a === 10) return true;
	if (a === 172 && b >= 16 && b <= 31) return true;
	if (a === 192 && b === 168) return true;
	if (a === 127) return true;                    // 回环
	if (a === 169 && b === 254) return true;       // 链路本地
	if (a === 100 && b >= 64 && b <= 127) return true; // CGNAT
	if (a >= 224) return true;                     // 组播/保留
	return false;
}

// 判断来源地址是否可信（内网 / 回环 / IPv6 本地）
function isLocalPeer(addr) {
	if (!addr) return false;
	let a = '' + addr;
	// IPv6 映射的 IPv4（::ffff:192.168.1.5）
	let m = match(a, /^::ffff:([0-9.]+)$/i);
	if (m) a = m[1];
	if (index(a, ':') >= 0) {
		// IPv6：回环、唯一本地地址 fc00::/7、链路本地 fe80::/10 视为内网
		let low = lc(a);
		if (low === '::1') return true;
		let head = substr(low, 0, 2);
		if (head === 'fc' || head === 'fd') return true;
		if (substr(low, 0, 3) === 'fe8') return true;
		if (isPrivateV4(a)) return true;
		// 其它 IPv6 一律当作公网，交给开关判定
		return false;
	}
	return isPrivateV4(a);
}

// 从查询串里取参数值
function queryParam(path, name) {
	let q = index(path, '?');
	if (q < 0) return null;
	let qs = substr(path, q + 1);
	let parts = split(qs, '&');
	for (let p in parts) {
		let eq = index(p, '=');
		if (eq < 0) {
			if (p === name) return '';
			continue;
		}
		if (substr(p, 0, eq) === name) return substr(p, eq + 1);
	}
	return null;
}

// 校验公网访问权限
//
// 返回 { allow: true } 或 { allow: false, code: 403, error: '...' }
function checkAccess(conn, peerAddr, path) {
	// 内网来源始终放行（局域网 TV-BOX 不受公网开关影响）
	if (isLocalPeer(peerAddr)) return { allow: true, local: true };

	// 公网来源：未开启开关则拒绝
	if (!cfg.publicAccess) {
		return {
			allow: false,
			code: 403,
			error: '公网访问未开启。请在 LuCI「服务 → 咪咕直播 → 设置 → 公网访问」中开启。',
		};
	}

	// 已开启：若配了令牌则必须匹配
	if (cfg.publicToken !== '') {
		let given = null;
		// 支持两种形式：?token=xxx  或  /<token>/ch/...
		let qp = queryParam(path, 'token');
		if (qp !== null) given = qp;
		if (given === null) {
			// 路径前缀形式：/TOKEN/m3u
			let seg = match(path, /^\/([A-Za-z0-9_-]{8,64})\//);
			if (seg) given = seg[1];
		}
		if (given === null || given !== cfg.publicToken) {
			return {
				allow: false,
				code: 403,
				error: '缺少或错误的访问令牌。请在订阅地址末尾加上 ?token=你的令牌。',
			};
		}
	}

	return { allow: true, local: false };
}

// 生成对外可用的基地址（用于拼 M3U / TXT 里的取流地址）
//
// 优先级：
//   1) 用户自定义的 publicBaseUrl（例如 https://migu.example.com）
//   2) 请求头 Host（最贴合客户端实际访问的地址）
//   3) 配置里的 host:port
//
// 注意：客户端可能通过域名 + 反代路径访问，此时 Host 就是正确答案，
// 所以默认用 Host 而不是写死 IP。
function externalBase(host, access) {
	let base = '';

	if (cfg.publicBaseUrl !== '') {
		base = cfg.publicBaseUrl;
	} else {
		base = 'http://' + host;
	}

	// 公网访问 + 配了令牌 → 用路径前缀形式把令牌编进地址，
	// 这样播放器不需要理解查询参数，兼容性最好
	if (access && access.local === false && cfg.publicToken !== '')
		base = base + '/' + cfg.publicToken;

	return base;
}

// ---------- 播放列表 ----------

// base 是已经算好的对外基地址（可能带令牌前缀），例如
//   http://192.168.69.1:8788        内网访问
//   https://migu.example.com/TOKEN  公网 + 令牌
function buildM3u(base) {
	let groups = allChannels();
	let lines = ['#EXTM3U x-tvg-url=""'];
	for (let g in groups) {
		for (let ch in g.dataList) {
			let logo = (ch.pics && ch.pics.highResolutionH) ? ch.pics.highResolutionH : '';
			let url = base + '/ch/' + ch.pID;
			push(lines, '#EXTINF:-1 tvg-id="' + ch.name + '" tvg-name="' + ch.name + '"' +
				(logo !== '' ? ' tvg-logo="' + logo + '"' : '') +
				' group-title="' + g.name + '",' + ch.name);
			push(lines, url);
		}
	}
	// 追加外部备用源作为独立分组，用户可在 TV-BOX 里手动选择线路
	// pid 编码：9001 = 外部源[0]，9002 = 外部源[1]，依此类推
	// 这样用户既可以用咪咕频道（自动降级到外部源），也可以直接订阅外部源线路
	if (cfg.extSources && length(cfg.extSources) > 0) {
		for (let i = 0; i < length(cfg.extSources); i++) {
			let es = cfg.extSources[i];
			let nm = (es.label !== '') ? ('备用源' + (i + 1) + '-' + es.label) : ('备用源' + (i + 1));
			push(lines, '#EXTINF:-1 tvg-id="' + nm + '" tvg-name="' + nm + '"' +
				' group-title="备用源",' + nm);
			push(lines, base + '/ch/' + (9001 + i));
		}
	}
	return join('\n', lines) + '\n';
}

function buildTxt(base) {
	let groups = allChannels();
	let lines = [];
	for (let g in groups) {
		for (let ch in g.dataList) {
			push(lines, ch.name + ',' + base + '/ch/' + ch.pID);
		}
	}
	// 同样追加外部源
	if (cfg.extSources && length(cfg.extSources) > 0) {
		for (let i = 0; i < length(cfg.extSources); i++) {
			let es = cfg.extSources[i];
			let nm = (es.label !== '') ? ('备用源' + (i + 1) + '-' + es.label) : ('备用源' + (i + 1));
			push(lines, nm + ',' + base + '/ch/' + (9001 + i));
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
		publicAccess: cfg.publicAccess,
		publicTokenSet: cfg.publicToken !== '',
		publicBaseUrl: cfg.publicBaseUrl,
	});
}

function handleM3u(conn, base) {
	let body = buildM3u(base);
	rawResponse(conn, 200, 'application/x-mpegurl; charset=utf-8', body, null);
}

function handleTxt(conn, base) {
	let body = buildTxt(base);
	rawResponse(conn, 200, 'text/plain; charset=utf-8', body, null);
}

// 版权受限时的回落表：pid → 备用 pid
//
// 背景：咪咕对 CCTV5 这类有独家赛事转播的频道，会在赛事时段按内容 ID
// 硬锁（COPYRIGHT_SHIELD_INVALID / playCode 403001006），实测 8 种请求头
// 组合全部无效，属于服务端策略，客户端无法绕过。
//
// 但 CCTV5 和 CCTV5+ 播的是重叠的赛事内容，CCTV5 被锁时 CCTV5+ 通常仍
// 可播（实测本机 CCTV5+ 正常返回 302）。所以这里做一次自动回落，
// 让用户在锁时段至少还能看到比赛，而不是直接吃一个 502。
//
// 回落只在主频道取流失败时发生，成功路径完全不受影响。
const FALLBACK_PID = {
	'641886683': '641886773',   // CCTV5 体育 → CCTV5+ 体育赛事
};

function handleChannel(conn, pid) {
	if (pid === '' || match(pid, /[^0-9]/)) {
		jsonResponse(conn, 400, { ok: false, error: '频道 ID 必须是数字' });
		return;
	}

	// pid >= 9001 = 外部备用源独立频道（用户手动选择的线路）
	//
	// 直连频道按索引精确取源，不做「跳到别的源」那种自作主张的替换 ——
	// 用户在 TV-BOX 里点的是第 N 条线路，就该拿到第 N 条。
	// 但源失效时必须给出明确错误，而不是甩一个打不开的地址让播放器干等：
	// 先探一次，不可用就返回 502 并说明原因（前端会显示「源不可用」而不是黑屏）。
	let extIdx = (+pid) - 9001;
	if (extIdx >= 0 && cfg.extSources && extIdx < length(cfg.extSources)) {
		let es = cfg.extSources[extIdx];
		if (!checkExternalSource(es.url)) {
			logErr('外部源频道 ' + pid + ' 不可用: ' + es.label + ' ' + es.url);
			jsonResponse(conn, 502, {
				ok: false,
				error: sprintf('备用源「%s」当前不可用，请在设置里换一条线路或稍后重试', es.label),
				url: es.url,
			});
			return;
		}
		logInfo('外部源直接访问: ' + es.label + ' ' + es.url);
		redirectResponse(conn, es.url, null);
		return;
	}

	let r = resolveStream(pid);

	// 降级链第一层：咪咕版权盾 → 同源备用 pid（如 CCTV5 → CCTV5+）
	let fellBack = false;
	let srcLabel = '';
	if (r.url === '' && FALLBACK_PID[pid]) {
		let altPid = FALLBACK_PID[pid];
		let r2 = resolveStream(altPid);
		if (r2.url !== '') {
			logInfo(sprintf('channel %s 受版权限制，已回落到 %s', pid, altPid));
			r = r2;
			fellBack = true;
			srcLabel = '咪咕回落(CCTV5+)';
		}
	}

	// 降级链第二层：咪咕完全不可用 → 外部备用源
	if (r.url === '') {
		let ext = tryExternalSources();
		if (ext) {
			logInfo(sprintf('channel %s 咪咕不可用，已切换外部源 [%s]', pid, ext.label));
			r = { url: ext.url, rid: 'EXTERNAL', rateType: cfg.rateType, at: time(), err: '' };
			fellBack = true;
			srcLabel = ext.label;
		}
	}

	if (r.url === '') {
		logErr('channel ' + pid + ' 取流失败: ' + r.err);
		jsonResponse(conn, 502, { ok: false, error: r.err, rid: r.rid });
		return;
	}
	// 回落时把实际来源告诉播放器（自定义头，标准播放器会忽略）
	let fb = fellBack ? (srcLabel !== '' ? ('src=' + srcLabel) : 'fallback') : null;
	redirectResponse(conn, r.url, fb);
}

// ---------- 分发 ----------
function dispatch(conn, head, body) {
	let req = parseHead(head);
	let method = req.method;
	let qIdx = index(req.path, '?');
	let path = (qIdx >= 0) ? substr(req.path, 0, qIdx) : req.path;
	let host = req.headers['host'] || (cfg.host + ':' + cfg.port);

	// 去掉可能存在的令牌路径前缀：/TOKEN/m3u → /m3u
	//
	// 这样公网订阅地址可以写成 https://域名/TOKEN/m3u，
	// 播放器无需理解查询参数，兼容性最好。
	if (cfg.publicToken !== '') {
		let prefix = '/' + cfg.publicToken;
		if (substr(path, 0, length(prefix)) === prefix) {
			let rest = substr(path, length(prefix));
			if (rest === '' || substr(rest, 0, 1) === '/') path = rest;
		}
	}

	// /health 始终放行（用于探活，不含任何隐私信息）
	if (method === 'GET' && path === '/health') {
		handleHealth(conn);
		return;
	}

	// 其余接口先过访问控制
	//
	// 用原始 req.path 做令牌提取（因为上面的 path 已经剥掉前缀了）
	let access = checkAccess(conn, conn.ip, req.path);
	if (!access.allow) {
		logErr('拒绝访问 ' + conn.ip + ' → ' + req.path + '：' + access.error);
		jsonResponse(conn, access.code || 403, {
			ok: false,
			error: access.error,
			hint: cfg.publicAccess ? '' : '内网访问不受影响。',
		});
		return;
	}

	// 对外基地址（拼播放列表里的取流地址用）
	let base = externalBase(host, access);

	// /m3u /txt
	if (method === 'GET' && path === '/m3u') {
		handleM3u(conn, base);
		return;
	}
	if (method === 'GET' && path === '/txt') {
		handleTxt(conn, base);
		return;
	}

	// /ch/<pid> —— 取流，按需 302
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
	if (method === 'GET' && (path === '/' || path === '')) {
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
