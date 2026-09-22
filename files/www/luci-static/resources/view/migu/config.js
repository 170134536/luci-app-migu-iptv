'use strict';
'require view';
'require form';
'require rpc';
'require ui';

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
