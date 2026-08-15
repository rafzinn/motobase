#!/usr/bin/env bash
# 🤝 SOMOS UM — atalho: vibe stack (base universal) + semente do projeto.
# Tudo que este script faz vive em vibe.sh; a identidade do projeto em seeds/somosum/.
# Fonte oficial: github.com/rafzinn/motobase
exec bash <(curl -fsSL https://raw.githubusercontent.com/rafzinn/motobase/main/vibe.sh) --seed somosum "$@"
