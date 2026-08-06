#!/usr/bin/env bash
# =============================================================================
#  🦀 MOTOBASE — Node.js no Mac/Linux, em uma linha
#
#    bash <(curl -fsSL https://get.motobot.com.br/node.sh)
#
#  Instala o Node.js LTS (com npm) e te deixa pronto pro:
#    npm install -g @anthropic-ai/claude-code
# =============================================================================
set -euo pipefail
G='\033[38;5;108m'; A='\033[38;5;179m'; C='\033[36m'; D='\033[2m'; N='\033[0m'
echo -e "\n  ${A}🦀 MOTOBASE — preparando seu computador (Node.js LTS)${N}\n"

if command -v node >/dev/null 2>&1; then
  echo -e "  ${G}✓ Node já instalado: $(node -v) — nada a fazer.${N}"
else
  OS=$(uname -s)
  if [[ "$OS" == "Darwin" ]]; then
    if command -v brew >/dev/null 2>&1; then
      echo -e "  ${D}instalando via Homebrew…${N}"
      brew install node@22 || brew install node
    else
      echo -e "  ${D}instalando o Homebrew primeiro (o gerenciador de apps do Mac)…${N}"
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
      brew install node@22 || brew install node
    fi
  elif command -v apt-get >/dev/null 2>&1; then
    echo -e "  ${D}instalando via NodeSource (repositório oficial pra Debian/Ubuntu)…${N}"
    SUDO=""; [[ $EUID -ne 0 ]] && SUDO="sudo"
    curl -fsSL https://deb.nodesource.com/setup_lts.x | $SUDO bash -
    $SUDO apt-get install -y nodejs
  else
    echo -e "  ${A}⚠ Sistema não reconhecido — baixe em https://nodejs.org (botão LTS).${N}"; exit 1
  fi
  echo -e "\n  ${G}✓ Node.js instalado: $(node -v 2>/dev/null || echo 'reabra o terminal')${N}"
fi

echo -e "\n  Próximo passo:\n"
echo -e "    ${C}npm install -g @anthropic-ai/claude-code${N}\n"
