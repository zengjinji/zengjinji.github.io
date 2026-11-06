(() => {
  document.querySelectorAll("[data-copy-code]").forEach((button) => {
    const code = document.getElementById(button.dataset.copyCode);
    const label = button.querySelector(".code-copy-text");
    if (!code || !label) return;

    let resetTimer;
    button.addEventListener("click", async () => {
      if (button.disabled) return;
      window.clearTimeout(resetTimer);
      button.disabled = true;

      try {
        if (!navigator.clipboard || typeof navigator.clipboard.writeText !== "function") {
          throw new Error("Clipboard unavailable");
        }
        await navigator.clipboard.writeText(code.textContent);
        label.textContent = button.dataset.labelCopied;
        button.dataset.copyState = "copied";
      } catch {
        const selection = window.getSelection();
        if (selection) {
          const range = document.createRange();
          range.selectNodeContents(code);
          selection.removeAllRanges();
          selection.addRange(range);
        }
        label.textContent = button.dataset.labelFailed;
        button.dataset.copyState = "failed";
      } finally {
        button.disabled = false;
        resetTimer = window.setTimeout(() => {
          label.textContent = button.dataset.labelCopy;
          delete button.dataset.copyState;
        }, 2500);
      }
    });
    button.hidden = false;
  });
})();
