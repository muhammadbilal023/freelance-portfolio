# ---- build stage ----
FROM node:20-alpine AS build
WORKDIR /app
# better-sqlite3 ships musl prebuilds, but keep toolchain ready as a fallback
RUN apk add --no-cache python3 make g++
COPY package*.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build && npm prune --omit=dev

# ---- runtime stage ----
FROM node:20-alpine AS runtime
WORKDIR /app
ENV NODE_ENV=production
# Run as the unprivileged built-in node user
USER node
COPY --chown=node:node --from=build /app/node_modules ./node_modules
COPY --chown=node:node --from=build /app/dist ./dist
COPY --chown=node:node package.json ./
COPY --chown=node:node public ./public
# SQLite lives here; mount a volume so data survives container restarts
RUN mkdir -p /app/data
EXPOSE 8081
CMD ["node", "dist/src/index.js"]
