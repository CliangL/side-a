'use strict';
document.querySelector('#login-form').addEventListener('submit', async function(event) {
  event.preventDefault();
  const button = this.querySelector('button');
  button.disabled = true;
  const error = document.querySelector('#login-error');
  error.textContent = '';
  try {
    const session = await (await fetch('/admin/api/session')).json();
    const response = await fetch('/admin/login', {method:'POST', headers:{'Content-Type':'application/json','X-CSRF-Token':session.csrf_token}, body:JSON.stringify({password:this.password.value})});
    const data = await response.json();
    if (!response.ok || !data.ok) throw new Error(data.error && data.error.message || '登录失败，请重试');
    location.replace('/');
  } catch (e) { error.textContent = e.message; }
  finally { button.disabled = false; }
});
