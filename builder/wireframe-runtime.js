(() => {
  const runtime = window.__wireframeRuntime || {};
  const fieldValues = runtime.fieldValues || new Map();

  const syncValues = () => {
    document.querySelectorAll('[data-field-value]').forEach((element) => {
      element.textContent = fieldValues.get(element.dataset.fieldValue) ?? element.dataset.emptyText ?? '未選択';
    });
  };

  runtime.showScreen = (id, options = {}) => {
    const screens = [...document.querySelectorAll('[data-screen-id]')];
    const next = screens.find((screen) => screen.dataset.screenId === id);
    if (!next) return;
    screens.forEach((screen) => screen.classList.toggle('is-active', screen === next));
    document.querySelectorAll('[data-nav-target]').forEach((button) => {
      if (button.dataset.navTarget === id) button.setAttribute('aria-current', 'page');
      else button.removeAttribute('aria-current');
    });
    syncValues();
    if (options.focus !== false) next.querySelector('h2')?.focus({ preventScroll: true });
  };

  if (!runtime.listenersInstalled) {
    const storeField = (event) => {
      const field = event.target.closest?.('[data-field-key]');
      if (!field) return;
      fieldValues.set(field.dataset.fieldKey, field.value);
      syncValues();
    };
    document.addEventListener('input', storeField);
    document.addEventListener('change', storeField);
    document.addEventListener('click', (event) => {
      const trigger = event.target.closest?.('[data-action-target], [data-nav-target]');
      if (!trigger) return;
      runtime.showScreen(trigger.dataset.actionTarget || trigger.dataset.navTarget);
    });
    document.addEventListener('keydown', (event) => {
      if (event.key === 'Home' && !/INPUT|TEXTAREA|SELECT/.test(document.activeElement?.tagName || '')) {
        event.preventDefault();
        runtime.showScreen(document.querySelector('[data-start-screen]')?.dataset.screenId);
      }
    });
    runtime.listenersInstalled = true;
  }

  runtime.fieldValues = fieldValues;
  window.__wireframeRuntime = runtime;
})();
