'use strict';
'require view';
'require form';
'require rpc';
'require ui';
'require uci';

// 咪咕直播 —— 设置页
//
// 原生 LuCI 表单：所有选项直接绑定 UCI 的 migu.main，
// 由 LuCI 自己的「保存 & 应用」按钮写盘。
// 额外钩子：应用后自动重启 migu 服务，使新配置立即生效
// （否则要等用户手动去系统 → 启动项里重启）。
//
// 注意：token / adminPassword 用 form.Value 的 password 属性渲染成密码框，
// 避免在页面上明文显示登录态。

var callRestart = rpc.declare({
	object: 'migu',
	method: 'restart',
	expect: { }
});

var callStatus = rpc.declare({
	object: 'migu',
	method: 'status',
	expect: { }
});

var callGenToken = rpc.declare({
	object: 'migu',
	method: 'gentoken',
	expect: { }
});

// 取表单里某个 option 的 input 元素。
//
// cbi 的控件 id 规则不统一（实测结论）：
//   - Flag（勾选框）：渲染成 <input id="cbXXXXXXXX" data-widget-id="widget.cbid.<sec>.<opt>">
//     真正的关联键是 data-widget-id，不是 id。
//   - Value / ListValue：渲染成 <input id="widget.cbid.<sec>.<opt>">
// 所以两种都要能取到，先按 data-widget-id 找，再回退到 id。
function inputOf(section, opt) {
	var wid = 'widget.cbid.migu.' + section + '.' + opt;
	return document.querySelector('[data-widget-id="' + wid + '"]')
		|| document.getElementById(wid);
}

// 把值写进 cbi 输入框并触发变更事件，让 LuCI 记录 dirty 状态
function setInput(section, opt, val) {
	var el = inputOf(section, opt);
	if (!el) return false;
	el.value = val;
	el.dispatchEvent(new Event('input', { bubbles: true }));
	el.dispatchEvent(new Event('change', { bubbles: true }));
	return true;
}

// 读取表单当前值（勾选框返回 '1'/'0'）
function getInput(section, opt) {
	var el = inputOf(section, opt);
	if (!el) return '';
	if (el.type === 'checkbox') return el.checked ? '1' : '0';
	return el.value;
}

// 拼接当前浏览器访问路由器时所用的地址（用于示例提示）
function lanBase() {
	var h = window.location.hostname || '192.168.1.1';
	var port = getInput('main', 'port') || '8788';
	return 'http://' + h + ':' + port;
}

return view.extend({
	render: function () {
		var m, s, o;

		m = new form.Map('migu', _('咪咕直播'),
			_('把咪咕视频的直播频道转成 TV-BOX 可订阅的 M3U 播放列表。') +
			_('在下方完成设置后点「保存 & 应用」，服务会自动重启生效。'));

		/* ---------------- 基本设置 ---------------- */
		s = m.section(form.NamedSection, 'main', 'migu', _('基本设置'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('启用服务'),
			_('关闭后停止提供 M3U 订阅与取流接口。'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'port', _('监听端口'),
			_('TV-BOX 订阅地址使用的端口，默认 8788。'));
		o.datatype = 'port';
		o.default = '8788';
		o.rmempty = false;

		o = s.option(form.ListValue, 'host', _('监听地址'),
			_('只有选「所有网络接口」时，电视盒等局域网设备才能访问。'));
		o.value('0.0.0.0', _('所有网络接口（局域网可访问）'));
		o.value('127.0.0.1', _('仅本机（仅用于调试）'));
		o.default = '0.0.0.0';

		o = s.option(form.ListValue, 'rateType', _('画质档位'),
			_('超出账号权益时，咪咕会自动降级到实际可用档位。'));
		o.value('2', _('标清 540p（游客可用）'));
		o.value('3', _('高清 720p（免费账号）'));
		o.value('4', _('蓝光 1080p（需 VIP）'));
		o.value('7', _('原画（需 VIP）'));
		o.value('9', _('4K（需 VIP）'));
		o.default = '3';

		o = s.option(form.Flag, 'enableH265', _('优先 H.265'),
			_('部分电视盒只有声音没有画面时，关闭此项可改用 H.264。'));
		o.default = '1';

		o = s.option(form.Flag, 'enableHDR', _('启用 HDR'));
		o.default = '1';

		o = s.option(form.Value, 'cacheMinutes', _('频道缓存（分钟）'),
			_('频道列表的缓存时长，缓存期内不重复请求咪咕。'));
		o.datatype = 'uinteger';
		o.default = '360';
		o.rmempty = false;

		o = s.option(form.Flag, 'debug', _('调试日志'),
			_('开启后向系统日志写入详细取流过程，排查问题时用。'));
		o.default = '0';

		/* ---------------- 咪咕账号 ---------------- */
		s = m.section(form.NamedSection, 'main', 'migu', _('咪咕账号'));
		s.anonymous = true;
		s.description = _('两项都留空 = 游客模式（最高 540p）。') +
			_('填写后可解锁更高画质；体育频道（CCTV5 等）在版权赛事时段需要体育会员。');

		o = s.option(form.Value, 'userId', _('用户 ID'));
		o.placeholder = _('留空 = 游客模式');
		o.rmempty = true;

		o = s.option(form.Value, 'token', _('登录令牌'));
		o.password = true;
		o.placeholder = _('留空 = 游客模式');
		o.rmempty = true;
		o.description = _('等同登录态，请勿外传，也不要提交到公开仓库。');

		/* ---------------- 外部备用源 ---------------- */
		s = m.section(form.NamedSection, 'main', 'migu', _('外部备用源'));
		s.anonymous = true;
		s.description = _('咪咕取流失败时的降级线路，按顺序依次尝试。') +
			_('CCTV5 等体育频道在赛事时段会被咪咕版权盾锁定，此时自动切换到这里配的源。') +
			_('每行一条，格式：标签|URL（标签可为空）。用 # 开头的行会被忽略。');

		o = s.option(form.TextArea, 'externalSources', _('备用源列表'));
		o.rows = 6;
		o.wrap = true;
		o.placeholder = _('移动tsfile|http://120.238.94.82:9901/tsfile/live/1030_1.m3u8\n' +
			'海外高清|http://74.91.26.218:82/live/cctv5hd.m3u8');
		o.rmempty = true;
		o.validate = function (section_id, value) {
			// 允许为空，但每条必须能解析出 URL
			value = value || '';
			let lines = value.split('\n');
			for (let i = 0; i < lines.length; i++) {
				let ln = lines[i].trim();
				if (ln === '' || ln.charAt(0) === '#') continue;
				let bar = ln.indexOf('|');
				let url = bar > 0 ? ln.substring(bar + 1).trim() : ln;
				if (!url.startsWith('http://') && !url.startsWith('https://'))
					return _('第 ' + (i + 1) + ' 行的 URL 格式无效');
			}
			return true;
		};

		/* ---------------- 公网访问 ---------------- */
		s = m.section(form.NamedSection, 'main', 'migu', _('公网访问'));
		s.anonymous = true;
		s.description = _('默认只允许局域网访问，公网请求会被拒绝。') +
			_('需要在外面（4G/公司网络）看电视时才开启；开启后建议同时设置访问令牌，' +
			  '否则任何人扫到你的地址都能用你的账号带宽。');

		o = s.option(form.Flag, 'publicAccess', _('允许公网访问'),
			_('关闭时：仅局域网与本机可访问，公网请求返回 403。') +
			_('开启时：公网可访问，并按下面的令牌设置决定是否校验。'));
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.Value, 'publicBaseUrl', _('对外访问地址（可选）'),
			_('填你在外网实际访问这个服务用的地址，例如 https://migu.example.com。') +
			_('留空则按请求里的 Host 自动推断，通常直接留空即可。'));
		o.placeholder = _('留空 = 自动推断（推荐）');
		o.rmempty = true;

		o = s.option(form.Value, 'publicToken', _('访问令牌'),
			_('公网访问时校验的密码，建议用下方按钮随机生成。') +
			_('留空则公网可无密码访问，风险较高。'));
		o.password = true;
		o.placeholder = _('留空 = 公网无需令牌（不推荐）');
		o.rmempty = true;

		// 自定义按钮：生成随机令牌
		o = s.option(form.Button, '_gen_token', _('生成令牌'));
		o.inputtitle = _('随机生成一个 32 位令牌');
		o.inputstyle = 'action';
		o.onclick = function () {
			return L.resolveDefault(callGenToken(), {}).then(function (r) {
				if (!r || !r.ok || !r.token) {
					ui.addNotification(null, E('p', {}, [
						_('令牌生成失败：') + ((r && r.error) || _('未知错误'))
					]), 'error');
					return;
				}
				if (!setInput('main', 'publicToken', r.token)) {
					ui.addNotification(null, E('p', {}, [
						_('未能写入表单，请手动复制：') + r.token
					]), 'warning');
					return;
				}
				ui.addNotification(null, E('div', {}, [
					E('p', {}, [ _('已生成令牌并填入输入框，点「保存 & 应用」生效。') ]),
					E('p', { 'style': 'margin-top:4px' }, [
						E('code', { 'style': 'user-select:all' }, [r.token])
					])
				]), 'info');
			}).catch(function (e) {
				ui.addNotification(null, E('p', {}, [ _('生成失败：') + e ]), 'error');
			});
		};

		// 地址格式说明（纯展示，不写盘）
		//
		// 注意：LuCI 的 E(tag, attrs, children) 把 attrs 里的键当【HTML 属性】写入，
		// 传 { innerHTML: '...' } 只会渲染出 <div innerhtml="..."> 而不会解析成元素。
		// 因此这里必须用嵌套 E() 构建表格，不能用 HTML 字符串。
		o = s.option(form.DummyValue, '_addr_help', _('地址格式说明'));
		o.rawhtml = true;
		o.cfgvalue = function () {
			var base = lanBase();
			var tok = getInput('main', 'publicToken') || '你的令牌';
			var pub = getInput('main', 'publicBaseUrl') || 'https://你的域名';
			var port = getInput('main', 'port') || '8788';

			function tr(cells, isHead) {
				return E('tr', { 'class': 'tr' }, cells.map(function (c) {
					return E(isHead ? 'th' : 'td',
						{ 'class': isHead ? 'th' : 'td' }, [c]);
				}));
			}
			function code(t) { return E('code', {}, [t]); }
			function table(rows) {
				return E('table', { 'class': 'table',
					'style': 'margin-bottom:12px' }, rows);
			}

			return E('div', { 'style': 'line-height:1.9;font-size:13px' }, [
				E('p', { 'style': 'margin:0 0 8px' }, [
					E('b', {}, [ _('服务对外提供两种订阅格式：') ])
				]),
				table([
					tr([ _('用途'), _('地址格式'), _('举例') ], true),
					tr([
						E('span', {}, [
							_('M3U 播放列表'), E('br'),
							E('small', {}, [ _('（大多数 TV-BOX / Kodi / 影视仓）') ])
						]),
						code('http://地址:端口/m3u'),
						code(base + '/m3u')
					]),
					tr([
						E('span', {}, [
							_('TXT 频道表'), E('br'),
							E('small', {}, [ _('（部分直播软件）') ])
						]),
						code('http://地址:端口/txt'),
						code(base + '/txt')
					]),
					tr([
						_('健康检查'),
						code('http://地址:端口/health'),
						code(base + '/health')
					])
				]),

				E('p', { 'style': 'margin:0 0 6px' }, [
					E('b', {}, [ _('公网访问时，令牌有两种写法（二选一）：') ])
				]),
				table([
					tr([ _('写法'), _('格式'), _('举例') ], true),
					tr([
						E('span', {}, [ _('路径前缀'), E('br'),
							E('small', {}, [ _('（推荐，兼容性最好）') ]) ]),
						E('span', {}, [ code('地址/'), E('b', {}, [ _('令牌') ]), code('/m3u') ]),
						code(pub + '/' + tok + '/m3u')
					]),
					tr([
						_('查询参数'),
						E('span', {}, [ code('地址/m3u?token='), E('b', {}, [ _('令牌') ]) ]),
						code(pub + '/m3u?token=' + tok)
					])
				]),

				E('p', { 'style': 'margin:0 0 6px' }, [
					E('b', {}, [ _('地址里的「地址」写什么：') ])
				]),
				E('ul', { 'style': 'margin:0 0 12px;padding-left:20px' }, [
					E('li', {}, [
						E('b', {}, [ _('局域网电视盒') ]), '：',
						_('写路由器的局域网 IP，例如 '), code(base), ' ',
						_('（就是你现在访问的这个地址）')
					]),
					E('li', {}, [
						E('b', {}, [ _('外网设备') ]), '：',
						_('写你在「对外访问地址」里填的域名；若留空则写端口映射后实际能访问到的公网地址，例如 '),
						code('http://你的公网IP:' + port)
					]),
					E('li', {}, [
						E('b', {}, [ _('不要') ]), ' ',
						_('写 '), code('0.0.0.0'), _(' 或 '), code('127.0.0.1'),
						_(' —— 前者不是可访问地址，后者只有路由器自己能连')
					])
				]),

				E('p', { 'style': 'margin:0 0 6px' }, [
					E('b', {}, [ _('注意事项：') ])
				]),
				E('ul', { 'style': 'margin:0;padding-left:20px' }, [
					E('li', {}, [
						_('公网访问需要自己在路由器上做'), E('b', {}, [ _('端口映射') ]),
						_('（防火墙 → 端口转发）把外面的端口转到本机 '), code(port),
						_('，本插件不自动开放防火墙')
					]),
					E('li', {}, [
						_('「监听地址」必须选'), E('b', {}, [ _('所有网络接口') ]),
						_('，选「仅本机」时公网与局域网都连不上')
					]),
					E('li', {}, [
						_('取流地址由服务器按'), E('b', {}, [ _('你访问时用的地址') ]),
						_('自动生成，所以局域网和外网可以各用各自的地址订阅，互不影响')
					])
				])
			]);
		};

		return m.render();
	},

	// 覆盖 view 级钩子：先走 LuCI 原生「保存 → 应用」，再重启服务
	handleSaveApply: function (ev, mode) {
		return this.handleSave(ev).then(function () {
			return ui.changes.apply(mode == '0');
		}).then(function () {
			ui.addNotification(null, E('p', {}, [ _('正在重启咪咕直播服务…') ]));
			return callRestart();
		}).then(function (res) {
			var ok = res && res.ok;
			ui.addNotification(null, E('p', {}, [
				ok
					? _('设置已保存，服务已重启并生效。')
					: _('设置已保存，但服务重启失败，请到「状态」页查看日志。')
			]), ok ? 'info' : 'warning');
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, [ _('应用失败：') + e ]), 'error');
		});
	}
});
