'use strict';
const $ = id => document.getElementById(id);
let mode = 'register';
let busy = false;
const messages = {
  invalid_email: '请输入有效的邮箱地址。',
  invalid_password: '密码需要包含 12–128 个字符。',
  password_mismatch: '两次输入的密码不一致，请重新确认。',
  email_exists: '这个邮箱已经注册，可以切换到“已有账户”登录。',
  invalid_credentials: '邮箱或密码不正确，请重新输入。',
  rate_limited: '操作较频繁，请一分钟后再试。',
  auth_busy: '当前登录请求较多，请稍后重试。',
  invalid_request: '请检查填写的信息后再试。',
  invalid_origin: '页面连接已变化，请刷新后重试。'
};
function message(element, text) { element.textContent = text; element.hidden = !text; }
function setBusy(value) {
  busy = value;
  for (const element of document.querySelectorAll('button, input')) element.disabled = value;
  $('submit-label').textContent = value ? (mode === 'register' ? '正在创建账户…' : '正在登录…') : (mode === 'register' ? '创建账户' : '登录');
  $('logout').textContent = value ? '正在退出…' : '退出登录';
  $('account-form').setAttribute('aria-busy', String(value));
}
function setMode(value) {
  if (busy) return;
  mode = value;
  const register = value === 'register';
  $('register-tab').classList.toggle('active', register);
  $('login-tab').classList.toggle('active', !register);
  $('register-tab').setAttribute('aria-pressed', String(register));
  $('login-tab').setAttribute('aria-pressed', String(!register));
  $('form-title').textContent = register ? '让想法，有个归处。' : '继续你的思想宇宙。';
  $('form-description').textContent = register ? '用邮箱创建账户，开始连接你的点界。' : '很高兴再次见到你，登录你的点界账户。';
  $('confirmation-field').hidden = !register;
  $('confirmation').required = register;
  $('confirmation').value = '';
  $('password').value = '';
  $('password').minLength = register ? 12 : 1;
  $('password').autocomplete = register ? 'new-password' : 'current-password';
  $('password').placeholder = register ? '至少 12 个字符' : '输入你的密码';
  $('password-help').hidden = !register;
  $('verification-note').hidden = !register;
  message($('form-message'), '');
  setBusy(false);
}
async function api(path, body) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 20000);
  try {
    const options = { method: body ? 'POST' : 'GET', credentials: 'same-origin', cache: 'no-store', signal: controller.signal };
    if (body) { options.headers = { 'Content-Type': 'application/json' }; options.body = JSON.stringify(body); }
    const response = await fetch('/web/auth/' + path, options);
    const result = response.status === 204 ? {} : await response.json();
    if (!response.ok) { const error = new Error(messages[result.error?.code] || '账户服务暂时不可用，请稍后重试。'); error.status = response.status; throw error; }
    return result;
  } catch (error) {
    if (error instanceof TypeError || error.name === 'AbortError') throw new Error('暂时无法连接账户服务，请检查网络后重试。');
    throw error;
  } finally { clearTimeout(timeout); }
}
function showUser(user, registered = false) {
  $('auth-panel').hidden = true;
  $('account-panel').hidden = false;
  $('account-title').textContent = registered ? '欢迎加入点界。' : '欢迎回到点界。';
  $('welcome-message').textContent = registered ? '账户已创建，你已经登录。' : '你的账户已登录。';
  const identity = user.identities.find(item => item.provider === 'email');
  $('account-email').textContent = identity?.email || '未提供邮箱';
  $('account-verification').textContent = identity?.email_verified ? '已验证' : '未验证 · 邮箱验证尚未开放';
  $('account-created').textContent = new Intl.DateTimeFormat('zh-CN', {year: 'numeric', month: 'long', day: 'numeric'}).format(new Date(user.created_at));
  $('password').value = ''; $('confirmation').value = '';
  message($('account-message'), '');
}
$('register-tab').addEventListener('click', () => setMode('register'));
$('login-tab').addEventListener('click', () => setMode('login'));
$('show-password').addEventListener('click', () => {
  const show = $('password').type === 'password';
  $('password').type = show ? 'text' : 'password';
  $('show-password').textContent = show ? '隐藏' : '显示';
  $('show-password').setAttribute('aria-label', show ? '隐藏密码' : '显示密码');
  $('show-password').setAttribute('aria-pressed', String(show));
});
$('account-form').addEventListener('submit', async event => {
  event.preventDefault(); if (busy) return;
  message($('form-message'), '');
  if (mode === 'register' && $('password').value !== $('confirmation').value) { message($('form-message'), messages.password_mismatch); $('confirmation').focus(); return; }
  const body = { email: $('email').value.trim(), password: $('password').value };
  if (mode === 'register') body.password_confirmation = $('confirmation').value;
  setBusy(true);
  try { const result = await api(mode, body); showUser(result.user, mode === 'register'); }
  catch (error) { message($('form-message'), error.message); }
  finally { setBusy(false); }
});
$('logout').addEventListener('click', async () => {
  if (busy) return; setBusy(true); message($('account-message'), '');
  try { await api('logout', {}); $('account-panel').hidden = true; $('auth-panel').hidden = false; }
  catch (error) { message($('account-message'), error.message); }
  finally { setBusy(false); }
});
(async () => {
  setBusy(true);
  try { const result = await api('me'); showUser(result.user); }
  catch (error) { if (error.status !== 401) message($('form-message'), error.message); }
  finally { setBusy(false); }
})();
