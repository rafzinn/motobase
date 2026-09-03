FROM node:20-slim AS build
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends python3 make g++ && rm -rf /var/lib/apt/lists/*
COPY package.json ./
RUN npm install --omit=dev --build-from-source --loglevel=error --no-audit --no-fund

FROM node:20-slim
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates ripgrep && rm -rf /var/lib/apt/lists/* \
 && npm install -g @anthropic-ai/claude-code --loglevel=error --no-audit --no-fund
COPY --from=build /app/node_modules ./node_modules
COPY server.js chat-settings.json auth.js identidade.js canal-2fa.js porta-cliente.js ./
COPY public ./public
RUN mkdir -p /data
ENV DATA_DIR=/data
EXPOSE 3000
CMD ["node","server.js"]
