// 咪咕取流算法独立验证脚本（游客模式）
// 验证：频道列表 → playurl 签名 → ddCalcu 解密 → 302 最终流地址
// 运行：ucode /tmp/migu-test.uc

import { popen, error } from 'fs';

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

function shquote(s) {
	return "'" + replace('' + s, "'", "'\\''") + "'";
}

// MD5 小写十六进制。输入都是数字/字母，安全。
function md5(s) {
	let r = sh("printf '%s' " + shquote(s) + " | openssl dgst -md5 | awk '{print $2}'");
	if (!r) return '';
	return trim(r);
}

// GET 请求，返回 body 字符串。headers 是数组（值形式）。
function httpGet(url, headers) {
	let cmd = 'curl -s -m 20';
	for (let h in headers)
		cmd += ' -H ' + shquote(h);
	cmd += ' ' + shquote(url);
	return sh(cmd);
}

// 取频道列表（分组）
function cateList() {
	let r = httpGet('https://program-sc.miguvideo.com/live/v2/tv-data/1ff892f2b5ab4a79be6e25b69d2f5d05', []);
	if (!r) return null;
	let j = json(r);
	if (!j || !j.body || !j.body.liveList) return null;
	return j.body.liveList;
}

// playurl：游客或带 token
function getAndroidURL(pid, rateType, userId, token) {
	let ts = time() * 1000;
	let appVersion = '26000370';
	let headers = [
		'AppVersion: 2600037000',
		'TerminalId: android',
		'X-UP-CLIENT-CHANNEL-ID: 2600037000-99000-200300220100002',
	];
	if (pid != '641886683' && pid != '641886773')
		push(headers, 'appCode: miguvideo_default_android');
	if (rateType != 2 && userId != '' && token != '') {
		push(headers, 'UserId: ' + userId);
		push(headers, 'UserToken: ' + token);
	}
	let str = '' + ts + pid + appVersion;
	let m = md5(str);
	let suffix = '3ce941cc3cbc40528bfd1c64f9fdf6c0migu0123';
	let sign = md5(m + suffix);
	let salt = 1230024;
	let url = 'https://play.miguvideo.com/playurl/v1/play/playurl' +
		'?sign=' + sign + '&rateType=' + rateType + '&contId=' + pid +
		'&timestamp=' + ts + '&salt=' + salt + '&flvEnable=true&super4k=true';
	let resp = httpGet(url, headers);
	if (!resp) return { url: '', raw: '' };
	let j = json(resp);
	return { url: (j && j.body && j.body.urlInfo) ? (j.body.urlInfo.url || '') : '', raw: resp, rid: (j && j.rid) ? ('' + j.rid) : '' };
}

// ddCalcu 解密（android）
function ddCalcuURL(puDataURL, pid, rateType, userId) {
	let idx = index(puDataURL, '&puData=');
	if (idx < 0) return '';
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

	let dateStr = trim(sh('date +%Y%m%d'));
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

// 跟随 302 取最终地址
function resolveFinal(url) {
	for (let i = 0; i < 6; i++) {
		let r = sh("curl -s -m 10 -o /dev/null -w '%{redirect_url}' " + shquote(url));
		let loc = trim(r || '');
		if (loc == '') break;
		url = loc;
	}
	return url;
}

// ============ 主流程 ============
printf('===== 咪咕取流链路验证（游客模式）=====\n\n');

printf('[1] 拉取频道分组…\n');
let cates = cateList();
if (!cates) {
	printf('  失败：频道列表接口无响应\n');
	exit(1);
}
let totalCate = length(cates);
printf('  分组数：%d\n', totalCate);
for (let c in cates) {
	if (c.name == '热门') continue;
	printf('    - %s (vomsID=%s)\n', c.name, c.vomsID);
}

// 选「央视」分组拉频道
printf('\n[2] 拉取「央视」分组频道…\n');
let yspVoms = '';
for (let c in cates) if (c.name == '央视') { yspVoms = c.vomsID; break; }
if (yspVoms == '') {
	// 回退到第一个非热门的
	for (let c in cates) if (c.name != '热门') { yspVoms = c.vomsID; break; }
}
let catResp = httpGet('https://program-sc.miguvideo.com/live/v2/tv-data/' + yspVoms, []);
let cat = json(catResp || '{}');
let chans = (cat && cat.body && cat.body.dataList) ? cat.body.dataList : [];
printf('  频道数：%d\n', length(chans));
if (length(chans) == 0) {
	printf('  失败：无频道\n');
	exit(1);
}
let sample = null;
for (let ch in chans) {
	if (ch.name && ch.pID) { sample = ch; break; }
}
printf('  取样频道：%s (pID=%s)\n', sample.name, sample.pID);
if (sample.pics && sample.pics.highResolutionH)
	printf('  台标：%s\n', sample.pics.highResolutionH);

printf('\n[3] playurl 取流（rateType=3 游客）…\n');
let r = getAndroidURL(sample.pID, 3, '', '');
printf('  rid=%s\n', r.rid);
printf('  urlInfo.url 长度=%d\n', length(r.url));
if (r.url == '') {
	printf('  取流失败，原始响应前 500 字节：\n');
	printf('  %s\n', substr(r.raw, 0, 500));
	exit(1);
}
printf('  原始加密 URL 前 120 字节：%s…\n', substr(r.url, 0, 120));

printf('\n[4] ddCalcu 解密…\n');
let dec = ddCalcuURL(r.url, sample.pID, 3, '');
printf('  解密 URL 长度=%d\n', length(dec));
printf('  含 ddCalcu=%s\n', (index(dec, '&ddCalcu=') >= 0) ? '是' : '否');

printf('\n[5] 跟随 302 取最终流地址…\n');
let fin = resolveFinal(dec);
printf('  最终地址长度=%d\n', length(fin));
printf('  前 160 字节：%s\n', substr(fin, 0, 160));

printf('\n[6] 校验最终地址可访问…\n');
let code = trim(sh("curl -s -m 12 -o /dev/null -w '%{http_code}' " + shquote(fin)) || '');
printf('  HTTP 状态：%s\n', code);

printf('\n===== 完成 =====\n');
