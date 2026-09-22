'use strict';
'require view';
'require uci';
'require poll';

return view.extend({
	load: function () {
		return Promise.all([
			uci.load('migu'),
		]);
	},

	render: function () {
		var port = uci.get('migu', 'main', 'port') || '8788';
		var enabled = uci.get('migu', 'main', 'enabled') || '1';
		var rateType = uci.get('migu', 'main', 'rateType') || '3';
		var userId = uci.get('migu', 'main', 'userId') || '';
		var hasToken = !!uci.get('migu', 'main', 'token');
		var adminPw = uci.get('migu', 'main', 'adminPassword') || '';

		var rateNames = { '2': '标清 540p', '3': '高清 720p', '4': '蓝光 1080p(VIP)', '7': '原画(VIP)', '9': '4K(VIP)' };

		var m3uUrl = 'http://' + location.hostname + ':' + port + '/m3u';

		var E = [];
		E.push(E('h2', {}, _('咪咕直播')));
		E.push(E('p', {}, _('把咪咕视频直播频道转成 TV-BOX 可订阅的 M3U 播放列表。')));

		var tbl = E('div', { 'class': 'cbi-section' }, [
			E('div', { 'class': 'cbi-section-descr' }, _('服务状态与订阅地址')),
			E('table', { 'class': 'cbi-section-table' }, [
				E('tr', {}, [E('td', { 'class': 'cbi-value-title' }, _('服务')), E('td', {}, enabled === '0' ? _('已禁用') : _('已启用'))]),
				E('tr', {}, [E('td', { 'class': 'cbi-value-title' }, _('监听端口')), E('td', {}, port)]),
				E('tr', {}, [E('td', { 'class': 'cbi-value-title' }, _('画质')), E('td', {}, rateNames[rateType] || rateType)]),
				E('tr', {}, [E('td', { 'class': 'cbi-value-title' }, _('咪咕账号')), E('td', {}, userId ? (userId.substring(0, 3) + '…（' + (hasToken ? '已填 token' : '无 token') + '）') : _('游客模式（最高 540p）'))]),
				E('tr', {}, [E('td', { 'class': 'cbi-value-title' }, _('管理页')), E('td', {}, E('a', { 'href': m3uUrl.replace('/m3u', '/admin'), 'target': '_blank' }, adminPw ? _('打开（需密码）') : _('打开（免登录）')))]),
			])
		]);

		var sub = E('div', { 'class': 'cbi-section' }, [
			E('div', { 'class': 'cbi-section-descr' }, _('在 TV-BOX 播放器（TiviMate / IPTV Pro / Kodi）中添加下面地址')),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('M3U 订阅')),
				E('div', { 'class': 'cbi-value-field' }, E('input', { 'class': 'cbi-input-text', 'readonly': 'readonly', 'value': m3uUrl, 'onclick': 'this.select()' })),
			])
		]);

		E.push(tbl);
		E.push(sub);
		E.push(E('p', { 'class': 'cbi-section-descr' }, _('提示：频道在播放时才实时取流；token 等同登录态，请在管理页配置。')));
		return E;
	},
});
