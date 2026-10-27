// 后台管理页共用导航栏：菜单顺序、登录守卫、会话与退出的唯一定义处
// 各页只放 <div id="petAdminNav"></div> 占位，不要再复制 <header class="navbar">
(function () {
  // 登录守卫：未登录直接回登录页（本脚本以同步方式放在各页 <head>，早于 body 渲染）
  if (!localStorage.getItem('petAdminSession') && location.pathname !== '/admin/login') {
    location.replace('/admin/login');
  }

  // 菜单顺序只在这里定义一次；高亮按 pathname 自动推导，页面无需传参
  var MENU = [
    { href: '/admin', label: '在线宠物' },
    { href: '/admin/codes', label: '激活码管理' },
    { href: '/admin/social', label: '宠物对话' },
    { href: '/admin/status', label: '服务器状态' },
    { href: '/admin/files', label: '文件管理' }
  ];

  // 会话令牌：各页 api() 继续用全局 session() 取值
  window.session = function () { return localStorage.getItem('petAdminSession') || ''; };

  // 退出：先清本地态再通知服务端，网络异常不阻塞回登录页
  window.logout = function () {
    var token = window.session();
    localStorage.removeItem('petAdminSession');
    localStorage.removeItem('petAdminSessionExp');
    return fetch('/api/admin/logout', { method: 'POST', headers: { 'X-Session-Token': token } })
      .catch(function (e) { /* 忽略网络异常 */ })
      .then(function () { location.href = '/admin/login'; });
  };

  function currentPath() {
    return location.pathname.replace(/\/+$/, '');
  }

  function renderNav() {
    var holder = document.getElementById('petAdminNav');
    if (!holder) return;

    var header = document.createElement('header');
    header.className = 'navbar navbar-expand-md navbar-dark bg-dark d-print-none';

    var links = MENU.map(function (item) {
      var active = currentPath() === item.href;
      var cls = 'nav-link' + (active ? ' active fw-bold' : '');
      return '<a class="' + cls + '" href="' + item.href + '">' + item.label + '</a>';
    }).join('');

    header.innerHTML =
      '<div class="container-xl">' +
      '<span class="navbar-brand">🐾 cute pet 后台管理</span>' +
      '<div class="navbar-nav flex-row ms-auto align-items-center">' +
      links +
      '<a class="nav-link ms-3 text-warning" href="#" id="petAdminLogout">退出登录</a>' +
      '</div>' +
      '</div>';

    // 原位替换占位 div：保证 <header> 仍是 .page 的直接子节点且为 :first-child
    // （保住 tabler 的 .page>.navbar:first-child 圆角规则与 flex 布局语义）
    holder.replaceWith(header);
    header.querySelector('#petAdminLogout').addEventListener('click', function (e) {
      e.preventDefault();
      window.logout();
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', renderNav);
  } else {
    renderNav();
  }
})();
