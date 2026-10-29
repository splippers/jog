# Installed to /etc/profile.d/jog-remind.sh — reminds operator to run the wizard or check FOG install.
if [[ -n "${PS1:-}" ]] && [[ "$(id -u)" -ne 0 ]]; then
  if [[ ! -f /etc/jog/wizard.done ]]; then
    echo ""
    echo "  [JOG] First-time setup: run  sudo jog-install-wizard"
    echo ""
  elif [[ ! -f /etc/jog/fog-native.done ]]; then
    echo ""
    echo "  [JOG] Native FOG install may still be running; check: journalctl -fu jog-fog-install.service"
    echo ""
  fi
fi
