(() => {
  const root = document.querySelector("[data-mac-playground]");
  if (!root) return;

  const windows = new Map(
    [...root.querySelectorAll("[data-window]")].map((windowEl) => [
      windowEl.dataset.window,
      windowEl,
    ])
  );

  const defaults = new Map();
  windows.forEach((windowEl, name) => {
    defaults.set(name, {
      x: windowEl.style.getPropertyValue("--x"),
      y: windowEl.style.getPropertyValue("--y"),
      w: windowEl.style.getPropertyValue("--w"),
      z: windowEl.style.getPropertyValue("--z"),
    });
  });

  let topZ = 20;
  let hiddenFromShare = true;
  let paused = false;

  const compactPill = root.querySelector("[data-compact-pill]");
  const answerBox = root.querySelector("[data-answer-box]");
  const transcript = root.querySelector("[data-live-transcript]");
  const title = root.querySelector("[data-prototype-title]");
  const contextLabel = root.querySelector("[data-context-label]");
  const privacyMenu = root.querySelector("[data-menu-action='privacy']");
  const privacySwitch = root.querySelector("[data-setting='privacy']");
  const callStatus = root.querySelector("[data-call-status]");
  const clock = root.querySelector("[data-clock]");

  function focusWindow(windowEl) {
    if (!windowEl) return;
    root.querySelectorAll(".mac-window").forEach((item) => item.classList.remove("active-window"));
    windowEl.classList.add("active-window");
    windowEl.style.setProperty("--z", String(++topZ));
  }

  function openWindow(name) {
    const windowEl = windows.get(name);
    if (!windowEl) return;
    if (name === "assistant") compactPill.hidden = true;
    windowEl.classList.remove("is-hidden", "is-minimized");
    focusWindow(windowEl);
  }

  function openSurface(name) {
    openWindow("assistant");
    root.querySelectorAll("[data-surface]").forEach((surface) => {
      surface.classList.toggle("is-active", surface.dataset.surface === name);
    });
    title.textContent = surfaceTitle(name);
  }

  function surfaceTitle(name) {
    return {
      home: "MacOverlay",
      interview: "Interview",
      live: "Live Focus",
      resume: "Resumes",
      prompts: "Prompts",
      settings: "Settings",
    }[name] || "MacOverlay";
  }

  function resetPrototype() {
    windows.forEach((windowEl, name) => {
      const state = defaults.get(name);
      windowEl.classList.remove("is-hidden", "is-minimized", "is-zoomed");
      windowEl.style.setProperty("--x", state.x);
      windowEl.style.setProperty("--y", state.y);
      windowEl.style.setProperty("--w", state.w);
      windowEl.style.setProperty("--z", state.z);
    });
    compactPill.hidden = true;
    root.classList.remove("is-aurora");
    hiddenFromShare = true;
    paused = false;
    updatePrivacyUI();
    callStatus.textContent = "Screen sharing";
    transcript.textContent = "Walk me through a system you made faster.";
    answerBox.textContent =
      "I’d start with the bottleneck, measure it, then ship the smallest change that improves the user-visible metric.";
    openSurface("home");
  }

  function updatePrivacyUI() {
    privacyMenu.textContent = hiddenFromShare ? "Hidden" : "Visible";
    privacyMenu.classList.toggle("is-active", !hiddenFromShare);
    privacySwitch.classList.toggle("is-on", hiddenFromShare);
    privacySwitch.setAttribute("aria-pressed", String(hiddenFromShare));
  }

  function suggestAnswer(seed = "") {
    openSurface("live");
    const base = seed || transcript.textContent;
    transcript.textContent = base;
    answerBox.textContent =
      "I’d answer with the result first, then one concrete example, and close with the metric or lesson that proves the impact.";
  }

  root.addEventListener("pointerdown", (event) => {
    const windowEl = event.target.closest(".mac-window");
    if (windowEl) focusWindow(windowEl);
  });

  root.addEventListener("click", (event) => {
    const windowButton = event.target.closest("[data-open-window]");
    if (windowButton) {
      openWindow(windowButton.dataset.openWindow);
      return;
    }

    const surfaceButton = event.target.closest("[data-open-surface]");
    if (surfaceButton) {
      openSurface(surfaceButton.dataset.openSurface);
      return;
    }

    const windowAction = event.target.closest("[data-window-action]");
    if (windowAction) {
      const windowEl = windowAction.closest(".mac-window");
      const action = windowAction.dataset.windowAction;
      if (action === "close") windowEl.classList.add("is-hidden");
      if (action === "minimize") windowEl.classList.toggle("is-minimized");
      if (action === "zoom") {
        windowEl.classList.toggle("is-zoomed");
        focusWindow(windowEl);
      }
      return;
    }

    const menuAction = event.target.closest("[data-menu-action]");
    if (menuAction) {
      const action = menuAction.dataset.menuAction;
      if (action === "reset") resetPrototype();
      if (action === "theme") {
        root.classList.toggle("is-aurora");
        menuAction.classList.toggle("is-active");
      }
      if (action === "privacy") {
        hiddenFromShare = !hiddenFromShare;
        updatePrivacyUI();
      }
      return;
    }

    const prototypeAction = event.target.closest("[data-prototype-action]");
    if (prototypeAction) {
      const action = prototypeAction.dataset.prototypeAction;
      if (action === "compact") {
        windows.get("assistant").classList.add("is-hidden");
        compactPill.hidden = false;
      }
      if (action === "new") {
        transcript.textContent = "New session ready.";
        answerBox.textContent = "Pick Interview, attach context, then Start interview.";
        openSurface("home");
      }
      if (action === "start") {
        callStatus.textContent = "Live";
        transcript.textContent = "Tell me about a system you made faster.";
        answerBox.textContent = "Listening. Suggestions will appear when the interviewer pauses.";
        openSurface("live");
      }
      if (action === "pause") {
        paused = !paused;
        prototypeAction.textContent = paused ? "Resume" : "Pause";
        answerBox.textContent = paused
          ? "Paused. The transcript is held until you resume."
          : "Resumed. Listening for the next useful question.";
      }
      if (action === "answer") suggestAnswer();
      if (action === "end") {
        callStatus.textContent = "Ended";
        transcript.textContent = "Interview ended.";
        answerBox.textContent = "Session saved locally. Start a new one from the plus button.";
      }
      return;
    }

    const callToggle = event.target.closest("[data-call-toggle]");
    if (callToggle) {
      const mode = callToggle.dataset.callToggle;
      if (mode === "mic") {
        callToggle.classList.toggle("is-off");
        callToggle.textContent = callToggle.classList.contains("is-off") ? "Mic off" : "Mic on";
      }
      if (mode === "camera") {
        callToggle.classList.toggle("is-off");
        callToggle.textContent = callToggle.classList.contains("is-off") ? "Camera off" : "Camera on";
      }
      if (mode === "share") {
        callToggle.classList.toggle("is-on");
        callToggle.textContent = callToggle.classList.contains("is-on") ? "Sharing" : "Share";
        callStatus.textContent = callToggle.classList.contains("is-on") ? "Screen sharing" : "Ready";
      }
      if (mode === "end") {
        callStatus.textContent = "Ended";
        transcript.textContent = "Call ended.";
        answerBox.textContent = "Your overlay stayed separate from the shared screen.";
        openSurface("live");
      }
      return;
    }

    const contextFile = event.target.closest("[data-context-file]");
    if (contextFile) {
      const file = contextFile.dataset.contextFile;
      contextLabel.textContent = `${file} attached`;
      transcript.textContent = `${file} added as interview context.`;
      answerBox.textContent = "I’ll ground suggested answers in this context and avoid made-up details.";
      openSurface("live");
      return;
    }

    const preset = event.target.closest("[data-prompt-preset]");
    if (preset) {
      suggestAnswer(preset.dataset.promptPreset);
    }
  });

  root.querySelector("[data-prompt-form]")?.addEventListener("submit", (event) => {
    event.preventDefault();
    const input = event.currentTarget.elements.prompt;
    const value = input.value.trim();
    if (!value) return;
    suggestAnswer(value);
    input.value = "";
  });

  root.querySelectorAll("[data-mode]").forEach((button) => {
    button.addEventListener("click", () => {
      root.querySelectorAll("[data-mode]").forEach((item) => item.classList.remove("is-selected"));
      button.classList.add("is-selected");
      contextLabel.textContent =
        button.dataset.mode === "call"
          ? "Call notes attached"
          : "Resume.pdf + Job Description.txt attached";
    });
  });

  root.querySelectorAll("[data-setting='opacity'], [data-setting='blur']").forEach((input) => {
    input.addEventListener("input", () => {
      if (input.dataset.setting === "opacity") {
        root.style.setProperty("--glass-opacity", String(Number(input.value) / 100));
      }
      if (input.dataset.setting === "blur") {
        root.style.setProperty("--glass-blur", `${input.value}px`);
      }
    });
  });

  privacySwitch?.addEventListener("click", () => {
    hiddenFromShare = !hiddenFromShare;
    updatePrivacyUI();
  });

  root.querySelectorAll("[data-drag-handle]").forEach((handle) => {
    handle.addEventListener("pointerdown", (event) => {
      if (event.target.closest("button")) return;
      const windowEl = handle.closest(".mac-window");
      focusWindow(windowEl);
      handle.setPointerCapture(event.pointerId);

      const rootRect = root.getBoundingClientRect();
      const rect = windowEl.getBoundingClientRect();
      const menuHeight = parseFloat(getComputedStyle(root).getPropertyValue("--menu-height")) || 42;
      const start = {
        pointerX: event.clientX,
        pointerY: event.clientY,
        x: rect.left - rootRect.left,
        y: rect.top - rootRect.top - menuHeight,
      };

      function onMove(moveEvent) {
        const width = windowEl.offsetWidth;
        const height = windowEl.offsetHeight;
        const maxX = root.clientWidth - width - 8;
        const maxY = root.clientHeight - menuHeight - height - 84;
        const nextX = Math.min(Math.max(8, start.x + moveEvent.clientX - start.pointerX), Math.max(8, maxX));
        const nextY = Math.min(Math.max(8, start.y + moveEvent.clientY - start.pointerY), Math.max(8, maxY));
        windowEl.style.setProperty("--x", `${Math.round(nextX)}px`);
        windowEl.style.setProperty("--y", `${Math.round(nextY)}px`);
      }

      function onUp() {
        handle.removeEventListener("pointermove", onMove);
        handle.removeEventListener("pointerup", onUp);
        handle.removeEventListener("pointercancel", onUp);
      }

      handle.addEventListener("pointermove", onMove);
      handle.addEventListener("pointerup", onUp);
      handle.addEventListener("pointercancel", onUp);
    });
  });

  function updateClock() {
    const now = new Date();
    clock.textContent = now.toLocaleString([], {
      weekday: "short",
      hour: "numeric",
      minute: "2-digit",
    });
  }

  updateClock();
  updatePrivacyUI();
  if (location.hash === "#demo") {
    window.setTimeout(() => {
      const header = document.querySelector(".site-header");
      const offset = (header?.getBoundingClientRect().height || 72) + 26;
      window.scrollTo({
        top: root.getBoundingClientRect().top + window.scrollY - offset,
        behavior: "auto",
      });
    }, 80);
  }
  window.setInterval(updateClock, 15000);
})();
