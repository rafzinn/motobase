# ── build: compila o better-sqlite3 (módulo nativo) ──
FROM node:20-alpine AS build
RUN apk add --no-cache python3 make g++
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev --build-from-source --loglevel=error --no-audit --no-fund

# ── runtime: só o necessário ──
FROM node:20-alpine
ENV NODE_ENV=production PORT=3000 DATA_DIR=/data
WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
COPY server.js ./
COPY public ./public
RUN mkdir -p /data
EXPOSE 3000
CMD ["node","server.js"]
