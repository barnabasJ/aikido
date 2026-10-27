export const AgentIdentity = {
  mounted() {
    this.positionPopup = () => {
      const popup = this.el.querySelector(".inspector-id-popup");
      const rect = this.el.getBoundingClientRect();
      popup.style.left = `${Math.max(8, Math.min(rect.right - 420, window.innerWidth - 428))}px`;
      popup.style.top = `${Math.min(rect.bottom, window.innerHeight - 100)}px`;
    };
    this.copyId = async (event) => {
      const button = event.target.closest("[data-copy-agent-id]");
      if (!button) return;
      try {
        await navigator.clipboard.writeText(button.dataset.copyAgentId);
        button.querySelector(".inspector-copy-label").textContent = "Copied";
      } catch {
        button.querySelector(".inspector-copy-label").textContent = "Copy unavailable";
      }
    };
    this.el.addEventListener("mouseenter", this.positionPopup);
    this.el.addEventListener("focusin", this.positionPopup);
    this.el.addEventListener("click", this.copyId);
  },
  destroyed() {
    this.el.removeEventListener("mouseenter", this.positionPopup);
    this.el.removeEventListener("focusin", this.positionPopup);
    this.el.removeEventListener("click", this.copyId);
  }
};
