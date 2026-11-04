"use strict";
(() => {
    for (const form of document.querySelectorAll("form[data-confirm]")) {
        form.addEventListener("submit", event => {
            if (!window.confirm(form.dataset.confirm)) event.preventDefault();
        });
    }
    const date = new Intl.DateTimeFormat("zh-CN", { dateStyle: "medium", timeStyle: "short" });
    for (const time of document.querySelectorAll("time[data-unix]")) {
        const value = new Date(Number(time.dataset.unix) * 1000);
        if (!Number.isNaN(value.valueOf())) {
            time.dateTime = value.toISOString();
            time.textContent = date.format(value);
        }
    }

    const form = document.querySelector("#qq-login");
    if (!form) return;
    const buttons = form.querySelectorAll("button[type=submit]");
    const pane = document.querySelector("#qr-pane");
    const img = document.querySelector("#qr-image");
    const message = document.querySelector("#qr-message");
    let timer, controller, attempt;
    function end() {
        clearTimeout(timer);
        controller?.abort();
        controller = undefined;
        attempt = undefined;
        img.removeAttribute("src");
        img.hidden = true;
        for (const button of buttons) button.disabled = false;
    }
    // Remember only Side A's polling handle. The QQ image and login credentials stay out of storage.
    const storageKey = "sidea.qq.pending";
    function remember(value) {
        try {
            if (value) sessionStorage.setItem(storageKey, JSON.stringify(value));
            else sessionStorage.removeItem(storageKey);
        } catch { /* Some browsers disable storage. Current-page polling still works. */ }
    }
    window.addEventListener("pagehide", end);
    async function json(url, options) {
        const response = await fetch(url, { ...options, credentials: "same-origin", cache: "no-store", redirect: "error" });
        if (response.status === 401 || response.status === 403) throw Error("管理员登录已失效，请重新登录。");
        if (!response.headers.get("Content-Type")?.includes("application/json"))
            throw Object.assign(Error("后台暂时无法返回状态。"), { retryable: response.status >= 500 });
        const data = await response.json();
        if (!response.ok) throw Object.assign(Error(typeof data.error === "string" ? data.error : "后台暂不可用。"),
            { retryable: [502, 503, 504].includes(response.status) });
        return data;
    }
    function stopWith(text) {
        end();
        remember(null);
        message.textContent = text;
    }
    async function poll(id, deadline, signal, lastError = "") {
        if (attempt !== id || signal.aborted) return;
        if (Date.now() >= deadline) {
            stopWith(lastError ? lastError + " 本次查询已结束，请刷新页面查看绑定状态。" : "二维码已过期，请重新生成。");
            return;
        }
        try {
            const data = await json(form.dataset.status.replace("ATTEMPT_ID",encodeURIComponent(id)), { signal });
            if (attempt !== id || signal.aborted) return;
            message.textContent = data.message || "正在等待手机确认…";
            if (data.status === "pending" || data.status === "scanned") {
                timer = setTimeout(() => poll(id, deadline, signal), 2200);
                return;
            }
            if (data.status === "connected") {
                const badge = document.querySelector("#qq-badge");
                badge.textContent = "已连接";
                badge.classList.add("on");
                document.querySelector("#qq-summary").textContent = data.message || "后台已登录 QQ 音乐。";
            }
            stopWith(message.textContent);
        } catch (error) {
            if (signal.aborted || attempt !== id) return;
            if (error instanceof TypeError || error.retryable) {
                const reason = error instanceof TypeError ? "浏览器暂时连不上后台。" : error.message;
                message.textContent = reason + " 正在继续查询同一次扫码。";
                timer = setTimeout(() => poll(id, deadline, signal, reason), 3000);
            } else {
                stopWith(error.message);
            }
        }
    }
    window.addEventListener("pageshow", () => {
        if (attempt) return;
        let previous;
        try { previous = JSON.parse(sessionStorage.getItem(storageKey)); } catch { return; }
        if (!previous || !/^[A-Za-z0-9_-]{12,120}$/.test(previous.id) || !(previous.deadline > Date.now())) {
            remember(null);
            return;
        }
        attempt = previous.id;
        controller = new AbortController();
        pane.hidden = false;
        message.textContent = "正在查询上一次扫码的结果…";
        poll(attempt, previous.deadline, controller.signal);
    });
    form.addEventListener("submit", async event => {
        event.preventDefault();
        end();
        remember(null);
        for (const button of buttons) button.disabled = true;
        pane.hidden = false;
        message.textContent = "正在向 QQ 音乐申请登录二维码…";
        controller = new AbortController();
        const signal = controller.signal;
        try {
            const body = new FormData(form);
            body.set("method", event.submitter?.value || "qq");
            const data = await json(form.action, { method: "POST", body, signal });
            if (signal.aborted) return;
            if (typeof data.id !== "string" || !/^[A-Za-z0-9_-]{12,120}$/.test(data.id) ||
                typeof data.image !== "string" || !/^data:image\/(?:png|jpeg);base64,[A-Za-z0-9+/]+=*$/.test(data.image))
                throw Error("后台没有返回可用的二维码，请重新生成。");
            img.src = data.image;
            img.hidden = false;
            message.textContent = data.message;
            for (const button of buttons) button.disabled = false;
            attempt = data.id;
            const deadline = Date.now() + (Number(data.expires_in) || 120) * 1000 + 5000;
            remember({id: data.id, deadline});
            timer = setTimeout(() => poll(data.id, deadline, signal), 2000);
        } catch (error) {
            if (!signal.aborted) stopWith(error.message || "无法生成二维码，请重试。");
        }
    });
})();
